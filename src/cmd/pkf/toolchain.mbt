// Resolving toolchains instead of taking their word for it.
//
// `tools { ["go"] = "1.26.2" }` is a string the author types and then
// has to remember to change. Nothing checks it: upgrade Go and the
// action key does not move, so every cached entry built by the old
// compiler stays a hit. It is a cache salt wearing a toolchain's name.
//
// A `Toolchain` is the same declaration made checkable. pkfire resolves
// it — finds the executable on `PATH`, asks it its version, optionally
// hashes its bytes — and puts what it *observed* into the action key.
// Upgrade Go and the key moves because the version string moved, with
// nothing to remember.
//
// What deliberately does not reach the key is the resolved path.
// `/opt/homebrew/bin/go` and `/usr/bin/go` are the same toolchain as
// far as a build is concerned, and hashing the path would split the
// cache between two machines that should share it — which is the whole
// reason a remote cache exists. The path is reported by
// `pkf explain`, where a human debugging a miss wants it.

///|
/// A declared external tool whose identity is part of the action key.
struct Toolchain {
  /// Executable to resolve on `PATH`, or an absolute path.
  name : String
  /// Command printing the version. Empty means `<name> --version`.
  version_cmd : String
  /// Hash the resolved executable's bytes as well as its version.
  hash_binary : Bool
  /// Whether the task can run without it.
  optional : Bool
  /// Executable to resolve instead of `name` when the task builds for
  /// a given target platform. This is the constraint that makes a
  /// toolchain a resolver: the declaration is one thing, and which
  /// compiler it selects depends on what the task is building for.
  for_target : Map[String, String]
}

///|
/// The executable `tc` resolves to when building for `target`.
///
/// A target with no entry falls back to the declared name, so a native
/// build needs no special case and an unrecognised target degrades to
/// the host compiler rather than to an error — the command will say
/// what it thinks of that better than the runner can.
fn toolchain_executable(tc : Toolchain, target : String) -> String {
  if target.length() == 0 {
    return tc.name
  }
  match tc.for_target.get(target) {
    Some(selected) => selected
    None => tc.name
  }
}

///|
/// What resolution found.
struct ResolvedToolchain {
  /// Absolute path, or empty when the tool was not found. Reported,
  /// never hashed.
  path : String
  /// First line of the version command's output, trimmed. Empty when
  /// the tool was not found or the command failed.
  version : String
  /// Hex digest of the executable, when `hash_binary` asked for one.
  digest : String
  found : Bool
  /// The executable actually selected — `name`, or the `forTarget`
  /// entry that matched. Recorded in the key: two cross compilers can
  /// report the same version string, and the selection is the fact
  /// that distinguishes them.
  executable : String
}

///|
/// Resolutions already performed in this process.
///
/// A monorepo declares the same compiler on thirty tasks, and each
/// resolution is two subprocesses. Doing it once per distinct
/// declaration keeps `pkf run` from spending more time interrogating
/// its tools than running them. Within a single run the answer cannot
/// change — and if it did, a key computed from two different answers
/// would be worse than one computed from a stale one.
let toolchain_memo : Map[String, ResolvedToolchain] = Map([], capacity=8)

///|
fn toolchain_memo_key(tc : Toolchain, target : String) -> String {
  // The selected executable, not the declared name: one `cc`
  // declaration resolves to a different compiler per target, and
  // sharing one memo slot between them would hand the second target
  // the first one's version.
  toolchain_executable(tc, target) +
  "\u{1F}" +
  tc.version_cmd +
  "\u{1F}" +
  tc.hash_binary.to_string()
}

///|
/// The version command to run for `tc` when it resolved to
/// `executable`.
///
/// The default probe follows the selection: a `cc` that resolved to
/// `aarch64-linux-gnu-gcc` must be asked *its* version, not the host
/// compiler's. An explicit `versionCmd` is taken literally, since an
/// author who wrote one has said what to run.
fn toolchain_version_command(tc : Toolchain, executable : String) -> String {
  if tc.version_cmd.length() > 0 {
    tc.version_cmd
  } else {
    executable + " --version"
  }
}

///|
/// First non-empty line, trimmed.
///
/// Version commands are chatty — `go version go1.26.2 darwin/arm64`,
/// or three lines of banner before the number. The first line is the
/// version by near-universal convention, and taking all of it would
/// put a build timestamp or a plugin list into the key.
fn first_line(text : String) -> String {
  for line in text.split("\n") {
    let trimmed = trim_ascii(line.to_owned())
    if trimmed.length() > 0 {
      return trimmed
    }
  }
  ""
}

