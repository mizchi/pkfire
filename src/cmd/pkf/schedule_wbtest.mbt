// Tests for the scheduler's bookkeeping.
//
// The parts worth pinning are the ones a wrong answer makes silent: an
// in-degree that double-counts leaves an action permanently unrunnable,
// and a critical path computed from observed start times reports a
// chain the graph never required. Actually running actions concurrently
// is covered end to end by the `parallel-order` conformance scenario,
// which is where a scheduler bug shows up as a wrong result rather than
// a wrong number.

///|
test "an action linked to one producer twice has in-degree one" {
  // `consume` both declares `deps { gen }` and reads what `gen`
  // produces, so the graph carries one edge; counting the declared and
  // the derived link separately would leave it waiting for a second
  // completion that never comes.
  let gen = graph_test_task("gen", ["src/in.txt"], ["dist/out.txt"], [], None)
  let consume = graph_test_task(
    "consume", ["dist/out.txt"], [], ["gen"], None,
  )
  let plan = graph_test_plan([gen, consume])
  let graph = build_action_graph(plan, ".", ["consume"])
  let indegree = action_indegrees(graph)
  assert_eq(indegree.get("gen"), Some(0))
  assert_eq(indegree.get("consume"), Some(1))
}

///|
test "in-degree ignores edges to actions outside the run set" {
  // An umbrella task's dependency is in the set; a producer that only
  // the *lint* view of the graph would see is not. Counting an absent
  // producer would stall the action forever.
  let a = graph_test_task("a", [], [], [], None)
  let b = graph_test_task("b", [], [], ["a", "missing"], None)
  let plan = graph_test_plan([a, b])
  let graph = build_action_graph(plan, ".", ["b"])
  assert_eq(action_indegrees(graph).get("b"), Some(1))
}

///|
test "dependents are the reverse edges, deduplicated" {
  let gen = graph_test_task("gen", [], ["dist/**"], [], None)
  let one = graph_test_task("one", ["dist/a.js"], [], ["gen"], None)
  let two = graph_test_task("two", ["dist/b.js"], [], [], None)
  let plan = graph_test_plan([gen, one, two])
  let graph = build_action_graph(plan, ".", ["one", "two"])
  let dependents = action_dependents(graph)
  let of_gen = dependents.get("gen").unwrap()
  of_gen.sort_by(fn(a, b) { lex_cmp(a, b) })
  assert_eq(of_gen, ["one", "two"])
  assert_eq(dependents.get("one").unwrap(), [])
}

///|
/// A finished-run record, for the reporting tests.
fn finished_run(task : String, ms : Int64) -> ActionRun {
  ActionRun::{ task, outcome: Finished(Ran(0)), duration_ms: ms, start_ms: 0L }
}

///|
test "the critical path is the longest chain the graph required" {
  // `slow` and `quick` are independent; `join` waits for both. The
  // wall clock is bounded by slow -> join, and shortening `quick`
  // would change nothing.
  let slow = graph_test_task("slow", [], [], [], None)
  let quick = graph_test_task("quick", [], [], [], None)
  let join = graph_test_task("join", [], [], ["slow", "quick"], None)
  let plan = graph_test_plan([slow, quick, join])
  let graph = build_action_graph(plan, ".", ["join"])
  let result = ScheduleResult::{
    exit_code: 0,
    runs: [
      finished_run("slow", 900L),
      finished_run("quick", 100L),
      finished_run("join", 50L),
    ],
    wall_ms: 950L,
  }
  let (length, chain) = critical_path(result, graph)
  assert_eq(length, 950L)
  assert_eq(chain, ["slow", "join"])
}

///|
test "equal durations still report the chain, not one action" {
  // Three actions of the same cost: comparing totals alone leaves the
  // first one seen as the winner, and the report becomes a single name
  // that explains nothing about what was waiting on what.
  let a = graph_test_task("a", [], [], [], None)
  let b = graph_test_task("b", [], [], ["a"], None)
  let c = graph_test_task("c", [], [], ["b"], None)
  let plan = graph_test_plan([a, b, c])
  let graph = build_action_graph(plan, ".", ["c"])
  let result = ScheduleResult::{
    exit_code: 0,
    runs: [finished_run("a", 10L), finished_run("b", 0L), finished_run("c", 0L)],
    wall_ms: 10L,
  }
  let (length, chain) = critical_path(result, graph)
  assert_eq(length, 10L)
  assert_eq(chain, ["a", "b", "c"])
}

