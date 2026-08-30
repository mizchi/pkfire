// The scheduler: executing an action graph, in parallel.
//
// The runner used to walk `graph.order` one task at a time. That order
// is a *serialization* of the graph — it says a valid sequence exists,
// not that no other sequence is valid — so running it sequentially
// leaves every independent branch of the graph waiting on work it does
// not depend on. `-j` was rejected outright because there was nothing
// to schedule with.
//
// Now that analysis produces a graph, scheduling is the usual
// ready-queue over in-degrees: an action becomes runnable when every
// action it depends on has finished, and up to `jobs` of them run at
// once. Two details are worth stating because they are choices, not
// consequences:
//
//   - **Ties break on `graph.order`.** When several actions are ready,
//     the one earliest in the topological order goes first. That makes
//     `-j 1` byte-for-byte identical to the old sequential walk, and
//     makes any `-j` reproducible rather than dependent on which
//     process happened to exit first.
//
//   - **A failure stops scheduling, it does not kill what is running.**
//     Cancelling a compiler mid-write leaves a half-written output that
//     a later run will happily treat as real. In-flight actions finish;
//     nothing new is launched.
//
// `--keep-going` keeps launching, but only actions whose dependencies
// all succeeded. Anything downstream of a failure is reported as
// skipped rather than run against inputs that were never produced —
// which is what the sequential runner did, because "continue past a
// failure" was implemented as "carry on down the list".

///|
/// Number of CPUs available to this process; 0 when undeterminable.
extern "C" fn cpu_count_ffi() -> Int = "mizchi_pkf_cpu_count"

///|
/// Wall clock in milliseconds. Only ever used for reporting.
extern "C" fn now_ms() -> Int64 = "mizchi_pkf_now_ms"

///|
/// How `-j auto` resolves. Capped because the number is a concurrency
/// limit for *processes*, and each one may itself be a parallel build
/// tool: on a 128-core machine, 128 concurrent `moon build`s is not
/// eight times better than 16, it is a way to run out of memory.
fn auto_jobs() -> Int {
  let n = cpu_count_ffi()
  if n <= 0 {
    1
  } else if n > 16 {
    16
  } else {
    n
  }
}

///|
/// What happened to one action.
enum ActionOutcome {
  /// Reached a conclusion of its own — ran, hit the cache, or had
  /// nothing to do. The exit code is inside the `TaskOutcome`.
  Finished(TaskOutcome)
  /// Never launched: something it depends on failed, or the run had
  /// already failed and `--keep-going` was not set. The `String` names
  /// the action that caused it.
  Skipped(String)
} derive(Eq)

///|
/// Per-action record of a completed run, in completion order.
struct ActionRun {
  task : String
  outcome : ActionOutcome
  /// Wall milliseconds from launch to completion. Zero for skipped.
  duration_ms : Int64
  /// Milliseconds from the start of the run to this action's launch.
  /// With `-j 1` this is just the sum of everything before it; with
  /// `-j N` it is what makes a critical path computable.
  start_ms : Int64
  /// How many times the command was spawned. 1 for anything that ran
  /// once; 0 for a cache hit, an umbrella or a skip, which spawn
  /// nothing. Above 1 means `retries` was used — the number that turns
  /// "this suite is flaky" into something anyone can act on.
  attempts : Int
}

///|
/// The result of executing a graph.
struct ScheduleResult {
  exit_code : Int
  runs : Array[ActionRun]
  wall_ms : Int64
}

///|
/// In-degree over the graph's edges, deduplicated by producer.
///
/// An action can be linked to the same producer twice — once through
/// `deps` and once through an artifact — and counting that twice would
/// leave the action permanently un-runnable.
fn action_indegrees(graph : ActionGraph) -> Map[String, Int] {
  let indegree : Map[String, Int] = Map([], capacity=graph.order.length())
  for name in graph.order {
    let seen : Map[String, Bool] = Map([], capacity=4)
    match graph.nodes.get(name) {
      Some(node) =>
        for edge in node.edges {
          if !seen.contains(edge.producer) && graph.nodes.get(edge.producer) is Some(_) {
            seen[edge.producer] = true
          }
        }
      None => ()
    }
    indegree[name] = seen.length()
  }
  indegree
}

