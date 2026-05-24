// pkf-mbt — MoonBit re-implementation of pkfire.
//
// Phase 1 MVP: `pkf run <task>` only.
//   1. Locate Taskfile.pkl (`./Taskfile.pkl` by default).
//   2. Spawn `mpkl eval -f json <Taskfile.pkl>` and capture stdout.
//   3. Parse the Rendered JSON envelope (taskOrder + tasks Mapping).
//   4. Topo-sort tasks via their `deps` list.
//   5. For each task, spawn `<shell> <shellFlags> <cmd>` with merged env.
//   6. Stream stdout/stderr through, return the first non-zero exit.
//
// Cache / watch / remote-cache / services / params are deferred to later
// phases. The MVP keeps Apple Pkl's role of generating the wire format
// and only proves the pkfire wire-consumer side translates cleanly to
// MoonBit. Once stable, mpkl can be embedded as a library to drop the
// subprocess hop.

///|
struct Param {
  name : String
  ptype : String
  choices : Array[String]
  default : String?
}

///|
struct Task {
  name : String
  cmd : String
  shell : String
  shell_flags : Array[String]
  inputs : Array[String]
  outputs : Array[String]
  deps : Array[String]
  env : Map[String, String]
  tools : Map[String, String]
  cache : Bool
  workdir : String?
  inherit_env : Bool
  params : Array[Param]
  accepts_args : Bool
  service : Bool
  services : Array[String]
  ready_port : Int
  ready_cmd : String
  ready_timeout_seconds : Int
  shutdown_timeout_seconds : Int
  description : String?
  visibility : String
}

///|
struct WorkflowTest {
  name : String
  changed : Array[String]
  tasks : Array[String]
  direct : Array[String]
}

///|
struct Plan {
  default_env : Map[String, String]
  tasks : Map[String, Task]
  task_order : Array[String]
  workflow_tests : Array[WorkflowTest]
}

///|
fn die(message : String) -> Unit {
  println("pkf: \{message}")
  @sys.exit(2)
}

///|
fn parse_string(value : Json) -> String {
  match value {
    String(s) => s
    _ => ""
  }
}

///|
fn parse_string_array(value : Json) -> Array[String] {
  let out : Array[String] = []
  match value {
    Array(items) =>
      for item in items {
        out.push(parse_string(item))
      }
    _ => ()
  }
  out
}

///|
fn parse_string_map(value : Json) -> Map[String, String] {
  let out : Map[String, String] = Map([], capacity=8)
  match value {
    Object(entries) =>
      for k, v in entries {
        out[k] = parse_string(v)
      }
    _ => ()
  }
  out
}

///|
fn parse_bool(value : Json, default~ : Bool) -> Bool {
  match value {
    True => true
    False => false
    _ => default
  }
}

///|
fn parse_plan(raw : String) -> Plan {
  let root : Json = @json.parse(raw) catch {
    _ => {
      die("could not parse mpkl JSON output")
      panic()
    }
  }
  let entries = match root {
    Object(e) => e
    _ => {
      die("mpkl JSON output is not an object")
      panic()
    }
  }
  let defaults_entries : Map[String, Json] = match
    entries.get("defaults") {
    Some(Object(e)) => e
    _ => Map([], capacity=0)
  }
  let default_shell = match defaults_entries.get("shell") {
    Some(v) => parse_string(v)
    None => "bash"
  }
  let default_shell_flags = match defaults_entries.get("shellFlags") {
    Some(v) => parse_string_array(v)
    None => ["-c"]
  }
  let default_env = match defaults_entries.get("env") {
    Some(v) => parse_string_map(v)
    None => Map([], capacity=0)
  }
  let task_order = match entries.get("taskOrder") {
    Some(v) => parse_string_array(v)
    None => []
  }
  let tasks_obj = match entries.get("tasks") {
    Some(Object(e)) => e
    _ => {
      die("Taskfile output has no `tasks` mapping")
      panic()
    }
  }
  let tasks : Map[String, Task] = Map([], capacity=tasks_obj.length())
  for name, raw_task in tasks_obj {
    let task_entries = match raw_task {
      Object(e) => e
      _ => continue
    }
    let cmd = match task_entries.get("cmd") {
      Some(v) => parse_string(v)
      None => ""
    }
    let shell = match task_entries.get("shell") {
      Some(v) => parse_string(v)
      None => default_shell
    }
    let shell_flags = match task_entries.get("shellFlags") {
      Some(v) => parse_string_array(v)
      None => default_shell_flags
    }
    let inputs = match task_entries.get("inputs") {
      Some(v) => parse_string_array(v)
      None => []
    }
    let outputs = match task_entries.get("outputs") {
      Some(v) => parse_string_array(v)
      None => []
    }
    let deps = match task_entries.get("deps") {
      Some(v) => parse_string_array(v)
      None => []
    }
    let env = match task_entries.get("env") {
      Some(v) => parse_string_map(v)
      None => Map([], capacity=0)
    }
    let tools = match task_entries.get("tools") {
      Some(v) => parse_string_map(v)
      None => Map([], capacity=0)
    }
    let cache = match task_entries.get("cache") {
      Some(v) => parse_bool(v, default=true)
      None => true
    }
    let workdir = match task_entries.get("workdir") {
      Some(String(s)) => Some(s)
      _ => None
    }
    let description = match task_entries.get("description") {
      Some(String(s)) => Some(s)
      _ => None
    }
    let visibility = match task_entries.get("visibility") {
      Some(v) => parse_string(v)
      None => "public"
    }
    let inherit_env = match task_entries.get("inheritEnv") {
      Some(v) => parse_bool(v, default=true)
      None => true
    }
    let accepts_args = match task_entries.get("acceptsArgs") {
      Some(v) => parse_bool(v, default=false)
      None => false
    }
    let service = match task_entries.get("service") {
      Some(v) => parse_bool(v, default=false)
      None => false
    }
    let services = match task_entries.get("services") {
      Some(v) => parse_string_array(v)
      None => []
    }
    let ready_port = match task_entries.get("readyPort") {
      Some(Number(n, ..)) => n.to_int()
      _ => 0
    }
    let ready_cmd = match task_entries.get("readyCmd") {
      Some(v) => parse_string(v)
      None => ""
    }
    let ready_timeout_seconds = match task_entries.get("readyTimeoutSeconds") {
      Some(Number(n, ..)) => n.to_int()
      _ => 30
    }
    let shutdown_timeout_seconds = match task_entries.get("shutdownTimeoutSeconds") {
      Some(Number(n, ..)) => n.to_int()
      _ => 5
    }
    let params : Array[Param] = []
    match task_entries.get("params") {
      Some(Array(raw_params)) =>
        for raw in raw_params {
          match raw {
            Object(p) => {
              let pname = match p.get("name") {
                Some(v) => parse_string(v)
                None => continue
              }
              let ptype = match p.get("type") {
                Some(v) => parse_string(v)
                None => "string"
              }
              let choices = match p.get("choices") {
                Some(v) => parse_string_array(v)
                None => []
              }
              let default = match p.get("default") {
                Some(String(s)) => Some(s)
                _ => None
              }
              params.push(Param::{ name: pname, ptype, choices, default })
            }
            _ => ()
          }
        }
      _ => ()
    }
    tasks[name] = Task::{
      name,
      cmd,
      shell,
      shell_flags,
      inputs,
      outputs,
      deps,
      env,
      tools,
      cache,
      workdir,
      inherit_env,
      params,
      accepts_args,
      service,
      services,
      ready_port,
      ready_cmd,
      ready_timeout_seconds,
      shutdown_timeout_seconds,
      description,
      visibility,
    }
  }
  let workflow_tests : Array[WorkflowTest] = []
  match entries.get("workflowTests") {
    Some(Array(raw_tests)) =>
      for raw in raw_tests {
        match raw {
          Object(e) => {
            let name = match e.get("name") {
              Some(v) => parse_string(v)
              None => continue
            }
            let changed = match e.get("changed") {
              Some(v) => parse_string_array(v)
              None => []
            }
            let wt_tasks = match e.get("tasks") {
              Some(v) => parse_string_array(v)
              None => []
            }
            let direct = match e.get("direct") {
              Some(v) => parse_string_array(v)
              None => []
            }
            workflow_tests.push(WorkflowTest::{
              name,
              changed,
              tasks: wt_tasks,
              direct,
            })
          }
          _ => ()
        }
      }
    _ => ()
  }
  Plan::{ default_env, tasks, task_order, workflow_tests }
}

