// Replaying a cached action's output.
//
// A cache hit used to print one line — `# build (cache hit 3f2a…)` —
// and nothing else. That is correct but not equivalent: the run that
// stored the entry printed a test summary, a bundle size, a list of
// warnings, and the hit printed none of it. So the output of a build
// depended on whether the cache happened to be warm, which makes CI
// logs unreadable and makes people distrust the cache. Turborepo
// solved this by storing the logs alongside the outputs and replaying
// them on a hit; this is the same idea.
//
// The logs live inside the entry archive under a reserved `.pkf-meta/`
// prefix, so a hit — local or remote — carries them. They are *output*,
// never input: nothing here may reach the action key, or a task's
// second run would key differently from its first.

///|
/// Archive members holding the stored streams.
///
/// The prefix is reserved: `validate_reserved_outputs` refuses a task
/// that declares an output under it, so a member with this name is
/// always ours and restoring it into the workspace is never right.
const LOG_STDOUT_MEMBER : String = ".pkf-meta/stdout"

///|
const LOG_STDERR_MEMBER : String = ".pkf-meta/stderr"

///|
/// The reserved prefix itself, for validation and for the restore-side
/// check.
const LOG_MEMBER_PREFIX : String = ".pkf-meta/"

///|
/// Per-stream cap on what is stored, in bytes.
///
/// A cache entry is fetched in full on every remote hit, so an
/// unbounded log turns a 2 KB entry into whatever a runaway `-v` build
/// printed. One mebibyte is past any output a person reads and far
/// short of a download anyone notices. Over the cap the *head* is kept:
/// it is a real prefix of what happened, and a truncation note says
/// what was dropped rather than leaving the reader to wonder why the
/// log stops mid-line.
const LOG_CAPTURE_CAP : Int = 1048576

///|
/// Whether an archive member is one of ours rather than a task output.
fn is_log_member(name : String) -> Bool {
  name.has_prefix(LOG_MEMBER_PREFIX)
}

///|
/// A task's captured streams. Mutable because it doubles as the sink
/// `cache_restore` fills in: the restore already walks every member,
/// and returning a second value through every caller in the chain would
/// be a larger change than the feature.
struct CapturedLogs {
  mut stdout : Bytes
  mut stderr : Bytes
}

///|
fn CapturedLogs::empty() -> CapturedLogs {
  CapturedLogs::{ stdout: Bytes::new(0), stderr: Bytes::new(0), }
}

///|
fn CapturedLogs::is_empty(self : CapturedLogs) -> Bool {
  self.stdout.length() == 0 && self.stderr.length() == 0
}

///|
/// FFI: write bytes to stdout (fd 1) verbatim, then flush.
#borrow(s)
extern "C" fn print_ffi(s : Bytes) -> Unit = "mizchi_pkf_print"

///|
/// Print a stored stream exactly as the command wrote it.
///
/// Verbatim: no added newline, no re-wrapping, no prefix. The point of
/// a replay is that the second run's transcript is indistinguishable
/// from the first's, and a `pkf: ` prefix or a normalised trailing
/// newline would make it distinguishable.
fn replay_logs(logs : CapturedLogs) -> Unit {
  // The `# name (cache hit …)` line above went into stdout's buffer,
  // which is block-buffered whenever stdout is not a terminal, while
  // stderr is not buffered at all. Without this a replayed stderr
  // stream overtakes the header that introduces it.
  flush_stdout()
  if logs.stdout.length() > 0 {
    print_ffi(logs.stdout)
  }
  if logs.stderr.length() > 0 {
    eprint_ffi(logs.stderr)
  }
}

///|
/// Trim a captured stream to the cap, appending a note when it had to.
///
/// The note goes on its own line, and starts one when the truncation
/// landed mid-line — otherwise it would be silently glued to the tail
/// of whatever the command was printing and read as part of it.
fn cap_log(data : Bytes, cap : Int) -> Bytes {
  if data.length() <= cap {
    return data
  }
  let buf = @buffer.Buffer(size_hint=cap + 64)
  buf.write_bytes(data[0:cap])
  append_truncation_note(buf, cap, data.length() - cap)
  buf.to_bytes()
}

