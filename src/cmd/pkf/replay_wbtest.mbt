// Tests for cached-log capture and replay.
//
// The live pumping is exercised end to end by the `cache-hit-replays-
// logs` conformance scenario, where a wrong answer is a missing or
// duplicated transcript. What is worth pinning here is the quiet part:
// a cap that silently drops the note, a member prefix that stops
// matching, or a log that leaks into the action key.

///|
fn log_text(data : Bytes) -> String {
  @utf8.decode_lossy(data)
}

///|
test "a log under the cap is stored byte for byte" {
  let data = @utf8.encode("hello\n")
  assert_eq(log_text(cap_log(data, 1024)), "hello\n")
  // Exactly at the cap is still not truncation.
  assert_eq(log_text(cap_log(data, 6)), "hello\n")
}

///|
test "truncation keeps the head and says how much it dropped" {
  // The head, not the tail: it is a real prefix of what happened, so
  // everything the reader sees is something the command actually
  // printed in that order.
  let data = @utf8.encode("abcdefghij")
  let out = log_text(cap_log(data, 4))
  assert_true(out.has_prefix("abcd\n"))
  assert_true(out.contains("truncated at 4 bytes"))
  assert_true(out.contains("6 more"))
  assert_false(out.contains("efgh"))
}

///|
test "a truncation landing on a line boundary does not add a blank line" {
  let data = @utf8.encode("one\ntwo\n")
  let out = log_text(cap_log(data, 4))
  assert_true(out.has_prefix("one\n[pkf:"))
}

///|
test "the reserved prefix is what tells a log from an output" {
  assert_true(is_log_member(LOG_STDOUT_MEMBER))
  assert_true(is_log_member(LOG_STDERR_MEMBER))
  assert_false(is_log_member("dist/app.js"))
  // Not a prefix match on the bare name: a task's own `.pkf-metadata`
  // file is its own business.
  assert_false(is_log_member(".pkf-metadata/x"))
  // Reserved members are still ordinary tar paths, so the traversal
  // check must accept them — a restore that rejected the whole entry
  // over its own log member would turn every hit into a miss.
  assert_true(is_safe_archive_path(LOG_STDOUT_MEMBER))
  assert_true(is_safe_archive_path(LOG_STDERR_MEMBER))
}

///|
test "a task may not declare an output inside the reserved prefix" {
  // Otherwise the entry would carry a member the restore drops as a
  // log, and the task's declared output would vanish on every hit.
  assert_true(reserved_output_conflict([".pkf-meta/stdout"]) is Some(_))
  assert_true(reserved_output_conflict([".pkf-meta/**"]) is Some(_))
  assert_true(reserved_output_conflict(["dist/**", ".pkf-meta/x"]) is Some(_))
  assert_true(reserved_output_conflict(["dist/**"]) is None)
  assert_true(reserved_output_conflict([".pkf-metadata/x"]) is None)
}

///|
test "captured logs are output, and never reach the action key" {
  // The key is computed before the command runs, so a log cannot be an
  // input without making a task's first run key differently from its
  // second — every entry would be stored under a key nothing ever
  // looks up again. This pins that the descriptor has no room for one.
  let task = graph_test_task("t", ["src/**"], ["dist/**"], [], None)
  let plan = graph_test_plan([task])
  let action = action_for_task(
    plan,
    task,
    ".",
    Map([]),
    [],
    RunOptions::default(),
  )
  let described = describe_action(action)
  assert_false(described.contains(".pkf-meta"))
  assert_false(described.contains("stdout"))
}

///|
test "an empty capture replays nothing, so a hit stays a one-liner" {
  let logs = CapturedLogs::empty()
  assert_true(logs.is_empty())
  logs.stdout = @utf8.encode("x")
  assert_false(logs.is_empty())
}