///|
fn topo_sort_for(target : String, plan : Plan) -> Array[String] {
  let visited : Map[String, Bool] = Map([], capacity=plan.tasks.length())
  let on_stack : Map[String, Bool] = Map([], capacity=plan.tasks.length())
  let order : Array[String] = []
  fn visit(name : String) -> Unit {
    if visited.get(name) is Some(true) {
      return
    }
    if on_stack.get(name) is Some(true) {
      die("task `\{name}` is part of a cycle")
    }
    on_stack[name] = true
    let task = match plan.tasks.get(name) {
      Some(t) => t
      None => {
        die("unknown task `\{name}`")
        panic()
      }
    }
    for dep in task.deps {
      visit(dep)
    }
    on_stack[name] = false
    visited[name] = true
    order.push(name)
  }

  visit(target)
  order
}

// ---------------------------------------------------------------------------
// Path / FS helpers (no recursion in moonbitlang/x/fs, so we roll our own).
// ---------------------------------------------------------------------------

///|
fn dirname(path : String) -> String {
  match path.rev_find("/") {
    Some(idx) =>
      if idx == 0 {
        "/"
      } else {
        path.substring(start=0, end=idx)
      }
    None => ""
  }
}

///|
fn basename(path : String) -> String {
  match path.rev_find("/") {
    Some(idx) => path.substring(start=idx + 1, end=path.length())
    None => path
  }
}

///|
fn join_path(a : String, b : String) -> String {
  if a.length() == 0 {
    b
  } else if a.has_suffix("/") {
    a + b
  } else {
    a + "/" + b
  }
}

///|
fn mkdir_p(path : String) -> Unit {
  if path.length() == 0 || @fs.path_exists(path) {
    return
  }
  let parent = dirname(path)
  if parent.length() > 0 && parent != path && parent != "/" {
    mkdir_p(parent)
  }
  if !@fs.path_exists(path) {
    @fs.create_dir(path) catch {
      _ => ()
    }
  }
}

///|
fn rm_rf(path : String) -> Unit {
  if !@fs.path_exists(path) {
    return
  }
  let is_dir = @fs.is_dir(path) catch {
    _ => false
  }
  if is_dir {
    let entries = @fs.read_dir(path) catch {
      _ => []
    }
    for entry in entries {
      rm_rf(join_path(path, entry))
    }
    @fs.remove_dir(path) catch {
      _ => ()
    }
  } else {
    @fs.remove_file(path) catch {
      _ => ()
    }
  }
}

///|
fn copy_file(src : String, dst : String) -> Unit {
  let parent = dirname(dst)
  if parent.length() > 0 {
    mkdir_p(parent)
  }
  let bytes = @fs.read_file_to_bytes(src) catch {
    _ => Bytes::new(0)
  }
  @fs.write_bytes_to_file(dst, bytes) catch {
    _ => ()
  }
}

///|
fn walk_files(root : String, rel_prefix : String, out : Array[String]) -> Unit {
  // Append every regular file under `root` to `out` as a relative path
  // built from `rel_prefix`. Symlinks are followed naively (whatever
  // `read_dir` returns). Directory recursion is depth-first.
  let entries = @fs.read_dir(root) catch {
    _ => []
  }
  for entry in entries {
    let full = join_path(root, entry)
    let rel = if rel_prefix.length() == 0 {
      entry
    } else {
      rel_prefix + "/" + entry
    }
    let is_dir = @fs.is_dir(full) catch {
      _ => false
    }
    if is_dir {
      walk_files(full, rel, out)
    } else {
      out.push(rel)
    }
  }
}

// ---------------------------------------------------------------------------
// Glob matcher: supports literal text, `?`, `*` (no slash), and `**`
// (zero-or-more slash-separated segments). Mirrors doublestar's subset
// that pkfire's Taskfile schema documents.
// ---------------------------------------------------------------------------

///|
fn glob_match(pattern : String, path : String) -> Bool {
  // Split both into segments by `/`, then match segment-by-segment with
  // `**` consuming zero or more.
  let p_segs = pattern.split("/").collect()
  let s_segs = path.split("/").collect()
  glob_segs(p_segs, 0, s_segs, 0)
}