///|
/// Close a truncated log with a line saying it was truncated.
///
/// A newline first when the cut landed mid-line, so the note reads as a
/// note rather than as the tail of whatever the command was printing.
fn append_truncation_note(
  buf : @buffer.Buffer,
  cap : Int,
  dropped : Int,
) -> Unit {
  let so_far = buf.to_bytes()
  if so_far.length() > 0 && so_far[so_far.length() - 1] != b'\n' {
    buf.write_byte(b'\n')
  }
  buf.write_bytes(
    @utf8.encode(
      "[pkf: log truncated at \{cap} bytes; \{dropped} more were not stored]\n",
    )[:],
  )
}

///|
/// Forward one of a child's streams to ours while accumulating it.
///
/// Chunks go out the moment they arrive, so a task under `-j 1` still
/// streams; the copy kept for the cache stops at the cap while the
/// forwarding does not, because what the user watches now should never
/// be shortened to suit what the cache stores.
async fn pump_stream(
  reader : @process.ReadFromProcess,
  to_stderr : Bool,
  cap : Int,
) -> Bytes {
  let buf = @buffer.Buffer(size_hint=4096)
  let mut seen = 0
  while (reader.read_some() catch { _ => None }) is Some(chunk) {
    if chunk.length() == 0 {
      continue
    }
    if to_stderr {
      eprint_ffi(chunk)
    } else {
      print_ffi(chunk)
    }
    if seen < cap {
      let room = cap - seen
      if chunk.length() <= room {
        buf.write_bytes(chunk[:])
      } else {
        buf.write_bytes(chunk[0:room])
      }
    }
    // Counted whether or not it was kept: past the cap the reading has
    // to continue, or the child blocks on a full pipe and the build
    // hangs. Only the keeping stops.
    seen = seen + chunk.length()
  }
  if seen > cap {
    append_truncation_note(buf, cap, seen - cap)
  }
  buf.to_bytes()
}

///|
/// Run a command, showing its output live *and* keeping a copy.
///
/// `run_inherit` hands the child our own file descriptors, which is why
/// a sequential run streams — and why nothing can be captured from it.
/// This gives the child pipes instead and copies through, which is the
/// only way to have both. The cost is that the child sees a pipe rather
/// than a terminal, so tools that colour their output conditionally
/// will turn colour off; that is why this is used only for actions
/// whose result is about to be cached, where a replayable log is the
/// point, and never for the uncacheable ones a person runs
/// interactively.
///
/// Returns `None` when the pipes could not be created, so the caller
/// can fall back to plain streaming rather than fail the task.
async fn tee_run(
  cmd : String,
  argv : Array[String],
  extra_env : Map[String, String],
  inherit_env : Bool,
  cwd : String,
  cap : Int,
) -> (Int, CapturedLogs)? {
  let (r_out, w_out) = @process.read_from_process() catch { _ => return None }
  let (r_err, w_err) = @process.read_from_process() catch { _ => return None }
  // Both readers must be running before the child fills a pipe buffer,
  // so they are spawned alongside the process rather than drained after
  // it exits — the latter deadlocks on any output past a pipe's worth.
  @async.with_task_group(group => {
    let exit_code = group.spawn(() => {
      @process.run(
        cmd.view(),
        argv[:],
        extra_env~,
        inherit_env~,
        stdout=w_out,
        stderr=w_err,
        cwd=cwd.view(),
      )
    })
    let out = group.spawn(() => {
      defer r_out.close()
      pump_stream(r_out, false, cap)
    })
    let err = group.spawn(() => {
      defer r_err.close()
      pump_stream(r_err, true, cap)
    })
    Some(
      (
        exit_code.wait(),
        CapturedLogs::{ stdout: out.wait(), stderr: err.wait(), },
      ),
    )
  })
}

///|
/// The first declared output that would collide with the reserved
/// prefix, if any.
///
/// Such a task cannot be cached correctly: `cache_store` would write
/// the file as a member and `cache_restore` would drop it as a log, so
/// the output would exist after the run that produced it and vanish on
/// every hit afterwards — the worst shape a cache bug can take, because
/// it only appears once the cache is warm. Refuse the Taskfile instead.
fn reserved_output_conflict(outputs : Array[String]) -> String? {
  for pattern in outputs {
    if pattern.has_prefix(LOG_MEMBER_PREFIX) {
      return Some(pattern)
    }
  }
  None
}

///|
/// The `, replaying logs` half of a cache-hit line, when there is
/// something to replay.
///
/// Only when there is: a task that printed nothing the first time
/// should not claim to be replaying anything, or the line becomes noise
/// on every silent task in the build.
fn replay_note(logs : CapturedLogs) -> String {
  if logs.is_empty() {
    ""
  } else {
    ", replaying logs"
  }
}
