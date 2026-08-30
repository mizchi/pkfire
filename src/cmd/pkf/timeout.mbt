// Running a command under a deadline, and killing what it started.
//
// A timeout that stops *waiting* is not a timeout. `with_timeout_opt`
// around the ordinary spawn returns promptly and leaves the command
// running: `bash -c "sleep 60"` outlives the cancel because the signal
// reaches the shell, not the `sleep` it forked. The run then looks
// finished while a runaway process keeps holding a port, a lock, or a
// CPU — which is the situation the timeout existed to prevent.
//
// So a timed task is spawned in its own process group and torn down
// through `signal_pid_tree`, the same SIGTERM-then-SIGKILL walk that
// stops a service. That needs the child's pid, which only
// `@process.spawn` hands back — `run_inherit` and `collect_output` do
// not — so this is a separate path.
//
// It is *only* taken when `timeoutSeconds > 0`. The untimed paths are
// left exactly as they were, because they carry behaviour worth not
// disturbing: `run_inherit` gives the command the real terminal, and
// the tee forwards output as it arrives. Duplicating a little spawn
// code is cheaper than making every task pay for a feature most tasks
// do not use.

///|
/// Seconds to wait after SIGTERM before SIGKILL.
///
/// The same five seconds a service teardown allows, and for the same
/// reason: a command that traps SIGTERM to flush a log or remove a
/// lockfile should get to finish, and one that ignores it should not
/// get to stay.
const TIMEOUT_GRACE_SECONDS : Int = 5

///|
/// Exit code reported for a task killed by its timeout.
///
/// 128 + SIGTERM, the shell convention, so a CI log reading only the
/// number still says "terminated" rather than inventing a meaning for
/// a code the command never chose.
const TIMEOUT_EXIT_CODE : Int = 143

///|
/// Run `argv` under `shell` with a deadline.
///
/// Returns the exit status and, when `capture` is set, the streams —
/// which are forwarded as they arrive either way, so a task with a
/// timeout is no less watchable than one without.
///
/// `None` for the status means the deadline passed and the process
/// tree was killed.
async fn[X] run_with_deadline(
  group : @async.TaskGroup[X],
  shell : String,
  argv : Array[String],
  extra_env : Map[String, String],
  inherit_env : Bool,
  cwd : String,
  capture : Bool,
  timeout_seconds : Int,
  cap : Int,
) -> (Int?, CapturedLogs) {
  let logs = CapturedLogs::empty()
  // Pipes only when there is something to capture. Without them the
  // child inherits this process's descriptors, which is what keeps an
  // uncached, untee'd task talking to the real terminal.
  let pipes = if capture {
    let out = @process.read_from_process() catch { _ => return (None, logs) }
    let err = @process.read_from_process() catch { _ => return (None, logs) }
    Some((out, err))
  } else {
    None
  }
  let proc = match pipes {
    Some(((_, w_out), (_, w_err))) =>
      @process.spawn(
        group,
        shell.view(),
        argv[:],
        extra_env~,
        inherit_env~,
        stdout=w_out,
        stderr=w_err,
        cwd=cwd.view(),
        no_wait=true,
        new_process_group=true,
      )
    None =>
      @process.spawn(
        group,
        shell.view(),
        argv[:],
        extra_env~,
        inherit_env~,
        cwd=cwd.view(),
        no_wait=true,
        new_process_group=true,
      )
  }
  // The readers must be running while the process does, or a child
  // that fills a pipe buffer blocks and the deadline fires on a
  // command that was only ever waiting for us to read.
  let pumps = match pipes {
    Some(((r_out, _), (r_err, _))) =>
      Some(
        (
          group.spawn(() => {
            defer r_out.close()
            pump_stream(r_out, false, cap)
          }),
          group.spawn(() => {
            defer r_err.close()
            pump_stream(r_err, true, cap)
          }),
        ),
      )
    None => None
  }
  let status = @async.with_timeout_opt(timeout_seconds * 1000, () => proc.wait())
  if status is None {
    // The shell is not the only thing to kill, and the order matters:
    // see `signal_command_tree`.
    // Enumerated before anything is signalled — see `descendant_pids`.
    let tree = descendant_pids(proc.pid)
    signal_command_tree(proc.pid, tree, "TERM")
    // Poll rather than sleep the whole grace period: a command that
    // handles SIGTERM usually exits immediately, and waiting five
    // seconds to confirm that would make every timeout five seconds
    // longer than it needs to be.
    let mut exited = false
    for _ in 0..<(TIMEOUT_GRACE_SECONDS * 20) {
      if (proc.try_wait() catch { _ => None }) is Some(_) {
        exited = true
        break
      }
      @async.sleep(50)
    }
    if !exited {
      signal_command_tree(proc.pid, tree, "KILL")
    }
    try proc.wait() |> ignore catch {
      _ => ()
    }
  }
  match pumps {
    Some((out, err)) => {
      logs.stdout = out.wait()
      logs.stderr = err.wait()
    }
    None => ()
  }
  (status, logs)
}

///|
/// Every descendant of `pid`, deepest last.
///
/// Collected *before* anything is signalled: once the shell dies its
/// children are reparented to init, and `pgrep -P <shell>` then finds
/// nothing. Enumerating first is what makes it possible to kill the
/// shell before its children — which is the ordering that matters,
/// because a shell whose child dies first notices, moves on, and runs
/// the next line of a script that was supposed to have been stopped.
async fn descendant_pids(pid : Int) -> Array[Int] {
  let out : Array[Int] = []
  let frontier = [pid]
  let mut i = 0
  while i < frontier.length() {
    let parent = frontier[i]
    i = i + 1
    let (code, listed, _) = @process.collect_output(
      "pgrep",
      ["-P", parent.to_string()][:],
    )
    if code != 0 {
      continue
    }
    for line in @utf8.decode_lossy(listed.binary()).split("\n") {
      let text = trim_ascii(line.to_owned())
      if text.length() == 0 {
        continue
      }
      let child = @string.parse_int(text) catch { _ => continue }
      if child > 0 && !out.contains(child) {
        out.push(child)
        frontier.push(child)
      }
    }
  }
  out
}

///|
/// Signal a command's shell and everything it started, in one call.
///
/// The shell is listed first so it receives the signal before — or at
/// worst with — the child it is waiting on. Signalling the child first
/// is what let `sleep 60; echo never` print `never` after its deadline:
/// the shell saw its child die, concluded the command had finished, and
/// carried on. `new_process_group` would have made this a single group
/// kill, but it does not reliably take (the spawned shell's pgid is not
/// its own pid), so the tree is enumerated instead of assumed.
async fn signal_command_tree(
  pid : Int,
  descendants : Array[Int],
  signal_name : String,
) -> Unit {
  let targets = ["-" + signal_name, pid.to_string()]
  for child in descendants {
    targets.push(child.to_string())
  }
  try @process.collect_output("kill", targets[:]) |> ignore catch {
    _ => ()
  }
}