///|
fn glob_segs(
  p : Array[@string.View],
  pi : Int,
  s : Array[@string.View],
  si : Int,
) -> Bool {
  let mut pi = pi
  let mut si = si
  for {
    if pi >= p.length() {
      return si >= s.length()
    }
    let seg = p[pi].to_string()
    if seg == "**" {
      // Try matching 0..n segments.
      if pi == p.length() - 1 {
        return true
      }
      for skip = si; skip <= s.length(); skip = skip + 1 {
        if glob_segs(p, pi + 1, s, skip) {
          return true
        }
      }
      return false
    }
    if si >= s.length() {
      return false
    }
    if !glob_segment_matches(seg, s[si].to_string()) {
      return false
    }
    pi = pi + 1
    si = si + 1
  }
}

///|
fn glob_segment_matches(pat : String, seg : String) -> Bool {
  // Single-segment matcher: supports `*` (any chars no slash) and `?`.
  // No character classes for the MVP.
  glob_seg_step(pat, 0, seg, 0)
}

///|
fn glob_seg_step(pat : String, pi : Int, seg : String, si : Int) -> Bool {
  let mut pi = pi
  let mut si = si
  for {
    if pi >= pat.length() {
      return si >= seg.length()
    }
    let pc = pat[pi]
    if pc == '*' {
      // Try matching greedy then backtrack.
      for skip = si; skip <= seg.length(); skip = skip + 1 {
        if glob_seg_step(pat, pi + 1, seg, skip) {
          return true
        }
      }
      return false
    }
    if si >= seg.length() {
      return false
    }
    let sc = seg[si]
    if pc == '?' || pc == sc {
      pi = pi + 1
      si = si + 1
    } else {
      return false
    }
  }
}

///|
fn expand_glob(root : String, pattern : String, out : Map[String, Bool]) -> Unit {
  // Fast path: literal pattern with no wildcard.
  if !pattern.contains("*") && !pattern.contains("?") {
    let full = if root.length() == 0 || root == "." {
      pattern
    } else {
      join_path(root, pattern)
    }
    if @fs.path_exists(full) {
      let is_dir = @fs.is_dir(full) catch {
        _ => false
      }
      if !is_dir {
        out[pattern] = true
      }
    }
    return
  }
  let all : Array[String] = []
  let walk_root = if root.length() == 0 { "." } else { root }
  walk_files(walk_root, "", all)
  for rel in all {
    if glob_match(pattern, rel) {
      out[rel] = true
    }
  }
}

///|
fn expand_inputs(root : String, patterns : Array[String]) -> Array[String] {
  let seen : Map[String, Bool] = Map([], capacity=32)
  for p in patterns {
    expand_glob(root, p, seen)
  }
  let out : Array[String] = []
  for k, _ in seen {
    out.push(k)
  }
  out.sort()
  out
}

// ---------------------------------------------------------------------------
// SHA-256 + action key calculation.
//
// pkf-mbt's cache uses a different hash family (SHA-256) and a different
// on-disk layout from go pkfire's BLAKE3 + tar.zst, so the two cannot
// share local cache. The action-key *string* still mirrors go pkfire's
// canonical form so a future BLAKE3 backend can produce wire-compatible
// keys by swapping the hash function.
// ---------------------------------------------------------------------------

///|
fn hex_digit(n : Int) -> Char {
  if n < 10 {
    Char::from_int(n + '0'.to_int())
  } else {
    Char::from_int(n - 10 + 'a'.to_int())
  }
}

///|
fn hex_encode(bytes : FixedArray[Byte]) -> String {
  let buf = StringBuilder::new(size_hint=bytes.length() * 2)
  for i in 0..<bytes.length() {
    let b = bytes[i].to_int()
    buf.write_char(hex_digit((b >> 4) & 0xf))
    buf.write_char(hex_digit(b & 0xf))
  }
  buf.to_string()
}

///|
fn sorted_keys(map : Map[String, String]) -> Array[String] {
  let keys : Array[String] = []
  for k, _ in map {
    keys.push(k)
  }
  keys.sort()
  keys
}

///|
fn hash_file(path : String) -> FixedArray[Byte] {
  let bytes = @fs.read_file_to_bytes(path) catch {
    _ => Bytes::new(0)
  }
  @crypto.sha256(bytes)
}

///|
fn compute_action_key(
  task : Task,
  input_hashes : Array[(String, FixedArray[Byte])],
  params : Map[String, String],
  positionals : Array[String],
) -> String {
  let h = @crypto.SHA256::new()
  h.update(("cmd:" + task.cmd + "\n").to_bytes())
  h.update(("shell:" + task.shell + "\n").to_bytes())
  for i, flag in task.shell_flags {
    let line = "shell-flag:" + i.to_string() + ":" + flag + "\n"
    h.update(line.to_bytes())
  }
  let env_keys = sorted_keys(task.env)
  for k in env_keys {
    let v = task.env.get(k).unwrap()
    h.update(("env:" + k + "=" + v + "\n").to_bytes())
  }
  let tool_keys = sorted_keys(task.tools)
  for k in tool_keys {
    let v = task.tools.get(k).unwrap()
    h.update(("tool:" + k + "=" + v + "\n").to_bytes())
  }
  for entry in input_hashes {
    let path = entry.0
    let digest = entry.1
    h.update(("in:" + path + ":" + hex_encode(digest) + "\n").to_bytes())
  }
  let param_keys = sorted_keys(params)
  for k in param_keys {
    let v = params.get(k).unwrap()
    h.update(("param:" + k + "=" + v + "\n").to_bytes())
  }
  for i, arg in positionals {
    h.update(("arg:" + i.to_string() + ":" + arg + "\n").to_bytes())
  }
  hex_encode(h.finalize())
}

// ---------------------------------------------------------------------------
// Cache directory layout: `<root>/cas/<key[0:2]>/<key[2:]>/`.
// Stored as a flat tree of `outputs/<relative-path>` plus a marker file
// `manifest`. `Has(key)` checks the marker presence.
// ---------------------------------------------------------------------------

///|
fn cache_root() -> String {
  match @sys.get_env_var("PKFIRE_MBT_CACHE_DIR") {
    Some(d) => d
    None =>
      match @sys.get_env_var("XDG_CACHE_HOME") {
        Some(base) => join_path(base, "pkfire-mbt")
        None =>
          match @sys.get_env_var("HOME") {
            Some(home) => join_path(join_path(home, ".cache"), "pkfire-mbt")
            None => ".pkfire-mbt-cache"
          }
      }
  }
}

