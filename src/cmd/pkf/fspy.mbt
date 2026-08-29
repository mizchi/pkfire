// `pkf trace` — run a task under the fspy shim and report what it read.
//
// See `fspy_source.mbt` for the shim itself and the rationale for
// interposition over ptrace/seccomp.

///|
/// Where the compiled shim is cached: `<cache root>/fspy/<digest>.so`.
/// Keyed by the digest of the C source so a pkf that changes the shim
/// rebuilds it and one that does not reuses the build.
fn fspy_lib_path() -> String {
  let digest = hex_encode(@crypto.sha256(@utf8.encode(fspy_preload_source)))
  let dir = join_path(cache_root(), "fspy")
  join_path(dir, "libpkf_fspy-" + digest[0:16].to_owned() + ".so")
}

///|
/// Build the shim if it is not already cached, returning its path.
///
/// Returns None after printing a diagnostic. The compiler is looked up
/// through `$CC`, then `cc`: tracing is an opt-in diagnostic, so
/// requiring a toolchain here is cheaper than shipping a per-platform
/// shared object in every release.
async fn ensure_fspy_lib() -> String? {
  let lib = fspy_lib_path()
  if @fs.path_exists(lib) {
    return Some(lib)
  }
  mkdir_p(dirname(lib))
  let source_path = lib + ".c"
  @fs.write_string_to_file(source_path, fspy_preload_source) catch {
    err => {
      ignore(err)
      die("pkf trace: cannot write the shim source to \{source_path}")
      return None
    }
  }
  let cc = match @env.get_env_var("CC") {
    Some(c) if c.length() > 0 => c
    _ => "cc"
  }
  // Build to a temp name and rename, so two concurrent traces cannot
  // hand a half-written .so to the dynamic loader.
  let tmp_lib = lib + ".tmp." + current_pid().to_string()
  let (code, out) = @process.collect_output_merged(cc.view(), [
    "-shared", "-fPIC", "-O2", "-o", tmp_lib, source_path, "-ldl",
  ]) catch {
    _ => {
      die(
        "pkf trace: no C compiler found (tried `\{cc}`); set $CC or install one",
      )
      return None
    }
  }
  if code != 0 {
    die("pkf trace: failed to build the fspy shim with `\{cc}`:\n" + out.text())
    return None
  }
  @xfs.rename(tmp_lib.view(), lib.view(), replace=true) catch {
    err => {
      die("pkf trace: cannot install the built shim at \{lib}: \{err}")
      return None
    }
  }
  Some(lib)
}

///|
/// One observed filesystem access.
struct TracedAccess {
  path : String
  /// True when the process opened it for writing. A path that is only
  /// ever written is an output, not an input, and must not end up in
  /// the suggested `inputs`.
  wrote : Bool
}

///|
/// Parse the shim's log into a deduplicated, sorted access list.
///
/// A path opened both for reading and for writing counts as written:
/// tasks routinely read back a file they just produced, and treating
/// that as an input would make the task's key depend on its own output.
fn parse_fspy_log(text : String) -> Array[TracedAccess] {
  let read_paths : Map[String, Bool] = Map([], capacity=64)
  let wrote_paths : Map[String, Bool] = Map([], capacity=64)
  for line in text.split("\n") {
    let line = line.to_owned()
    if line.length() < 3 {
      continue
    }
    let kind = line[0]
    // Records are `<kind><TAB><path>`.
    if line[1] != '\t' {
      continue
    }
    let path = line[2:line.length()].to_owned()
    if path.length() == 0 {
      continue
    }
    if kind == 'W' {
      wrote_paths[path] = true
    } else {
      read_paths[path] = true
    }
  }
  let names : Map[String, Bool] = Map([], capacity=64)
  for p, _ in read_paths {
    names[p] = true
  }
  for p, _ in wrote_paths {
    names[p] = true
  }
  let out : Array[TracedAccess] = []
  for p, _ in names {
    out.push(TracedAccess::{ path: p, wrote: wrote_paths.contains(p) })
  }
  out.sort_by(fn(a, b) { lex_cmp(a.path, b.path) })
  out
}

///|
/// Reduce a raw access list to repo-relative read paths worth showing.
///
/// Everything outside the workspace is dropped — a build reads its
/// toolchain, /etc/localtime, and a few hundred shared objects, none of
/// which belong in a Taskfile's `inputs`. So are the cache root, `.git`,
/// and directories: those are noise for every task.
fn fspy_relevant_reads(
  accesses : Array[TracedAccess],
  repo_root_abs : String,
) -> Array[String] {
  let cache_abs = cache_root()
  let out : Array[String] = []
  let seen : Map[String, Bool] = Map([], capacity=accesses.length())
  for access in accesses {
    if access.wrote {
      continue
    }
    let rel = match path_relative_to(repo_root_abs, access.path) {
      Some(r) => r
      None => continue
    }
    if rel.length() == 0 {
      continue
    }
    if rel.has_prefix(".git/") || rel == ".git" {
      continue
    }
    if access.path.has_prefix(cache_abs) {
      continue
    }
    // Directory opens (readdir, glob expansion) are not content inputs.
    let is_dir = @fs.is_dir(access.path) catch { _ => false }
    if is_dir {
      continue
    }
    if !@fs.path_exists(access.path) {
      // Probes for files that do not exist — a compiler walking an
      // include path, a shell searching $PATH. Not an input.
      continue
    }
    if !seen.contains(rel) {
      seen[rel] = true
      out.push(rel)
    }
  }
  out.sort_by(fn(a, b) { lex_cmp(a, b) })
  out
}