///|
/// Reverse edges: for each action, the actions waiting on it.
fn action_dependents(graph : ActionGraph) -> Map[String, Array[String]] {
  let dependents : Map[String, Array[String]] = Map(
    [],
    capacity=graph.order.length(),
  )
  for name in graph.order {
    dependents[name] = []
  }
  for name in graph.order {
    let seen : Map[String, Bool] = Map([], capacity=4)
    match graph.nodes.get(name) {
      Some(node) =>
        for edge in node.edges {
          if seen.contains(edge.producer) {
            continue
          }
          match dependents.get(edge.producer) {
            Some(list) => {
              seen[edge.producer] = true
              list.push(name)
            }
            None => ()
          }
        }
      None => ()
    }
  }
  dependents
}

///|
/// Execute `graph`, running up to `jobs` actions concurrently.
///
/// One driver fiber owns all the bookkeeping and spawns one fiber per
/// action; the driver only ever advances when an action reports back,
/// so the ready set, the in-degrees and the counters are never observed
/// half-updated.
async fn[X] run_action_graph(
  group : @async.TaskGroup[X],
  plan : Plan,
  graph : ActionGraph,
  repo_root : String,
  arg_target : String,
  flags : Map[String, String],
  positionals : Array[String],
  opts : RunOptions,
  jobs : Int,
  keep_going : Bool,
) -> ScheduleResult {
  let started = now_ms()
  let runs : Array[ActionRun] = []
  let indegree = action_indegrees(graph)
  let dependents = action_dependents(graph)
  // Position in the topological order, so ties among ready actions
  // break the same way on every run.
  let rank : Map[String, Int] = Map([], capacity=graph.order.length())
  for i, name in graph.order {
    rank[name] = i
  }
  let ready : Array[String] = []
  for name in graph.order {
    if indegree.get(name) is Some(0) {
      ready.push(name)
    }
  }
  // `poisoned` marks an action whose dependencies did not all succeed.
  let poisoned : Map[String, String] = Map([], capacity=8)
  let completions = @semaphore.Semaphore(
    graph.order.length() + 1,
    initial_value=0,
  )
  let inbox : Array[(String, TaskOutcome, Int64, Int64, Int)] = []
  let mut running = 0
  let mut outstanding = 0
  let mut exit_code = 0
  let mut failed = false

  // Retire one action and release whatever it was holding up. Skipped
  // dependents cascade here rather than through the ready set, so an
  // action downstream of a failure is never launched at all.
  fn retire(name : String, ok : Bool, cause : String) -> Unit {
    match dependents.get(name) {
      Some(list) =>
        for dep in list {
          match indegree.get(dep) {
            Some(n) => indegree[dep] = n - 1
            None => ()
          }
          if !ok && !poisoned.contains(dep) {
            poisoned[dep] = cause
          }
          if indegree.get(dep) is Some(0) {
            match poisoned.get(dep) {
              Some(why) => {
                runs.push(ActionRun::{
                  task: dep,
                  outcome: Skipped(why),
                  duration_ms: 0,
                  start_ms: now_ms() - started,
                  // Never launched, so nothing was attempted.
                  attempts: 0,
                })
                if !opts.quiet {
                  println("pkf: - \{dep} (skipped: `\{why}` failed)")
                }
                retire(dep, false, why)
              }
              None => ready.push(dep)
            }
          }
        }
      None => ()
    }
  }

  while true {
    // Launch everything runnable, up to the job limit. After a failure
    // without `--keep-going` nothing new is launched; the loop then
    // only drains what is already running.
    while running < jobs && ready.length() > 0 && !(failed && !keep_going) {
      // Earliest in topological order wins.
      let mut pick = 0
      for i, candidate in ready {
        let a = rank.get(candidate).unwrap_or(0)
        let b = rank.get(ready[pick]).unwrap_or(0)
        if a < b {
          pick = i
        }
      }
      let name = ready[pick]
      let _ = ready.remove(pick)
      let task = match plan.tasks.get(name) {
        Some(t) => t
        None => continue
      }
      // CLI flags and positional args only ever apply to the target the
      // user named, never to something pulled in as a dependency.
      let (task_flags, task_positionals) = if name == arg_target {
        (flags, positionals)
      } else {
        (Map([], capacity=0), [])
      }
      let resolved_params = match resolve_task_params(task, task_flags) {
        Some(m) => m
        None => {
          failed = true
          exit_code = 2
          retire(name, false, name)
          continue
        }
      }
      running = running + 1
      outstanding = outstanding + 1
      let launched = now_ms()
      group.spawn_bg(() => {
        let attempts = Ref(0)
        let outcome = run_task(
          group,
          plan,
          task,
          repo_root,
          resolved_params,
          task_positionals,
          opts~,
          graph=Some(graph),
          attempts~,
        )
        inbox.push(
          (name, outcome, now_ms() - launched, launched - started, attempts.val),
        )
        completions.release()
      })
    }
    if outstanding == 0 {
      break
    }
    // One release per completion, one completion consumed per acquire:
    // the counts stay balanced, so the driver never spins.
    completions.acquire()
    if inbox.length() == 0 {
      continue
    }
    let (name, outcome, duration_ms, start_ms, attempts) = inbox.remove(0)
    let code = outcome.code()
    running = running - 1
    outstanding = outstanding - 1
    runs.push(ActionRun::{
      task: name,
      outcome: Finished(outcome),
      duration_ms,
      start_ms,
      attempts,
    })
    if code != 0 {
      println("pkf: task `\{name}` failed with exit code \{code}")
      failed = true
      if exit_code == 0 {
        exit_code = code
      }
    }
    retire(name, code == 0, name)
    // Everything this action had to say is now printed. Push it out
    // rather than letting a pipe hold it until the run ends.
    flush_stdout()
  }
  ScheduleResult::{ exit_code, runs, wall_ms: now_ms() - started }
}