///|
fn entry_dir(key : String) -> String {
  let head = key.substring(start=0, end=2)
  let tail = key.substring(start=2, end=key.length())
  join_path(join_path(join_path(cache_root(), "cas"), head), tail)
}

///|
fn cache_hit(key : String) -> Bool {
  let marker = join_path(entry_dir(key), "manifest")
  @fs.path_exists(marker)
}

///|
fn cache_store(
  key : String,
  root : String,
  outputs : Array[String],
) -> Unit {
  let dir = entry_dir(key)
  rm_rf(dir)
  mkdir_p(dir)
  let outputs_dir = join_path(dir, "outputs")
  mkdir_p(outputs_dir)
  let manifest = StringBuilder::new(size_hint=outputs.length() * 64)
  for rel in outputs {
    let src = if root.length() == 0 || root == "." {
      rel
    } else {
      join_path(root, rel)
    }
    if !@fs.path_exists(src) {
      continue
    }
    let is_dir = @fs.is_dir(src) catch {
      _ => false
    }
    if is_dir {
      // Directory outputs: recurse and copy each contained file.
      let inner : Array[String] = []
      walk_files(src, rel, inner)
      for nested in inner {
        let nested_src = join_path(root, nested)
        let nested_dst = join_path(outputs_dir, nested)
        copy_file(nested_src, nested_dst)
        manifest.write_string(nested)
        manifest.write_char('\n')
      }
    } else {
      let dst = join_path(outputs_dir, rel)
      copy_file(src, dst)
      manifest.write_string(rel)
      manifest.write_char('\n')
    }
  }
  @fs.write_string_to_file(
    join_path(dir, "manifest"),
    manifest.to_string(),
  ) catch {
    _ => ()
  }
}

///|
fn cache_restore(key : String, root : String) -> Unit {
  let dir = entry_dir(key)
  let outputs_dir = join_path(dir, "outputs")
  let manifest_path = join_path(dir, "manifest")
  let manifest = @fs.read_file_to_string(manifest_path) catch {
    _ => ""
  }
  for line in manifest.split("\n") {
    let rel = line.to_string()
    if rel.length() == 0 {
      continue
    }
    let src = join_path(outputs_dir, rel)
    let dst = if root.length() == 0 || root == "." {
      rel
    } else {
      join_path(root, rel)
    }
    copy_file(src, dst)
  }
}

// ---------------------------------------------------------------------------
// Service orchestration: bring up declared `services { ... }` before running
// the main `cmd`, probe readiness, and tear them down on completion.
// ---------------------------------------------------------------------------

///|
struct RunningService {
  name : String
  proc : @process.Process?
  shutdown_timeout_seconds : Int
}

///|
async fn probe_port(port : Int) -> Bool {
  let addr = @socket.Addr::parse("127.0.0.1:" + port.to_string()) catch {
    _ => return false
  }
  match (try? @socket.Tcp::connect(addr)) {
    Ok(tcp) => {
      tcp.close()
      true
    }
    Err(_) => false
  }
}

///|
async fn run_ready_cmd(task : Task) -> Bool {
  // Single readiness-probe shell execution. The probe is considered
  // ready when the cmd exits 0 — matches `pg_isready`, `curl -sf`,
  // etc. The default 5-second timeout shields against a buggy probe
  // hanging indefinitely.
  let argv : Array[String] = []
  for flag in task.shell_flags {
    argv.push(flag)
  }
  argv.push(task.ready_cmd)
  // Suppress probe output by collecting stdout/stderr instead of
  // inheriting — health-check chatter shouldn't drown the pkf log.
  let (code, _, _) = match task.workdir {
    Some(cwd) =>
      @process.collect_output(
        task.shell.view(),
        argv[:],
        inherit_env=task.inherit_env,
        cwd=cwd.view(),
      )
    None =>
      @process.collect_output(
        task.shell.view(),
        argv[:],
        inherit_env=task.inherit_env,
      )
  }
  code == 0
}

///|
async fn wait_until_ready(task : Task) -> Bool {
  // Poll readiness probes every 100ms up to `readyTimeoutSeconds`.
  // When both `readyPort` and `readyCmd` are set, BOTH must pass —
  // pg_isready alone doesn't guarantee the TCP socket is bound and
  // vice versa. Returns true on first joint success. When neither is
  // set, the call is a no-op (service is considered immediately
  // ready, matching Apple pkfire).
  let has_port = task.ready_port > 0
  let has_cmd = task.ready_cmd.length() > 0
  if !has_port && !has_cmd {
    return true
  }
  let deadline_iters = task.ready_timeout_seconds * 10
  for i in 0..<deadline_iters {
    let port_ok = if has_port { probe_port(task.ready_port) } else { true }
    let cmd_ok = if has_cmd { run_ready_cmd(task) } else { true }
    if port_ok && cmd_ok {
      return true
    }
    @async.sleep(100)
    ignore(i)
  }
  false
}

///|
async fn[X] start_service(
  group : @async.TaskGroup[X],
  plan : Plan,
  service_task : Task,
  params : Map[String, String],
) -> RunningService raise {
  // Reuse path: if the readyPort is already open, treat the service as
  // externally provided (`pkf up dev` running in another shell, etc.).
  // Apple pkfire documents this reuse semantics; matching it here means
  // a developer's `pkf run e2e` doesn't collide with their `pkf up dev`.
  if service_task.ready_port > 0 && probe_port(service_task.ready_port) {
    println("pkf: ~ \{service_task.name} (already up, reusing)")
    return RunningService::{
      name: service_task.name,
      proc: None,
      shutdown_timeout_seconds: service_task.shutdown_timeout_seconds,
    }
  }
  let argv : Array[String] = []
  for flag in service_task.shell_flags {
    argv.push(flag)
  }
  argv.push(service_task.cmd)
  let extra_env : Map[String, String] = Map([], capacity=4)
  for k, v in plan.default_env {
    extra_env[k] = v
  }
  for k, v in service_task.env {
    extra_env[k] = v
  }
  for pname, pvalue in params {
    extra_env[upcase(pname)] = pvalue
  }
  println("pkf: ↑ \{service_task.name}")
  let handler = @process.graceful_cancel(
    timeout=service_task.shutdown_timeout_seconds * 1000,
    signal=@signal.SIGTERM,
  )
  let proc = match service_task.workdir {
    Some(cwd) =>
      @process.spawn(
        group,
        service_task.shell.view(),
        argv[:],
        extra_env~,
        inherit_env=service_task.inherit_env,
        cwd=cwd.view(),
        cancel_handler=handler,
        no_wait=true,
        new_process_group=true,
      )
    None =>
      @process.spawn(
        group,
        service_task.shell.view(),
        argv[:],
        extra_env~,
        inherit_env=service_task.inherit_env,
        cancel_handler=handler,
        no_wait=true,
        new_process_group=true,
      )
  }
  // Wait for readiness (readyPort + readyCmd, whichever are set).
  let ok = wait_until_ready(service_task)
  if !ok {
    proc.cancel()
    raise Failure(
      "service `\{service_task.name}` did not become ready within \{service_task.ready_timeout_seconds}s",
    )
  }
  RunningService::{
    name: service_task.name,
    proc: Some(proc),
    shutdown_timeout_seconds: service_task.shutdown_timeout_seconds,
  }
}

