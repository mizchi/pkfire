// `pkf build` as shorthand for `pkf run build`.
//
// Running a task is the overwhelmingly common thing to do with this
// tool, and typing `run` for it every time is friction with no payoff.
// Every other task runner people reach for — npm, make, just, task —
// lets the task name stand on its own, so the `run` reads as ceremony.
//
// The rule is deliberately one-directional: **a built-in subcommand
// always wins.** A Taskfile that names a task `list` does not get to
// change what `pkf list` means, because a command whose meaning depends
// on the repository it is run in is a command nobody can learn. The
// shadowed task stays reachable as `pkf run list`, and `pkf lint`
// reports it so the collision is not silent.
//
// The fallback only fires when the name resolves to a real task, so
// `pkf lst` still says "unknown" rather than dying somewhere inside the
// runner, and a leading `-` is never treated as a task name.

///|
/// Every name `run_main` dispatches on before the fallback.
///
/// Kept as one list so the shorthand, the lint rule and the error
/// message cannot disagree about what is reserved — three copies of
/// this would drift the first time a subcommand is added.
let builtin_subcommands : Array[String] = [
  "affected", "cache", "clean", "completion", "describe", "doctor", "explain",
  "format", "graph", "help", "hooks", "info", "init", "install", "lint",
  "list", "migrate", "pkl-cache", "run", "trace", "uninstall", "up",
  "version", "watch",
]

///|
fn is_builtin_subcommand(name : String) -> Bool {
  builtin_subcommands.contains(name)
}

///|
/// Whether `token` could name a task at all.
///
/// A leading `-` is a flag, however malformed; treating `--verison` as a
/// task name would replace a clear "unknown flag" with a confusing
/// "unknown task". Empty is not a name either.
fn could_be_task_name(token : String) -> Bool {
  token.length() > 0 && !token.has_prefix("-")
}

///|
/// The Taskfile a command would use, or `None` when there is none.
///
/// `locate_taskfile` exits the process when it finds nothing, which is
/// right for a command that cannot proceed without one. The shorthand
/// needs to *ask*: outside a project, `pkf whatever` should say the
/// subcommand is unknown, not that a Taskfile is missing — the user was
/// not talking about a Taskfile.
fn find_taskfile(explicit : String?) -> String? {
  match explicit {
    Some(p) =>
      if @fs.path_exists(p) {
        let cwd = match @env.current_dir() {
          Some(dir) => dir
          None => "."
        }
        Some(absolute_lexical_path(p, cwd))
      } else {
        None
      }
    None => {
      let mut dir = match @env.current_dir() {
        Some(d) => d
        None => return None
      }
      while true {
        let candidate = dir + "/Taskfile.pkl"
        if @fs.path_exists(candidate) {
          return Some(candidate)
        }
        let parent = parent_dir(dir)
        if parent == dir {
          break
        }
        dir = parent
      }
      None
    }
  }
}

///|
/// Task names a built-in subcommand shadows.
///
/// Reachable only as `pkf run <name>`, which is what the lint rule
/// exists to say — a task you cannot invoke the way every other task is
/// invoked is a surprise worth surfacing at lint time rather than the
/// first time someone tries.
fn builtin_shadowed_tasks(plan : Plan) -> Array[String] {
  let out : Array[String] = []
  for name in plan.task_order {
    if is_builtin_subcommand(name) {
      out.push(name)
    }
  }
  out
}

///|
/// Report a first token that is neither a subcommand nor a task.
///
/// Both halves matter. `pkf buld` is a typo for a task and `pkf lst` is
/// a typo for a subcommand, and the message cannot know which — so it
/// offers whichever near misses exist on either side rather than
/// guessing, and says nothing when there are none.
fn suggest_unknown_command(token : String, plan : Plan?) -> Unit {
  eprintln("pkf: unknown subcommand or task `\{token}`")
  let threshold = if token.length() / 3 > 2 { token.length() / 3 } else { 2 }
  let near_commands : Array[String] = []
  for name in builtin_subcommands {
    if levenshtein(token, name) <= threshold {
      near_commands.push(name)
    }
  }
  let near_tasks : Array[String] = []
  match plan {
    Some(p) =>
      for name in p.task_order {
        if levenshtein(token, name) <= threshold {
          near_tasks.push(name)
        }
      }
    None => ()
  }
  if near_commands.length() > 0 {
    eprintln("  did you mean the subcommand: " + join_with(near_commands, ", "))
  }
  if near_tasks.length() > 0 {
    eprintln("  did you mean the task: " + join_with(near_tasks, ", "))
  }
  if near_commands.length() == 0 && near_tasks.length() == 0 {
    eprintln("  run `pkf help` for the subcommands, `pkf list` for the tasks")
  }
}