///|
test "a run with no dependencies has a one-action critical path" {
  let only = graph_test_task("only", [], [], [], None)
  let plan = graph_test_plan([only])
  let graph = build_action_graph(plan, ".", ["only"])
  let result = ScheduleResult::{
    exit_code: 0,
    runs: [finished_run("only", 42L)],
    wall_ms: 42L,
  }
  let (length, chain) = critical_path(result, graph)
  assert_eq(length, 42L)
  assert_eq(chain, ["only"])
}

///|
fn run_with(task : String, outcome : ActionOutcome) -> ActionRun {
  ActionRun::{ task, outcome, duration_ms: 0L, start_ms: 0L }
}

///|
fn summary_of(runs : Array[ActionRun], wall_ms : Int64) -> String? {
  summary_line(ScheduleResult::{ exit_code: 0, runs, wall_ms })
}

///|
test "the summary says how much of the run was skipped" {
  // The per-task `# name (cache hit …)` lines scroll past in a
  // fifty-task build. The question left afterwards is how much was
  // actually redone.
  assert_eq(
    summary_of(
      [
        run_with("a", Finished(LocalHit)),
        run_with("b", Finished(LocalHit)),
        run_with("c", Finished(Ran(0))),
      ],
      1500L,
    ),
    Some("3 task(s) · 2 cached · 1 ran · 1.5s"),
  )
}

///|
test "a fully cached run says nothing had to be rebuilt" {
  assert_eq(
    summary_of([run_with("a", Finished(LocalHit))], 3L),
    Some("1 task(s) · 1 cached · 0 ran · 3ms  (nothing to rebuild)"),
  )
  // Not the same claim when something was skipped after a failure:
  // work was left undone, which is not the same as nothing to do.
  assert_eq(
    summary_of(
      [run_with("a", Finished(LocalHit)), run_with("b", Skipped("a"))],
      3L,
    ),
    Some("2 task(s) · 1 cached · 0 ran · 1 skipped · 3ms"),
  )
}

///|
test "a remote hit is distinguished from a local one" {
  // Worth separating: a remote hit means the network was involved and
  // the entry came from somewhere else, which is the difference
  // between "my cache works" and "CI's cache works".
  assert_eq(
    summary_of([run_with("a", Finished(RemoteHit))], 40L),
    Some("1 task(s) · 1 cached (remote) · 0 ran · 40ms  (nothing to rebuild)"),
  )
  assert_eq(
    summary_of(
      [run_with("a", Finished(RemoteHit)), run_with("b", Finished(LocalHit))],
      40L,
    ),
    Some("2 task(s) · 2 cached (1 remote) · 0 ran · 40ms  (nothing to rebuild)"),
  )
}

///|
test "umbrella tasks and report modes are not counted as work" {
  // A deps-only task spawns nothing, so calling it "ran" would
  // overstate the build. `--dry-run` executed nothing at all, so a
  // summary of it would be a summary of nothing.
  assert_eq(
    summary_of(
      [run_with("all", Finished(Umbrella)), run_with("a", Finished(Ran(0)))],
      5L,
    ),
    Some("1 task(s) · 1 ran · 5ms"),
  )
  assert_eq(summary_of([run_with("a", Finished(Reported))], 5L), None)
  assert_eq(summary_of([], 5L), None)
  assert_eq(summary_of([run_with("all", Finished(Umbrella))], 5L), None)
}

///|
test "durations read the way a person reads a clock" {
  assert_eq(format_ms(0L), "0ms")
  assert_eq(format_ms(999L), "999ms")
  assert_eq(format_ms(1000L), "1.0s")
  assert_eq(format_ms(3240L), "3.2s")
  assert_eq(format_ms(59_999L), "59.9s")
  assert_eq(format_ms(60_000L), "1m00s")
  assert_eq(format_ms(64_000L), "1m04s")
  assert_eq(format_ms(725_000L), "12m05s")
}

///|
test "`-j auto` resolves to at least one job and stays bounded" {
  // The value is a process concurrency limit, and each process may be
  // a parallel build tool of its own — so a 128-core machine gets a
  // capped number rather than 128 concurrent compilers. Zero would
  // deadlock the scheduler, which never launches anything.
  let n = auto_jobs()
  assert_true(n >= 1)
  assert_true(n <= 16)
}

///|
test "a skipped action is distinguishable from one that ran" {
  // Both end a run without producing outputs; only one of them is a
  // failure the user needs to look at.
  assert_true(Skipped("build") == Skipped("build"))
  assert_false(Skipped("build") == Skipped("test"))
  assert_false(Skipped("build") == Finished(Ran(0)))
  assert_false(Finished(Ran(0)) == Finished(Ran(1)))
  // A cache hit and a run are both "finished" and both exit 0; only
  // the outcome tells them apart, which is what the summary counts.
  assert_false(Finished(LocalHit) == Finished(Ran(0)))
}