///|
async fn signal_pid_tree(pid : Int, signal : @signal.Signal) -> Unit {
  // Send `signal` to `pid` and every descendant. mizchi/x/process's
  // `new_process_group` is best-effort (sub-millisecond race against
  // child exec / setpgid), so we still need to walk the parent-pid
  // tree via `pkill -P` for the subtree. The direct leaf signal
  // dispatches through the native `kill(2)` wrapper added in
  // mizchi/x@0.3.3 — one fewer subprocess per teardown.
  let sig_name = match signal {
    @signal.SIGTERM => "TERM"
    @signal.SIGINT => "INT"
    @signal.SIGHUP => "HUP"
    _ => "KILL"
  }
  ignore(
    try? @process.collect_output("pkill", ["-" + sig_name, "-P", pid.to_string()]),
  )
  @process.kill(pid, signal)
}

///|
async fn stop_services(running : Array[RunningService]) -> Unit {
  // Reverse declaration order so dependents stop before their backends.
  for i = running.length() - 1; i >= 0; i = i - 1 {
    let svc = running[i]
    match svc.proc {
      Some(p) => {
        println("pkf: ↓ \{svc.name}")
        // Graceful SIGTERM to the whole subtree, then SIGKILL after the
        // shutdownTimeout grace if the process is still alive.
        signal_pid_tree(p.pid, @signal.SIGTERM)
        let deadline_iters = svc.shutdown_timeout_seconds * 20
        let mut exited = false
        for j in 0..<deadline_iters {
          match (try? p.try_wait()) {
            Ok(Some(_)) => {
              exited = true
              break
            }
            _ => ()
          }
          @async.sleep(50)
          ignore(j)
        }
        if !exited {
          // SIGKILL is not in mizchi/x/signal.Signal — fall back to the
          // subprocess `kill -KILL` for the hard shutdown path.
          ignore(
            try? @process.collect_output("pkill", [
              "-KILL", "-P", p.pid.to_string(),
            ]),
          )
          ignore(
            try? @process.collect_output("kill", [
              "-KILL", p.pid.to_string(),
            ]),
          )
        }
        ignore(try? p.wait())
      }
      None => ()
    }
  }
}

///|
suberror PkfError String derive(Show)

///|
fn PkfError::message(self : PkfError) -> String {
  let PkfError(m) = self
  m
}

///|
async fn[X] run_task(
  group : @async.TaskGroup[X],
  plan : Plan,
  task : Task,
  repo_root : String,
  params : Map[String, String],
  positionals : Array[String],
) -> Int {
  if task.cmd.length() == 0 {
    // deps-only umbrella task — nothing to spawn.
    return 0
  }
  // Compute the action key and consult the cache when caching is on.
  let mut key : String? = None
  if task.cache {
    let resolved_inputs = expand_inputs(repo_root, task.inputs)
    let input_hashes : Array[(String, FixedArray[Byte])] = []
    for rel in resolved_inputs {
      let src = if repo_root.length() == 0 || repo_root == "." {
        rel
      } else {
        join_path(repo_root, rel)
      }
      input_hashes.push((rel, hash_file(src)))
    }
    let k = compute_action_key(task, input_hashes, params, positionals)
    if cache_hit(k) {
      println("pkf: # \{task.name} (cache hit \{k.substring(start=0, end=8)})")
      cache_restore(k, repo_root)
      return 0
    }
    key = Some(k)
  }
  // bash -c "cmd" placeholder for positional args: pkfire passes
  // positionals as `bash -c "cmd" <task-name> <positional...>` so that
  // `$0` is the task name and `$1`..`$@` are the user-supplied args.
  let argv : Array[String] = []
  for flag in task.shell_flags {
    argv.push(flag)
  }
  argv.push(task.cmd)
  if task.accepts_args && positionals.length() > 0 {
    argv.push(task.name)
    for pos in positionals {
      argv.push(pos)
    }
  }
  let extra_env : Map[String, String] = Map([], capacity=4)
  for k, v in plan.default_env {
    extra_env[k] = v
  }
  for k, v in task.env {
    extra_env[k] = v
  }
  // Param values surface as `$<NAME>` (uppercased).
  for pname, pvalue in params {
    extra_env[upcase(pname)] = pvalue
  }
  // Start declared services before running cmd. Cache hit above
  // short-circuits the spawn; reuse semantics apply per service.
  let running : Array[RunningService] = []
  for service_name in task.services {
    let service_task = match plan.tasks.get(service_name) {
      Some(t) => t
      None => {
        stop_services(running)
        die("unknown service `\{service_name}` declared by `\{task.name}`")
        return 2
      }
    }
    if !service_task.service {
      stop_services(running)
      die(
        "task `\{service_name}` is referenced as a service by `\{task.name}` but is not declared `service = true`",
      )
      return 2
    }
    match (try? start_service(group, plan, service_task, params)) {
      Ok(rs) => running.push(rs)
      Err(err) => {
        stop_services(running)
        println("pkf: \{err}")
        return 2
      }
    }
  }
  println("pkf: $ \{task.name}")
  let code = match task.workdir {
    Some(cwd) =>
      @process.run_inherit(
        task.shell.view(),
        argv[:],
        extra_env~,
        inherit_env=task.inherit_env,
        cwd=cwd.view(),
      )
    None =>
      @process.run_inherit(
        task.shell.view(),
        argv[:],
        extra_env~,
        inherit_env=task.inherit_env,
      )
  }
  stop_services(running)
  if code == 0 {
    match key {
      Some(k) => {
        let resolved_outputs = expand_inputs(repo_root, task.outputs)
        cache_store(k, repo_root, resolved_outputs)
      }
      None => ()
    }
  }
  code
}

