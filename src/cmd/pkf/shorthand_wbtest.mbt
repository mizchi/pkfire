// Tests for the `pkf <task>` shorthand.
//
// The rule that has to hold is one-directional: a built-in wins, always.
// If a Taskfile could change what `pkf list` means, the command stops
// being learnable — you would have to read the repository to know what
// you typed. The behaviour is exercised end to end by the
// `shorthand-*` conformance scenarios; what is pinned here is the
// reserved list itself, which three places read and none may disagree
// about.

///|
test "every name run_main dispatches on is reserved" {
  // Drifting from the real dispatch is the failure that matters: a
  // subcommand missing here would be shadowable by a task, and one
  // listed but not dispatched would make `pkf <that>` unrunnable for no
  // reason. These are the arms of `run_main`'s match.
  for name in [
    "affected", "cache", "clean", "completion", "describe", "doctor", "explain",
    "format", "graph", "help", "hooks", "info", "init", "install", "lint",
    "list", "migrate", "pkl-cache", "run", "trace", "uninstall", "up",
    "version", "watch",
  ] {
    assert_true(is_builtin_subcommand(name))
  }
  assert_false(is_builtin_subcommand("build"))
  assert_false(is_builtin_subcommand("test:unit"))
  assert_false(is_builtin_subcommand(""))
}

///|
test "the reserved list has no duplicates and stays sorted" {
  // Sorted because it is read by a human deciding whether a task name
  // is safe, and deduplicated because a repeat would mean a subcommand
  // was added twice and one of the two is stale.
  for i in 1..<builtin_subcommands.length() {
    assert_true(lex_cmp(builtin_subcommands[i - 1], builtin_subcommands[i]) < 0)
  }
}

///|
test "a leading dash is never a task name" {
  // `pkf --verison` must stay an unknown *flag*, not become an unknown
  // task — the second reads as though the flag were understood and the
  // task was missing.
  assert_false(could_be_task_name("--verison"))
  assert_false(could_be_task_name("-j"))
  assert_false(could_be_task_name(""))
  assert_true(could_be_task_name("build"))
  // Task names may contain `:` `/` `.` and `-`, just not lead with one.
  assert_true(could_be_task_name("test:unit"))
  assert_true(could_be_task_name("check-translate/docs:DESIGN"))
  // A glob reaches the runner, which is the only thing that knows what
  // it matches.
  assert_true(could_be_task_name("test:*"))
}

///|
test "a task sharing a subcommand's name is reported, not silently shadowed" {
  let shadowed = graph_test_task("list", [], [], [], None)
  let fine = graph_test_task("build", [], [], [], None)
  let plan = graph_test_plan([shadowed, fine])
  assert_eq(builtin_shadowed_tasks(plan), ["list"])
  // A Taskfile with no collisions reports none.
  assert_eq(builtin_shadowed_tasks(graph_test_plan([fine])), [])
}

///|
test "shadowing is reported in declaration order, once per task" {
  let plan = graph_test_plan([
    graph_test_task("run", [], [], [], None),
    graph_test_task("build", [], [], [], None),
    graph_test_task("clean", [], [], [], None),
  ])
  assert_eq(builtin_shadowed_tasks(plan), ["run", "clean"])
}
