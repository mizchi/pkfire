// Tests for the execution log's encoding.
//
// A log is a contract with a consumer that is not in this repository,
// so the parts pinned here are the ones a change would break silently:
// the status vocabulary, and the fields that are present or absent for
// each status. A log that emits `exitCode: 0` for a cache hit parses
// perfectly and reports the opposite of what happened.

///|
fn log_run(
  task : String,
  outcome : ActionOutcome,
  start_ms : Int64,
  duration_ms : Int64,
  attempts~ : Int = 1,
) -> ActionRun {
  ActionRun::{ task, outcome, duration_ms, start_ms, attempts }
}

///|
fn log_lines(
  runs : Array[ActionRun],
  wall_ms : Int64,
  exit_code~ : Int = 0,
  critical_ms~ : Int64 = 0L,
  chain~ : Array[String] = [],
) -> Array[String] {
  let text = render_execution_log(
    ScheduleResult::{ exit_code, runs, wall_ms },
    critical_ms,
    chain,
  )
  let out : Array[String] = []
  for line in text.split("\n") {
    let s = line.to_owned()
    if s.length() > 0 {
      out.push(s)
    }
  }
  out
}

///|
test "each outcome has its own status name" {
  // `cached` alone would collapse a local hit and a remote fetch, which
  // is the distinction anyone reading the log for cache behaviour is
  // there for.
  assert_eq(execution_log_status(Finished(Ran(0))), "ran")
  assert_eq(execution_log_status(Finished(LocalHit)), "cached-local")
  assert_eq(execution_log_status(Finished(RemoteHit)), "cached-remote")
  assert_eq(execution_log_status(Finished(Umbrella)), "umbrella")
  assert_eq(execution_log_status(Finished(Reported)), "reported")
  assert_eq(execution_log_status(Skipped("build")), "skipped")
}

///|
test "an action that ran carries its exit code" {
  let json = execution_log_action(log_run("test", Finished(Ran(3)), 10L, 42L))
  match json {
    Object(o) => {
      assert_eq(o.get("task"), Some(Json::string("test")))
      assert_eq(o.get("status"), Some(Json::string("ran")))
      assert_eq(o.get("exitCode"), Some(Json::number(3)))
      assert_eq(o.get("startMs"), Some(Json::number(10)))
      assert_eq(o.get("durationMs"), Some(Json::number(42)))
    }
    _ => fail("expected an object")
  }
}

///|
test "a cache hit has no exit code at all" {
  // Not `exitCode: 0`: a consumer filtering on "actions that exited
  // zero" must not pick up work that never ran.
  match execution_log_action(log_run("build", Finished(LocalHit), 0L, 1L)) {
    Object(o) => {
      assert_eq(o.get("exitCode"), None)
      assert_eq(o.get("blockedBy"), None)
    }
    _ => fail("expected an object")
  }
}

///|
test "a skipped action names what blocked it" {
  // A list of skipped names with no causes cannot be traced back to the
  // one failure that produced all of them.
  match execution_log_action(log_run("deploy", Skipped("build"), 0L, 0L)) {
    Object(o) => {
      assert_eq(o.get("blockedBy"), Some(Json::string("build")))
      assert_eq(o.get("exitCode"), None)
    }
    _ => fail("expected an object")
  }
}

///|
test "the summary counts the same way the printed summary does" {
  let runs = [
    log_run("a", Finished(Ran(0)), 0L, 10L),
    log_run("b", Finished(LocalHit), 10L, 1L),
    log_run("c", Finished(RemoteHit), 11L, 2L),
    log_run("d", Finished(Umbrella), 13L, 0L),
    log_run("e", Skipped("a"), 0L, 0L),
  ]
  match execution_log_summary(
      ScheduleResult::{ exit_code: 1, runs, wall_ms: 13L },
      0L,
      [],
    ) {
    Object(o) => {
      assert_eq(o.get("kind"), Some(Json::string("summary")))
      assert_eq(o.get("version"), Some(Json::number(1)))
      assert_eq(o.get("exitCode"), Some(Json::number(1)))
      assert_eq(o.get("wallMs"), Some(Json::number(13)))
      assert_eq(o.get("actions"), Some(Json::number(5)))
      assert_eq(o.get("ran"), Some(Json::number(1)))
      // An umbrella is not work, exactly as `summary_line` has it.
      assert_eq(o.get("cached"), Some(Json::number(2)))
      assert_eq(o.get("skipped"), Some(Json::number(1)))
    }
    _ => fail("expected an object")
  }
}