///|
fn locate_taskfile() -> String {
  let path = "Taskfile.pkl"
  if @fs.path_exists(path) {
    path
  } else {
    die("Taskfile.pkl not found in current directory")
    panic()
  }
}

///|
async fn eval_taskfile(taskfile : String) -> String {
  // PKF-3a: embed mpkl's loader in-process to drop the ~30ms subprocess
  // startup. Falls back to the subprocess hop only when the embedded
  // loader can't service the request (HTTP modules, glob imports, etc.).
  match (try? @loader.eval_module_path(taskfile)) {
    Ok(@pkl.EvalOk(value)) =>
      @pkl.render_value_as_json(extract_output_value(value))
    Ok(@pkl.EvalError(errors)) => {
      for e in errors {
        println("pkf: " + e.message)
      }
      die("mpkl eval failed")
      panic()
    }
    Err(err) =>
      // Fallback: spawn the mpkl CLI for cases the embedded loader can't
      // service (e.g. HTTP imports).
      eval_taskfile_via_subprocess(taskfile, err.message())
  }
}

///|
fn extract_output_value(value : @pkl.Value) -> @pkl.Value {
  // Module is rendered as ObjectValue with an `output { value = ... }`
  // member. Peel that off so the JSON we hand parse_plan looks the same
  // as `mpkl eval -f json` would have produced.
  match value {
    @pkl.ObjectValue(members) => {
      for m in members {
        if m.name == "output" {
          match m.value {
            @pkl.ObjectValue(sub) =>
              for s in sub {
                if s.name == "value" {
                  return s.value
                }
              }
            _ => ()
          }
        }
      }
      value
    }
    _ => value
  }
}

///|
async fn eval_taskfile_via_subprocess(
  taskfile : String,
  reason : String,
) -> String {
  println("pkf: # embedded loader fell back to mpkl CLI (\{reason})")
  let (code, stdout) = @process.collect_stdout("mpkl", [
    "eval", "-f", "json", taskfile,
  ])
  if code != 0 {
    die("mpkl eval failed with exit code \{code}")
  }
  stdout.text()
}

///|
///|
struct ParsedRunArgs {
  target : String
  flags : Map[String, String]
  positionals : Array[String]
}

///|
fn parse_run_args(args : ArrayView[String]) -> ParsedRunArgs {
  // Layout: `<task> [--name=value | --name value | --flag] [-- positional...]`
  let mut target : String? = None
  let flags : Map[String, String] = Map([], capacity=4)
  let positionals : Array[String] = []
  let mut i = 0
  let mut after_dash_dash = false
  while i < args.length() {
    let arg = args[i]
    if after_dash_dash {
      positionals.push(arg)
      i = i + 1
      continue
    }
    if arg == "--" {
      after_dash_dash = true
      i = i + 1
      continue
    }
    if arg.has_prefix("--") {
      let stripped = arg.substring(start=2, end=arg.length())
      match stripped.find("=") {
        Some(idx) => {
          let key = stripped.substring(start=0, end=idx)
          let value = stripped.substring(start=idx + 1, end=stripped.length())
          flags[key] = value
        }
        None =>
          // bool flag: `--flag` alone means "true".
          flags[stripped] = "true"
      }
      i = i + 1
      continue
    }
    if target is None {
      target = Some(arg)
    } else {
      positionals.push(arg)
    }
    i = i + 1
  }
  ParsedRunArgs::{
    target: match target {
      Some(t) => t
      None => ""
    },
    flags,
    positionals,
  }
}

///|
fn resolve_task_params(
  task : Task,
  provided : Map[String, String],
) -> Map[String, String]? {
  // Returns the resolved (name -> value) map after validating types
  // against the task's declared params. Unknown CLI flags are ignored;
  // only the task's declared params surface as env vars. None on
  // validation failure.
  let resolved : Map[String, String] = Map([], capacity=task.params.length())
  for p in task.params {
    let value : String? = match provided.get(p.name) {
      Some(v) => Some(v)
      None => p.default
    }
    let v = match value {
      Some(s) => s
      None => {
        println("pkf: missing required --\{p.name} for task `\{task.name}`")
        return None
      }
    }
    if !validate_param_value(p, v) {
      return None
    }
    resolved[p.name] = v
  }
  Some(resolved)
}

///|
fn validate_param_value(p : Param, value : String) -> Bool {
  match p.ptype {
    "enum" => {
      for choice in p.choices {
        if choice == value {
          return true
        }
      }
      println(
        "pkf: --\{p.name}=\{value} is not a valid choice for `\{p.name}`",
      )
      false
    }
    "int" =>
      match (try? @strconv.parse_int64(value)) {
        Ok(_) => true
        Err(_) => {
          println("pkf: --\{p.name}=\{value} is not a valid int")
          false
        }
      }
    "bool" =>
      if value == "true" || value == "false" {
        true
      } else {
        println("pkf: --\{p.name}=\{value} is not a valid bool")
        false
      }
    _ => true
  }
}

///|
fn upcase(name : String) -> String {
  let buf = StringBuilder::new(size_hint=name.length())
  for i in 0..<name.length() {
    let c = name[i]
    if c >= 'a' && c <= 'z' {
      buf.write_char(
        Int::unsafe_to_char(c.to_int() - 'a'.to_int() + 'A'.to_int()),
      )
    } else {
      buf.write_char(c.to_int().unsafe_to_char())
    }
  }
  buf.to_string()
}

///|
// ---------------------------------------------------------------------------
// `pkf affected` — given a set of changed file paths, compute the run plan.
//
// Algorithm:
//   1. `direct` = every task whose declared `inputs` glob matches a
//      changed path. Ordered by authored task_order.
//   2. Expand to `affected` via reverse-edge closure: if task A is in
//      `affected` and another task B has A in its `deps`, B becomes
//      affected too (a dependent re-runs when its dep is dirty).
//   3. Expand each affected task to include its own transitive deps
//      (so the plan is closed under "needs to run before me").
//   4. Topological sort over the resulting set.
//
// `--check` re-runs each declared `WorkflowTest` against the algorithm
// and asserts the computed plan matches the test's `tasks` (and
// optionally `direct`) — handy for catching schema drift in CI.
// ---------------------------------------------------------------------------

