// ---------------------------------------------------------------------------
// Action execution log (`--execution-log=FILE`).
//
// `--timing` prints what happened, and printing is where the record
// ends: the numbers scroll past, the shape is fixed, and nothing else
// can read them. Bazel's execution log exists because the questions
// that matter after a build — which actions actually ran, how the wall
// clock was spent, whether CI's cache is behaving — are asked by
// tooling, over many runs, long after the terminal is gone.
//
// The format is JSON Lines rather than one JSON document, for two
// reasons. A line at a time is what `jq`, `grep` and a spreadsheet
// import all take without ceremony. And a run that dies partway still
// leaves every completed line valid and readable, which is exactly the
// run whose log you most want to read.
//
// One `kind: "action"` line per action in completion order, then a
// single `kind: "summary"` line. The summary is last so a reader that
// streams the file sees each action as it is recorded rather than
// waiting on a header it cannot have yet.
// ---------------------------------------------------------------------------

///|
/// Schema version, carried on the summary line.
///
/// A consumer that reads a field this runner later renames should be
/// able to say so rather than silently reporting zeroes.
const EXECUTION_LOG_VERSION : Int = 1

///|
/// The stable name for an outcome, as it appears in the log.
///
/// Deliberately not the enum's own spelling: `TaskOutcome` is internal
/// and free to be renamed, and a log consumers parse is not. Splitting
/// `cached` into `local` and `remote` is the point of the field — a
/// remote hit and a local hit cost very different amounts of time.
fn execution_log_status(outcome : ActionOutcome) -> String {
  match outcome {
    Finished(Ran(_)) => "ran"
    Finished(LocalHit) => "cached-local"
    Finished(RemoteHit) => "cached-remote"
    Finished(Umbrella) => "umbrella"
    Finished(Reported) => "reported"
    Skipped(_) => "skipped"
  }
}

///|
/// One action's record.
fn execution_log_action(run : ActionRun) -> Json {
  let o : Map[String, Json] = Map([], capacity=8)
  o["kind"] = Json::string("action")
  o["task"] = Json::string(run.task)
  o["status"] = Json::string(execution_log_status(run.outcome))
  // Only ever meaningful for an action that ran. Emitting `0` for a
  // cache hit would read as "ran and succeeded", which is the one
  // confusion this log exists to prevent.
  match run.outcome {
    Finished(Ran(code)) => o["exitCode"] = Json::number(code.to_double())
    // What blocked it is the whole content of a skip: a list of skipped
    // names without causes cannot be traced back to the failure.
    Skipped(cause) => o["blockedBy"] = Json::string(cause)
    _ => ()
  }
  o["startMs"] = Json::number(run.start_ms.to_double())
  o["durationMs"] = Json::number(run.duration_ms.to_double())
  // Only when it means something. A `"attempts":1` on every line of a
  // fifty-action log is noise; a `"attempts":4` is the whole reason
  // anyone greps this file for flakiness.
  if run.attempts > 1 {
    o["attempts"] = Json::number(run.attempts.to_double())
  }
  Json::object(o)
}

///|
/// The trailing summary line.
///
/// Carries the critical path because it cannot be recovered from the
/// action lines alone: it is a property of the graph's edges, and the
/// log does not record edges. A consumer computing "the longest chain
/// of observed start times" would get a different, wrong answer under
/// `-j 1`, where everything runs back to back whether or not it had to.
fn execution_log_summary(
  result : ScheduleResult,
  critical_ms : Int64,
  critical_chain : Array[String],
) -> Json {
  let o : Map[String, Json] = Map([], capacity=8)
  o["kind"] = Json::string("summary")
  o["version"] = Json::number(EXECUTION_LOG_VERSION.to_double())
  o["exitCode"] = Json::number(result.exit_code.to_double())
  o["wallMs"] = Json::number(result.wall_ms.to_double())
  o["actions"] = Json::number(result.runs.length().to_double())
  let mut ran = 0
  let mut cached = 0
  let mut skipped = 0
  for run in result.runs {
    match run.outcome {
      Finished(Ran(_)) => ran = ran + 1
      Finished(LocalHit) | Finished(RemoteHit) => cached = cached + 1
      Skipped(_) => skipped = skipped + 1
      _ => ()
    }
  }
  o["ran"] = Json::number(ran.to_double())
  o["cached"] = Json::number(cached.to_double())
  o["skipped"] = Json::number(skipped.to_double())
  // Actions that needed more than one attempt. Zero is the number a
  // dashboard wants to alert on drifting away from, so it is always
  // present rather than omitted when empty.
  let mut retried = 0
  for run in result.runs {
    if run.attempts > 1 {
      retried = retried + 1
    }
  }
  o["retried"] = Json::number(retried.to_double())
  // A single-action "chain" is not a chain; reporting one would invite
  // a reader to optimize an ordering the graph never imposed.
  if critical_chain.length() > 1 {
    o["criticalPathMs"] = Json::number(critical_ms.to_double())
    o["criticalPath"] = jstr_array(critical_chain)
  }
  Json::object(o)
}

///|
/// The whole log as text, ready to write.
///
/// Built as a string rather than streamed to the file so a failed run
/// cannot leave a half-written log behind that looks complete: the file
/// appears at its final size or not at all.
fn render_execution_log(
  result : ScheduleResult,
  critical_ms : Int64,
  critical_chain : Array[String],
) -> String {
  let sb = StringBuilder()
  for run in result.runs {
    sb.write_string(execution_log_action(run).stringify())
    sb.write_string("\n")
  }
  sb.write_string(
    execution_log_summary(result, critical_ms, critical_chain).stringify(),
  )
  sb.write_string("\n")
  sb.to_string()
}

///|
/// Write the log for `result` to `path`.
///
/// Reports a problem to stderr but never changes the run's exit code:
/// an unwritable log directory is a reason to hear about it, not a
/// reason to fail a build that already succeeded.
fn write_execution_log(
  path : String,
  result : ScheduleResult,
  graph : ActionGraph,
) -> Unit {
  let (critical_ms, critical_chain) = critical_path(result, graph)
  let text = render_execution_log(result, critical_ms, critical_chain)
  let parent = dirname(path)
  if parent.length() > 0 {
    mkdir_p(parent)
  }
  @fs.write_bytes_to_file(path, @utf8.encode(text)) catch {
    _ => eprintln("pkf: could not write execution log to \{path}")
  }
}