///|
fn trim_ascii(text : String) -> String {
  let chars : Array[Char] = []
  for ch in text {
    chars.push(ch)
  }
  fn is_space(ch : Char) -> Bool {
    ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n'
  }

  let mut start = 0
  let mut end = chars.length()
  while start < end && is_space(chars[start]) {
    start = start + 1
  }
  while end > start && is_space(chars[end - 1]) {
    end = end - 1
  }
  let buf = StringBuilder()
  for i in start..<end {
    buf.write_char(chars[i])
  }
  buf.to_string()
}

///|
/// Find, interrogate and optionally hash one toolchain.
async fn resolve_toolchain(
  tc : Toolchain,
  shell : String,
  target : String,
) -> ResolvedToolchain {
  let executable = toolchain_executable(tc, target)
  let memo_key = toolchain_memo_key(tc, target)
  match toolchain_memo.get(memo_key) {
    Some(cached) => return cached
    None => ()
  }
  // `command -v` rather than `which`: POSIX, built into the shell, and
  // it reports the same executable the command itself will get.
  let (locate_code, located, _) = @process.collect_output(
    shell.view(),
    ["-c", "command -v " + shell_quote(executable)][:],
  )
  let path = if locate_code == 0 {
    first_line(@utf8.decode_lossy(located.binary()))
  } else {
    ""
  }
  if path.length() == 0 {
    let missing = ResolvedToolchain::{
      path: "",
      version: "",
      digest: "",
      found: false,
      executable,
    }
    toolchain_memo[memo_key] = missing
    return missing
  }
  let (version_code, out, err) = @process.collect_output(
    shell.view(),
    ["-c", toolchain_version_command(tc, executable)][:],
  )
  // Version banners land on stdout or stderr depending on the tool, so
  // both are considered rather than guessing which one this tool picked.
  let printed = @utf8.decode_lossy(out.binary())
  let version = if version_code == 0 {
    let from_stdout = first_line(printed)
    if from_stdout.length() > 0 {
      from_stdout
    } else {
      first_line(@utf8.decode_lossy(err.binary()))
    }
  } else {
    ""
  }
  let digest = if tc.hash_binary {
    hex_encode(hash_file(path))
  } else {
    ""
  }
  let resolved = ResolvedToolchain::{
    path,
    version,
    digest,
    found: true,
    executable,
  }
  toolchain_memo[memo_key] = resolved
  resolved
}

///|
/// Single-quote a string for a POSIX shell.
fn shell_quote(value : String) -> String {
  let buf = StringBuilder()
  buf.write_char('\'')
  for ch in value {
    if ch == '\'' {
      // Close, escape a literal quote, reopen.
      buf.write_string("'\\''")
    } else {
      buf.write_char(ch)
    }
  }
  buf.write_char('\'')
  buf.to_string()
}

///|
/// Execution properties describing every toolchain `task` declares.
///
/// Sorted by the property key, so two runs of the same Taskfile hash
/// the same bytes whatever order the Listing was authored in.
///
/// A declared toolchain that is not `optional` and is not there is
/// fatal, and fatal *here* rather than inside the command: the message
/// names the task and the tool, where the command's would be a shell's
/// `command not found` attributed to whatever line happened to use it.
async fn toolchain_key_fields(
  task : Task,
  shell : String,
) -> Array[(String, String)] {
  let target = task.target_platform.unwrap_or("")
  let out : Array[(String, String)] = []
  for tc in task.toolchains {
    let resolved = resolve_toolchain(tc, shell, target)
    if !resolved.found {
      if !tc.optional {
        // Named twice on purpose when they differ: the author wrote
        // `cc`, and what is missing is the cross compiler that `cc`
        // selected for this target. Reporting only one of the two
        // sends them looking in the wrong place.
        let what = if resolved.executable == tc.name {
          "`" + tc.name + "`"
        } else {
          "`" + resolved.executable + "` (selected by `" + tc.name +
          "` for target " + target + ")"
        }
        die(
          "task `\{task.name}` declares toolchain \{what}, which is not on PATH",
        )
      }
      // Recorded, not skipped: a run that went ahead without the tool
      // did something different from one that had it, and the two must
      // not share an entry.
      out.push(("toolchain." + tc.name, "absent"))
      continue
    }
    if resolved.version.length() > 0 {
      out.push(("toolchain." + tc.name + ".version", resolved.version))
    } else {
      // The tool is there but would not say what it is. Hashing
      // "unknown" is honest; omitting the field would make this
      // indistinguishable from not declaring the toolchain at all.
      out.push(("toolchain." + tc.name + ".version", "unknown"))
    }
    if tc.hash_binary {
      out.push(("toolchain." + tc.name + ".digest", resolved.digest))
    }
    // Only when the constraint actually selected something else. A
    // native build's key is then byte-identical to what it was before
    // `forTarget` existed.
    if resolved.executable != tc.name {
      out.push(("toolchain." + tc.name + ".selected", resolved.executable))
    }
  }
  out.sort_by(fn(a, b) { lex_cmp(a.0, b.0) })
  out
}