///|
fn task_inputs_match_any(task : Task, changed : Array[String]) -> Bool {
  for change in changed {
    for pattern in task.inputs {
      if glob_match(pattern, change) {
        return true
      }
    }
  }
  false
}

///|
fn compute_affected(
  plan : Plan,
  changed : Array[String],
) -> (Array[String], Array[String]) {
  // Direct hits: tasks whose inputs glob matches a changed path.
  let direct_set : Map[String, Bool] = Map([], capacity=plan.task_order.length())
  let direct : Array[String] = []
  for name in plan.task_order {
    let task = match plan.tasks.get(name) {
      Some(t) => t
      None => continue
    }
    if task_inputs_match_any(task, changed) {
      direct_set[name] = true
      direct.push(name)
    }
  }
  // Reverse-edge closure: pull every dependent of an already-affected
  // task into the affected set. Loop until the set stops growing.
  let affected : Map[String, Bool] = Map([], capacity=plan.task_order.length())
  for n in direct {
    affected[n] = true
  }
  let mut changed_set = true
  while changed_set {
    changed_set = false
    for name in plan.task_order {
      if affected.get(name) is Some(true) {
        continue
      }
      let task = match plan.tasks.get(name) {
        Some(t) => t
        None => continue
      }
      for dep in task.deps {
        if affected.get(dep) is Some(true) {
          affected[name] = true
          changed_set = true
          break
        }
      }
    }
  }
  // Pull in each affected task's own deps so the plan is runnable.
  let plan_set : Map[String, Bool] = Map([], capacity=affected.length())
  for name, _ in affected {
    let order = topo_sort_for(name, plan)
    for n in order {
      plan_set[n] = true
    }
  }
  // Produce the final plan in topological order. We compute the topo
  // for each affected task and union; then re-emit in plan.task_order's
  // authored ordering (filtered to plan_set members) — that matches
  // Apple pkfire's output, which sorts the affected set by authored
  // order and then expands deps. For multi-root sets we walk each
  // affected task's topo and dedupe; the result is the affected set
  // listed in the order they'd run.
  let final_plan : Array[String] = []
  let seen : Map[String, Bool] = Map([], capacity=plan_set.length())
  for name in plan.task_order {
    if plan_set.get(name) is Some(true) && seen.get(name) is None {
      final_plan.push(name)
      seen[name] = true
    }
  }
  // Sort with deps before dependents within the affected set: walk
  // plan.task_order forward but emit each task only after its deps
  // have been emitted. The simple authored-order pass above is wrong
  // when an inserted dep sits later in task_order than its dependent
  // (rare but possible). Reorder with a classical DFS topo sort
  // restricted to plan_set.
  let topo_out : Array[String] = []
  let topo_visited : Map[String, Bool] = Map([], capacity=plan_set.length())
  let topo_stack : Map[String, Bool] = Map([], capacity=plan_set.length())
  fn visit(name : String) -> Unit {
    if topo_visited.get(name) is Some(true) {
      return
    }
    if topo_stack.get(name) is Some(true) {
      return
    }
    topo_stack[name] = true
    let task = match plan.tasks.get(name) {
      Some(t) => t
      None => {
        let _ = topo_stack.remove(name)
        return
      }
    }
    for dep in task.deps {
      if plan_set.get(dep) is Some(true) {
        visit(dep)
      }
    }
    let _ = topo_stack.remove(name)
    topo_visited[name] = true
    topo_out.push(name)
  }

  for name in final_plan {
    visit(name)
  }
  (direct, topo_out)
}

///|
async fn affected_cmd(args : ArrayView[String]) -> Int {
  let mut check_mode = false
  let mut changed_file : String? = None
  let positional : Array[String] = []
  let mut i = 0
  while i < args.length() {
    let arg = args[i]
    if arg == "--check" {
      check_mode = true
    } else if arg.has_prefix("--changed=") {
      changed_file = Some(arg.substring(start=10, end=arg.length()))
    } else if arg.has_prefix("--") {
      die("pkf affected: unknown flag `\{arg}`")
      return 2
    } else {
      positional.push(arg)
    }
    i = i + 1
  }
  let taskfile = locate_taskfile()
  let raw_json = eval_taskfile(taskfile)
  let plan = parse_plan(raw_json)
  if check_mode {
    if plan.workflow_tests.length() == 0 {
      println("pkf affected --check: no workflowTests declared")
      return 0
    }
    let mut failed = 0
    for wt in plan.workflow_tests {
      let (direct, computed) = compute_affected(plan, wt.changed)
      let plan_ok = string_arrays_equal(computed, wt.tasks)
      let direct_ok = wt.direct.length() == 0 ||
        string_arrays_equal(direct, wt.direct)
      if plan_ok && direct_ok {
        println("PASS  \{wt.name}")
      } else {
        failed = failed + 1
        println("FAIL  \{wt.name}")
        if !plan_ok {
          println("  expected plan:   " + join_list(wt.tasks))
          println("  computed plan:   " + join_list(computed))
        }
        if !direct_ok {
          println("  expected direct: " + join_list(wt.direct))
          println("  computed direct: " + join_list(direct))
        }
      }
    }
    if failed > 0 {
      println("\{failed} / \{plan.workflow_tests.length()} workflow tests failed")
      return 1
    }
    println("all \{plan.workflow_tests.length()} workflow tests passed")
    0
  } else {
    if positional.length() == 0 && changed_file is None {
      die(
        "pkf affected: expected at least one positional <path> or --changed=<file>",
      )
      return 2
    }
    let changed : Array[String] = []
    for p in positional {
      changed.push(p)
    }
    match changed_file {
      Some(_) => {
        // Reading from a file would require @fs streaming; leave as a
        // future improvement.
        die("pkf affected: --changed=<file> is not yet supported")
        return 2
      }
      None => ()
    }
    let (_, computed) = compute_affected(plan, changed)
    for name in computed {
      println(name)
    }
    0
  }
}

///|
fn string_arrays_equal(a : Array[String], b : Array[String]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i in 0..<a.length() {
    if a[i] != b[i] {
      return false
    }
  }
  true
}

///|
fn join_list(items : Array[String]) -> String {
  let mut out = "["
  for i, item in items {
    if i > 0 {
      out = out + ", "
    }
    out = out + item
  }
  out + "]"
}