///|
/// One line at the end of a run saying what actually happened.
///
/// The per-task lines already say `# name (cache hit …)`, but in a
/// fifty-task build they scroll past and the reader is left asking the
/// only question that matters after a change: how much of this did we
/// actually redo? A count answers it without reading the log, and the
/// wall clock next to it is what a cache is for.
///
/// Printed for every run, not behind a flag: a summary you have to ask
/// for is one nobody sees.
fn report_summary(result : ScheduleResult) -> Unit {
  match summary_line(result) {
    Some(line) => println("pkf: " + line)
    None => ()
  }
}

///|
/// The summary text, or `None` when there is nothing worth saying.
///
/// Split from the printing so the counting can be tested: which
/// outcomes count as work is the part that can quietly go wrong, and a
/// summary that overstates what ran is worse than none.
fn summary_line(result : ScheduleResult) -> String? {
  let mut hits = 0
  let mut remote = 0
  let mut ran = 0
  let mut skipped = 0
  let mut reported = 0
  for run in result.runs {
    match run.outcome {
      Finished(LocalHit) => hits = hits + 1
      Finished(RemoteHit) => remote = remote + 1
      Finished(Ran(_)) => ran = ran + 1
      // An umbrella task spawns nothing, so it is not work; counting it
      // as "ran" would overstate what happened.
      Finished(Umbrella) => ()
      Finished(Reported) => reported = reported + 1
      Skipped(_) => skipped = skipped + 1
    }
  }
  // `--dry-run` and `--print-hash` printed a report per task; a summary
  // of work that did not happen would only be noise.
  if reported > 0 {
    return None
  }
  let total = hits + remote + ran + skipped
  if total == 0 {
    return None
  }
  let parts : Array[String] = ["\{total} task(s)"]
  let cached = hits + remote
  if cached > 0 {
    if remote > 0 && hits > 0 {
      parts.push("\{cached} cached (\{remote} remote)")
    } else if remote > 0 {
      parts.push("\{cached} cached (remote)")
    } else {
      parts.push("\{cached} cached")
    }
  }
  parts.push("\{ran} ran")
  if skipped > 0 {
    parts.push("\{skipped} skipped")
  }
  parts.push(format_ms(result.wall_ms))
  let mut line = ""
  for i, part in parts {
    if i > 0 {
      line = line + " · "
    }
    line = line + part
  }
  // The case worth calling out: nothing had to be redone.
  if ran == 0 && skipped == 0 && cached == total {
    line = line + "  (nothing to rebuild)"
  }
  Some(line)
}