///|
/// True when any declared input glob covers `rel`.
fn declared_covers(task : Task, rel : String) -> Bool {
  for pattern in task.inputs {
    if glob_match(pattern, rel) || pattern == rel {
      return true
    }
  }
  false
}

///|
async fn trace_cmd(
  explicit_taskfile : String?,
  args : ArrayView[String],
) -> Int {
  let mut emit = false
  let mut check = false
  let task_names : Array[String] = []
  for a in args {
    if a == "--emit" {
      emit = true
    } else if a == "--check" {
      check = true
    } else if a.has_prefix("-") {
      die("pkf trace: unknown flag `\{a}`")
      return 2
    } else {
      task_names.push(a)
    }
  }
  if task_names.length() != 1 {
    die("usage: pkf trace [-f FILE] [--emit] [--check] <task>")
    return 2
  }
  let target = task_names[0]
  let taskfile = locate_taskfile(explicit_taskfile)
  let raw_json = eval_taskfile(taskfile)
  let plan = parse_plan(raw_json)
  let task = match plan.tasks.get(target) {
    Some(t) => t
    None => {
      suggest_task_name(target, plan)
      return 2
    }
  }
  if task.cmd.length() == 0 {
    die("pkf trace: task `\{target}` has no cmd to trace")
    return 2
  }
  let lib = match ensure_fspy_lib() {
    Some(l) => l
    None => return 2
  }
  let repo_root = taskfile_dir(taskfile)
  let task_cwd = task_root_of(repo_root, task)
  let cwd = match @env.current_dir() {
    Some(d) => d
    None => repo_root
  }
  let repo_root_abs = absolute_lexical_path(repo_root, cwd)
  // The log lives outside the workspace so tracing does not perturb the
  // very input globs it is measuring.
  let log_path = join_path(
    join_path(cache_root(), "fspy"),
    "trace-" + current_pid().to_string() + ".log",
  )
  mkdir_p(dirname(log_path))
  @fs.write_string_to_file(log_path, "") catch {
    err => {
      ignore(err)
      die("pkf trace: cannot create the trace log at \{log_path}")
      return 2
    }
  }
  let extra_env : Map[String, String] = Map([], capacity=8)
  for k, v in plan.default_env {
    extra_env[k] = v
  }
  for k, v in task.env {
    extra_env[k] = v
  }
  // Params are not settable through `trace`; take their declared
  // defaults so the command sees the same shape `pkf run` gives it.
  let params = match resolve_task_params(task, Map([], capacity=0)) {
    Some(m) => m
    None => return 2
  }
  for pname, pvalue in params {
    extra_env[upcase(pname)] = pvalue
  }
  // Prepending keeps any LD_PRELOAD the environment already set.
  let preload = match @env.get_env_var("LD_PRELOAD") {
    Some(p) if p.length() > 0 => lib + " " + p
    _ => lib
  }
  extra_env["LD_PRELOAD"] = preload
  extra_env["PKF_FSPY_LOG"] = log_path
  let argv : Array[String] = []
  for flag in task.shell_flags {
    argv.push(flag)
  }
  argv.push(task.cmd)
  println("pkf: $ \{target}  (traced)")
  let code = @process.run_inherit(
    task.shell.view(),
    argv[:],
    extra_env~,
    inherit_env=task.inherit_env,
    cwd=task_cwd.view(),
  )
  let log = @fs.read_file_to_string(log_path) catch { _ => "" }
  @fs.remove_file(log_path) catch { _ => () }
  if log.length() == 0 {
    println("")
    println(
      "pkf: the trace recorded nothing. The command may be statically linked",
    )
    println(
      "pkf: (Go, Rust with a static libc, busybox), which never calls into",
    )
    println("pkf: libc and so cannot be observed this way.")
    return code
  }
  let reads = fspy_relevant_reads(parse_fspy_log(log), repo_root_abs)
  println("")
  println("pkf: \{target} read \{reads.length()} file(s) under the workspace")
  if emit {
    println("")
    println("  inputs {")
    for rel in reads {
      println("    \"" + rel + "\"")
    }
    println("  }")
  }
  if check {
    // Undeclared reads are the cache-correctness bug: the task's key
    // does not cover a file whose contents change what it produces.
    let undeclared : Array[String] = []
    for rel in reads {
      if !declared_covers(task, rel) {
        undeclared.push(rel)
      }
    }
    // Declared globs that matched nothing the task opened cost cache
    // hits without buying correctness.
    let unread : Array[String] = []
    for pattern in task.inputs {
      let mut used = false
      for rel in reads {
        if glob_match(pattern, rel) || pattern == rel {
          used = true
          break
        }
      }
      if !used {
        unread.push(pattern)
      }
    }
    println("")
    if undeclared.length() == 0 {
      println("pkf: OK   every file read is covered by a declared input")
    } else {
      println(
        "pkf: WARN \{undeclared.length()} file(s) read but not covered by `inputs`:",
      )
      for rel in undeclared {
        println("pkf:        " + rel)
      }
      println("pkf:      editing one of these will NOT invalidate the cache.")
    }
    if unread.length() > 0 {
      println("")
      println(
        "pkf: NOTE \{unread.length()} declared input pattern(s) matched nothing read:",
      )
      for pattern in unread {
        println("pkf:        " + pattern)
      }
      println("pkf:      these cost cache hits without protecting correctness.")
    }
    if undeclared.length() > 0 && code == 0 {
      return 1
    }
  } else if !emit {
    for rel in reads {
      println("  " + rel)
    }
  }
  code
}