// ---------------------------------------------------------------------------
// `pkf list` / `pkf graph` — repo-level introspection over the Taskfile.
// ---------------------------------------------------------------------------

///|
async fn list_cmd(args : ArrayView[String]) -> Int {
  let mut verbose = false
  let mut show_all = false
  for arg in args {
    match arg {
      "-v" | "--verbose" => verbose = true
      "--all" => show_all = true
      _ => {
        die("pkf list: unknown flag `\{arg}`")
        return 2
      }
    }
  }
  let taskfile = locate_taskfile()
  let raw_json = eval_taskfile(taskfile)
  let plan = parse_plan(raw_json)
  let visible : Array[String] = []
  for name in plan.task_order {
    let task = match plan.tasks.get(name) {
      Some(t) => t
      None => continue
    }
    if !show_all && task.visibility == "internal" {
      continue
    }
    visible.push(name)
  }
  if visible.length() == 0 {
    println("pkf: no tasks defined")
    return 0
  }
  let mut max_name = 0
  for name in visible {
    if name.length() > max_name {
      max_name = name.length()
    }
  }
  for name in visible {
    let task = plan.tasks.get(name).unwrap()
    let desc = match task.description {
      Some(d) => d
      None => ""
    }
    let pad = String::make(max_name - name.length() + 2, ' ')
    let tag = if task.service { " [service]" } else { "" }
    println(name + pad + desc + tag)
    if verbose {
      if task.params.length() > 0 {
        for p in task.params {
          let default = match p.default {
            Some(d) => "=" + d
            None => " (required)"
          }
          println("    --" + p.name + default + "  : " + p.ptype)
        }
      }
      if task.deps.length() > 0 {
        let mut joined = ""
        for i, dep in task.deps {
          if i > 0 {
            joined = joined + ", "
          }
          joined = joined + dep
        }
        println("    deps: " + joined)
      }
      if task.inputs.length() > 0 {
        let mut joined = ""
        for i, inp in task.inputs {
          if i > 0 {
            joined = joined + ", "
          }
          joined = joined + inp
        }
        println("    inputs: " + joined)
      }
      if task.outputs.length() > 0 {
        let mut joined = ""
        for i, out in task.outputs {
          if i > 0 {
            joined = joined + ", "
          }
          joined = joined + out
        }
        println("    outputs: " + joined)
      }
    }
  }
  0
}

///|
fn render_graph_node(
  plan : Plan,
  name : String,
  prefix : String,
  is_last : Bool,
  seen : Map[String, Bool],
) -> Unit {
  let task = match plan.tasks.get(name) {
    Some(t) => t
    None => return
  }
  let branch = if is_last { "└─ " } else { "├─ " }
  println(prefix + branch + name)
  if seen.get(name) is Some(true) {
    return
  }
  seen[name] = true
  let next_prefix = prefix + (if is_last { "   " } else { "│  " })
  for i, dep in task.deps {
    let last = i == task.deps.length() - 1
    render_graph_node(plan, dep, next_prefix, last, seen)
  }
}

///|
async fn graph_cmd(args : ArrayView[String]) -> Int {
  let mut show_all = false
  for arg in args {
    match arg {
      "--all" => show_all = true
      _ => {
        die("pkf graph: unknown flag `\{arg}`")
        return 2
      }
    }
  }
  let taskfile = locate_taskfile()
  let raw_json = eval_taskfile(taskfile)
  let plan = parse_plan(raw_json)
  for name in plan.task_order {
    let task = match plan.tasks.get(name) {
      Some(t) => t
      None => continue
    }
    if !show_all && task.visibility == "internal" {
      continue
    }
    println(name)
    let seen : Map[String, Bool] = Map([], capacity=8)
    seen[name] = true
    for i, dep in task.deps {
      let last = i == task.deps.length() - 1
      render_graph_node(plan, dep, "", last, seen)
    }
  }
  0
}

///|
///|
async fn[X] run_main(group : @async.TaskGroup[X], args : Array[String]) -> Int {
  if args.length() < 1 {
    let msg =
      #|usage: pkf <command> [args...]
      #|
      #|commands:
      #|  run <task> [--name=value]... [-- positional...]
      #|  list [-v] [--all]
      #|  graph [--all]
      #|  affected <path>... | --check
    println(msg)
    return 2
  }
  match args[0] {
    "list" => list_cmd(args[1:])
    "graph" => graph_cmd(args[1:])
    "affected" => affected_cmd(args[1:])
    "run" => {
      let parsed = parse_run_args(args[1:])
      if parsed.target.length() == 0 {
        die("pkf run: missing <task> argument")
      }
      let target = parsed.target
      let taskfile = locate_taskfile()
      let raw_json = eval_taskfile(taskfile)
      let plan = parse_plan(raw_json)
      match plan.tasks.get(target) {
        Some(t) =>
          if t.service {
            die(
              "task `\{target}` is a `service` (start it with `pkf up` once supported, not `pkf run`)",
            )
            return 2
          }
        None => ()
      }
      let order = topo_sort_for(target, plan)
      let repo_root = "."
      for name in order {
        let task = plan.tasks.get(name).unwrap()
        // CLI flags / positional args only apply to the explicit target.
        let (flags, positionals) = if name == target {
          (parsed.flags, parsed.positionals)
        } else {
          (Map([], capacity=0), [])
        }
        if name != target && positionals.length() > 0 {
          // unreachable — positionals are emptied for non-target tasks.
          ignore(positionals)
        }
        if !task.accepts_args && name == target && parsed.positionals.length() > 0 {
          die(
            "pkf run: task `\{target}` does not accept positional args " +
            "(set `acceptsArgs = true` to allow)",
          )
        }
        let resolved_params = match resolve_task_params(task, flags) {
          Some(m) => m
          None => return 2
        }
        let code = run_task(group, plan, task, repo_root, resolved_params, positionals)
        if code != 0 {
          println("pkf: task `\{name}` failed with exit code \{code}")
          return code
        }
      }
      0
    }
    other => {
      die("unknown subcommand `\{other}` (only `run` is supported in this MVP)")
      1
    }
  }
}

///|
async fn main {
  let args = @sys.get_cli_args()
  // The first argv entry is the binary path; skip it.
  let trimmed : Array[String] = []
  for i in 1..<args.length() {
    trimmed.push(args[i])
  }
  let code = @async.with_task_group(fn(group) { run_main(group, trimmed) })
  @sys.exit(code)
}