///|
/// Render `--timing`.
///
/// Sequentially the interesting number is each task's duration and
/// their sum. In parallel the sum is meaningless — it exceeds the wall
/// clock — and the number that decides how long the build takes is the
/// critical path: the longest chain of actions that must run one after
/// another. Shortening anything off that path changes nothing.
fn report_timing(result : ScheduleResult, graph : ActionGraph) -> Unit {
  println("pkf: timing")
  for run in result.runs {
    match run.outcome {
      Finished(LocalHit) | Finished(RemoteHit) =>
        println("pkf:   \{run.task}  \{format_ms(run.duration_ms)}  (cached)")
      Finished(_) =>
        println(
          "pkf:   \{run.task}  \{format_ms(run.duration_ms)}" +
          "  (started +\{format_ms(run.start_ms)})",
        )
      Skipped(_) => println("pkf:   \{run.task}  skipped")
    }
  }
  println("pkf:   total  \{format_ms(result.wall_ms)} wall")
  let (length, chain) = critical_path(result, graph)
  if chain.length() > 1 {
    println("pkf:   critical path  \{format_ms(length)}  \{join_with(chain, " -> ")}")
  }
}

///|
/// The longest chain of actions that had to run in sequence, and how
/// long it took.
///
/// Computed over the graph's edges rather than over observed start
/// times: two actions that happened to run back to back because `-j 1`
/// forced them to are not a dependency chain, and reporting them as one
/// would send the reader optimizing an ordering the graph never
/// required.
fn critical_path(
  result : ScheduleResult,
  graph : ActionGraph,
) -> (Int64, Array[String]) {
  let duration : Map[String, Int64] = Map([], capacity=result.runs.length())
  for run in result.runs {
    duration[run.task] = run.duration_ms
  }
  // Longest finish time per action, plus the predecessor achieving it.
  let finish : Map[String, Int64] = Map([], capacity=graph.order.length())
  let prev : Map[String, String] = Map([], capacity=graph.order.length())
  // Chain length breaks ties. Without it a run whose actions all cost
  // the same reports a single action as "the critical path", when the
  // chain through it is what the wall clock was actually waiting on.
  let depth : Map[String, Int] = Map([], capacity=graph.order.length())
  let mut best = 0L
  let mut best_depth = 0
  let mut best_task = ""
  // `graph.order` is topological, so every producer is already final
  // by the time its consumer is visited.
  for name in graph.order {
    let own = duration.get(name).unwrap_or(0L)
    let mut longest = 0L
    let mut from = ""
    match graph.nodes.get(name) {
      Some(node) =>
        for edge in node.edges {
          match finish.get(edge.producer) {
            Some(f) =>
              if f > longest {
                longest = f
                from = edge.producer
              }
            None => ()
          }
        }
      None => ()
    }
    let total = longest + own
    finish[name] = total
    let own_depth = if from.length() > 0 {
      prev[name] = from
      depth.get(from).unwrap_or(0) + 1
    } else {
      1
    }
    depth[name] = own_depth
    if total > best || (total == best && own_depth > best_depth) {
      best = total
      best_depth = own_depth
      best_task = name
    }
  }
  let chain : Array[String] = []
  let mut cursor = best_task
  while cursor.length() > 0 {
    chain.push(cursor)
    cursor = prev.get(cursor).unwrap_or("")
  }
  chain.rev_in_place()
  (best, chain)
}

///|
/// Milliseconds as something a person reads: `840ms`, `3.2s`, `1m04s`.
fn format_ms(ms : Int64) -> String {
  if ms < 1000L {
    return "\{ms}ms"
  }
  if ms < 60_000L {
    let whole = ms / 1000L
    let tenths = ms % 1000L / 100L
    return "\{whole}.\{tenths}s"
  }
  let minutes = ms / 60_000L
  let seconds = ms % 60_000L / 1000L
  if seconds < 10L {
    "\{minutes}m0\{seconds}s"
  } else {
    "\{minutes}m\{seconds}s"
  }
}