///|
test "a one-action chain is not reported as a critical path" {
  match execution_log_summary(
      ScheduleResult::{ exit_code: 0, runs: [], wall_ms: 5L },
      5L,
      ["only"],
    ) {
    Object(o) => assert_eq(o.get("criticalPath"), None)
    _ => fail("expected an object")
  }
}

///|
test "a real chain is carried on the summary" {
  // It cannot be recovered from the action lines: the log records no
  // edges, and start times under `-j 1` make everything look chained.
  match execution_log_summary(
      ScheduleResult::{ exit_code: 0, runs: [], wall_ms: 9L },
      9L,
      ["gen", "build"],
    ) {
    Object(o) => {
      assert_eq(o.get("criticalPathMs"), Some(Json::number(9)))
      assert_eq(
        o.get("criticalPath"),
        Some(Json::array([Json::string("gen"), Json::string("build")])),
      )
    }
    _ => fail("expected an object")
  }
}

///|
test "the log is one line per action, summary last" {
  // Streaming order: a reader tailing the file sees each action as it
  // is recorded, rather than waiting on a header that cannot exist yet.
  let lines = log_lines(
    [
      log_run("a", Finished(Ran(0)), 0L, 1L),
      log_run("b", Finished(LocalHit), 1L, 0L),
    ],
    2L,
  )
  assert_eq(lines.length(), 3)
  assert_true(lines[0].contains("\"task\":\"a\""))
  assert_true(lines[1].contains("\"task\":\"b\""))
  assert_true(lines[2].contains("\"kind\":\"summary\""))
}

///|
test "an empty run still produces a readable summary" {
  // `pkf run` on a graph with nothing to do must leave a valid file,
  // not a zero-byte one a consumer reads as a crash.
  let lines = log_lines([], 0L)
  assert_eq(lines.length(), 1)
  assert_true(lines[0].contains("\"actions\":0"))
}

///|
test "a single attempt is not spelled out on the line" {
  // `"attempts":1` on every line of a fifty-action log is noise. The
  // field exists to make the exceptional case findable.
  match execution_log_action(log_run("build", Finished(Ran(0)), 0L, 1L)) {
    Object(o) => assert_eq(o.get("attempts"), None)
    _ => fail("expected an object")
  }
}

///|
test "a retried action carries its attempt count" {
  match
    execution_log_action(
      log_run("test", Finished(Ran(0)), 0L, 9L, attempts=3),
    ) {
    Object(o) => assert_eq(o.get("attempts"), Some(Json::number(3)))
    _ => fail("expected an object")
  }
}

///|
test "the summary always reports how many actions were retried" {
  // Always present, including as zero: a dashboard alerts on this
  // drifting away from zero, and a field that disappears when empty
  // reads as a parse failure rather than as good news.
  let quiet = [log_run("a", Finished(Ran(0)), 0L, 1L)]
  match
    execution_log_summary(
      ScheduleResult::{ exit_code: 0, runs: quiet, wall_ms: 1L },
      0L,
      [],
    ) {
    Object(o) => assert_eq(o.get("retried"), Some(Json::number(0)))
    _ => fail("expected an object")
  }
  let flaky = [
    log_run("a", Finished(Ran(0)), 0L, 1L, attempts=2),
    log_run("b", Finished(Ran(0)), 1L, 1L),
    log_run("c", Finished(Ran(1)), 2L, 1L, attempts=4),
  ]
  match
    execution_log_summary(
      ScheduleResult::{ exit_code: 1, runs: flaky, wall_ms: 3L },
      0L,
      [],
    ) {
    Object(o) => assert_eq(o.get("retried"), Some(Json::number(2)))
    _ => fail("expected an object")
  }
}
