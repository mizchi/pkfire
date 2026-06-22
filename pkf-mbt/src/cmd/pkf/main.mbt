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
  description : String?
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
  quiet : Bool
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
  default_shell : String
  default_shell_flags : Array[String]
  tasks : Map[String, Task]
  task_order : Array[String]
  workflow_tests : Array[WorkflowTest]
}

///|
fn die(message : String) -> Unit {
  eprintln("pkf: \{message}")
  @sys.exit(1)
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
    let quiet = match task_entries.get("quiet") {
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
              let pdesc = match p.get("description") {
                Some(String(s)) => Some(s)
                _ => None
              }
              params.push(
                Param::{ name: pname, ptype, choices, default, description: pdesc },
              )
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
      quiet,
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
  Plan::{ default_env, default_shell, default_shell_flags, tasks, task_order, workflow_tests }
}

// ---------------------------------------------------------------------------
// JSON encoder helpers — used by `list --json` (and graph --json later).
// ---------------------------------------------------------------------------

///|
fn jbool(b : Bool) -> Json {
  Json::boolean(b)
}

///|
fn jstr_array(xs : Array[String]) -> Json {
  let arr : Array[Json] = []
  for x in xs {
    arr.push(Json::string(x))
  }
  Json::array(arr)
}

///|
fn task_to_json(
  t : Task,
  with_kind : Bool,
  keep : Map[String, Bool]?,
) -> Json {
  let o : Map[String, Json] = Map([], capacity=16)
  o["name"] = Json::string(t.name)
  match t.description {
    Some(d) => o["description"] = Json::string(d)
    None => ()
  }
  o["visibility"] = Json::string(t.visibility)
  o["cmd"] = Json::string(t.cmd)
  o["shell"] = Json::string(t.shell)
  o["shellFlags"] = jstr_array(t.shell_flags)
  if t.inputs.length() > 0 {
    o["inputs"] = jstr_array(t.inputs)
  }
  if t.outputs.length() > 0 {
    o["outputs"] = jstr_array(t.outputs)
  }
  // deps: filter to visible set when keep is provided (graph --json).
  // list --json (keep=None) emits deps unfiltered.
  let visible_deps = match keep {
    Some(k) => {
      let filtered : Array[String] = []
      for d in t.deps {
        if k.get(d) is Some(true) {
          filtered.push(d)
        }
      }
      filtered
    }
    None => t.deps
  }
  if visible_deps.length() > 0 {
    o["deps"] = jstr_array(visible_deps)
  }
  o["cache"] = jbool(t.cache)
  o["service"] = jbool(t.service)
  o["quiet"] = jbool(t.quiet)
  // services: filter to visible set when keep is provided (graph --json).
  let visible_services = match keep {
    Some(k) => {
      let filtered : Array[String] = []
      for s in t.services {
        if k.get(s) is Some(true) {
          filtered.push(s)
        }
      }
      filtered
    }
    None => t.services
  }
  if visible_services.length() > 0 {
    o["services"] = jstr_array(visible_services)
  }
  o["acceptsArgs"] = jbool(t.accepts_args)
  o["inheritEnv"] = jbool(t.inherit_env)
  match t.workdir {
    Some(wd) => o["workdir"] = Json::string(wd)
    None => ()
  }
  if t.params.length() > 0 {
    let parr : Array[Json] = []
    for p in t.params {
      parr.push(param_to_json(p))
    }
    o["params"] = Json::array(parr)
  }
  if with_kind {
    let kind = if t.service {
      "service"
    } else if t.cmd == "" && t.deps.length() > 0 {
      "aggregate"
    } else if t.cmd == "" {
      "noop"
    } else {
      "task"
    }
    o["kind"] = Json::string(kind)
  }
  Json::object(o)
}

///|
fn param_to_json(p : Param) -> Json {
  let o : Map[String, Json] = Map([], capacity=6)
  o["name"] = Json::string(p.name)
  let typ = if p.ptype.length() == 0 { "string" } else { p.ptype }
  o["type"] = Json::string(typ)
  match p.default {
    Some(d) => o["default"] = Json::string(d)
    None => ()
  }
  if p.choices.length() > 0 {
    o["choices"] = jstr_array(p.choices)
  }
  match p.description {
    Some(d) => o["description"] = Json::string(d)
    None => ()
  }
  Json::object(o)
}

///|
fn describe_to_json(t : Task) -> Json {
  let o : Map[String, Json] = Map([], capacity=16)
  o["name"] = Json::string(t.name)
  match t.description {
    Some(d) => o["description"] = Json::string(d)
    None => ()
  }
  o["visibility"] = Json::string(t.visibility)
  // service: omit when false (omitempty)
  if t.service {
    o["service"] = jbool(true)
  }
  match t.workdir {
    Some(wd) => o["workdir"] = Json::string(wd)
    None => ()
  }
  if t.params.length() > 0 {
    let arr : Array[Json] = []
    for p in t.params {
      arr.push(param_to_json(p))
    }
    o["params"] = Json::array(arr)
  }
  // acceptsArgs: omit when false (omitempty)
  if t.accepts_args {
    o["acceptsArgs"] = jbool(true)
  }
  if t.inputs.length() > 0 {
    o["inputs"] = jstr_array(t.inputs)
  }
  if t.outputs.length() > 0 {
    o["outputs"] = jstr_array(t.outputs)
  }
  // cache: always present
  o["cache"] = jbool(t.cache)
  if t.deps.length() > 0 {
    o["deps"] = jstr_array(t.deps)
  }
  if t.services.length() > 0 {
    o["services"] = jstr_array(t.services)
  }
  o["cmd"] = Json::string(t.cmd)
  if t.env.length() > 0 {
    let env_o : Map[String, Json] = Map([], capacity=t.env.length())
    for k, v in t.env {
      env_o[k] = Json::string(v)
    }
    o["env"] = Json::object(env_o)
  }
  if t.tools.length() > 0 {
    let tools_o : Map[String, Json] = Map([], capacity=t.tools.length())
    for k, v in t.tools {
      tools_o[k] = Json::string(v)
    }
    o["tools"] = Json::object(tools_o)
  }
  // specRef is not tracked in MoonBit's Task struct — omitted.
  Json::object(o)
}

///|
/// Lexicographic string comparison (char-by-char, shorter prefix wins).
/// MoonBit's built-in String::compare sorts by length first, so we need
/// this explicit comparator for alphabetical ordering.
fn lex_cmp(a : String, b : String) -> Int {
  let la = a.length()
  let lb = b.length()
  let min_len = if la < lb { la } else { lb }
  for i in 0..<min_len {
    let ca = a[i].to_int()
    let cb = b[i].to_int()
    if ca != cb {
      return ca - cb
    }
  }
  la - lb
}

///|
fn sorted_visible_tasks(plan : Plan, include_all : Bool) -> Array[Task] {
  let names : Array[String] = []
  for name in plan.task_order {
    match plan.tasks.get(name) {
      Some(t) =>
        if include_all || t.visibility != "internal" {
          names.push(name)
        }
      None => ()
    }
  }
  names.sort_by(fn(a, b) { lex_cmp(a, b) })
  let out : Array[Task] = []
  for n in names {
    match plan.tasks.get(n) {
      Some(t) => out.push(t)
      None => ()
    }
  }
  out
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
// ---------------------------------------------------------------------------
// File-mode preservation.
//
// MoonBit's fs surface exposes `chmod` but not `stat`, so we can't read
// the source file's mode at store time. Instead, detect executable
// payloads by their magic bytes (ELF / Mach-O / Mach-O fat / Windows
// PE / shebang) and record a "755" mode in the manifest. The restore
// path reads the recorded mode and applies it via `@mfs.chmod`.
// ---------------------------------------------------------------------------

///|
fn looks_executable(bytes : Bytes) -> Bool {
  if bytes.length() < 2 {
    return false
  }
  let b0 = bytes[0].to_int()
  let b1 = bytes[1].to_int()
  // Shebang
  if b0 == 0x23 && b1 == 0x21 {
    return true
  }
  if bytes.length() < 4 {
    return false
  }
  let b2 = bytes[2].to_int()
  let b3 = bytes[3].to_int()
  // ELF: 0x7F 'E' 'L' 'F'
  if b0 == 0x7f && b1 == 0x45 && b2 == 0x4c && b3 == 0x46 {
    return true
  }
  // Mach-O 64 LE: cf fa ed fe
  if b0 == 0xcf && b1 == 0xfa && b2 == 0xed && b3 == 0xfe {
    return true
  }
  // Mach-O 32 LE: ce fa ed fe
  if b0 == 0xce && b1 == 0xfa && b2 == 0xed && b3 == 0xfe {
    return true
  }
  // Mach-O 64 BE: fe ed fa cf
  if b0 == 0xfe && b1 == 0xed && b2 == 0xfa && b3 == 0xcf {
    return true
  }
  // Mach-O 32 BE: fe ed fa ce
  if b0 == 0xfe && b1 == 0xed && b2 == 0xfa && b3 == 0xce {
    return true
  }
  // Mach-O fat: ca fe ba be (also Java class — caller domain is build
  // outputs, not class files, so treating as executable is fine).
  if b0 == 0xca && b1 == 0xfe && b2 == 0xba && b3 == 0xbe {
    return true
  }
  // Windows PE: 'M' 'Z'
  if b0 == 0x4d && b1 == 0x5a {
    return true
  }
  false
}

///|
///|
/// FFI: stat(2) → lower 12 bits of st_mode, or -1 on failure / Windows.
#borrow(path)
extern "C" fn stat_mode_ffi(path : Bytes) -> Int = "mizchi_pkf_stat_mode"

///|
/// FFI: write bytes to stderr (fd 2) verbatim.
#borrow(s)
extern "C" fn eprint_ffi(s : Bytes) -> Unit = "mizchi_pkf_eprint"

///|
/// Write a line to stderr (mirrors `println`, but fd 2).
fn eprintln(message : String) -> Unit {
  eprint_ffi(@utf8.encode(message + "\n"))
}

///|
fn detect_file_mode(path : String) -> Int {
  // Preferred: ask the OS via stat(2). The full mode (rwx + sticky)
  // round-trips through cache_store / cache_restore that way, so files
  // like `0o600` private keys or `0o444` generated read-only outputs
  // keep their permissions.
  let path_z = @utf8.encode(path + "\u{00}")
  let m = stat_mode_ffi(path_z)
  if m >= 0 {
    return m
  }
  // Fallback (Windows or stat error): the previous magic-byte heuristic.
  // 0o755 for ELF / Mach-O / PE / shebang, 0o644 otherwise.
  let bytes = @fs.read_file_to_bytes(path) catch {
    _ => Bytes::new(0)
  }
  if looks_executable(bytes) {
    0o755
  } else {
    0o644
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
  // Pre-expand `{a,b,c}` brace alternations into a flat list of patterns;
  // segment-and-step matching is unchanged below.
  for expanded in brace_expand(pattern) {
    let p_segs = expanded.split("/").collect()
    let s_segs = path.split("/").collect()
    if glob_segs(p_segs, 0, s_segs, 0) {
      return true
    }
  }
  false
}

///|
/// Recursively expand `{a,b,c}` brace alternations into a flat list. Nested
/// braces are handled. Commas inside nested braces are not split-points.
/// An unmatched `{` is treated as a literal (pattern returned as-is).
fn brace_expand(pattern : String) -> Array[String] {
  let mut open = -1
  let mut close = -1
  let mut depth = 0
  for i in 0..<pattern.length() {
    let c = pattern[i]
    if c == '{' {
      if open < 0 {
        open = i
      }
      depth = depth + 1
    } else if c == '}' {
      depth = depth - 1
      if depth == 0 {
        close = i
        break
      }
    }
  }
  if open < 0 || close < 0 {
    return [pattern]
  }
  let before = pattern[:open].to_owned()
  let body = pattern[open + 1:close].to_owned()
  let after = pattern[close + 1:].to_owned()
  let parts : Array[String] = []
  let mut start = 0
  let mut d = 0
  for i in 0..<body.length() {
    let c = body[i]
    if c == '{' {
      d = d + 1
    } else if c == '}' {
      d = d - 1
    } else if c == ',' && d == 0 {
      parts.push(body[start:i].to_owned())
      start = i + 1
    }
  }
  parts.push(body[start:].to_owned())
  let result : Array[String] = []
  for part in parts {
    for sub in brace_expand(before + part + after) {
      result.push(sub)
    }
  }
  result
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
  // Single-segment matcher: supports `*` (any chars no slash), `?`, and
  // `[abc]` / `[!abc]` / `[a-z]` character classes.
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
    if pc == '[' {
      // Locate the matching `]`. If absent, fall back to treating `[` as a
      // literal so unbalanced patterns still match something predictable.
      let class_start = if pi + 1 < pat.length() && pat[pi + 1] == '!' {
        pi + 2
      } else {
        pi + 1
      }
      let mut class_end = -1
      for j = class_start; j < pat.length(); j = j + 1 {
        if pat[j] == ']' {
          class_end = j
          break
        }
      }
      if class_end < 0 {
        // Treat `[` as a literal.
        if si >= seg.length() || pc != seg[si] {
          return false
        }
        pi = pi + 1
        si = si + 1
        continue
      }
      if si >= seg.length() {
        return false
      }
      let sc = seg[si]
      let negate = class_start == pi + 2
      let mut hit = false
      let mut k = class_start
      while k < class_end {
        if k + 2 < class_end && pat[k + 1] == '-' {
          let lo = pat[k]
          let hi = pat[k + 2]
          if sc >= lo && sc <= hi {
            hit = true
          }
          k = k + 3
        } else {
          if pat[k] == sc {
            hit = true
          }
          k = k + 1
        }
      }
      let matched = if negate { !hit } else { hit }
      if !matched {
        return false
      }
      pi = class_end + 1
      si = si + 1
      continue
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
  // Pre-expand `{a,b}` brace alternations to the same flat pattern list
  // glob_match uses internally; this keeps the literal-path fast path
  // viable for each alternative.
  if pattern.contains("{") {
    for alt in brace_expand(pattern) {
      expand_glob(root, alt, out)
    }
    return
  }
  // Fast path: literal pattern with no wildcard / class.
  if !pattern.contains("*") &&
    !pattern.contains("?") &&
    !pattern.contains("[") {
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
  // Single-archive format: every output goes into one `entry.tar.gz` blob
  // under <cache_dir>/<key[0:2]>/<key[2:]>/. Tar headers carry the mode,
  // so there's no separate manifest file. Wire-incompatible with go
  // pkfire (BLAKE3 + zstd) on purpose.
  let dir = entry_dir(key)
  rm_rf(dir)
  mkdir_p(dir)
  let tb = tar_new()
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
      let inner : Array[String] = []
      walk_files(src, rel, inner)
      for nested in inner {
        let nested_src = join_path(root, nested)
        let content = @fs.read_file_to_bytes(nested_src) catch {
          _ => continue
        }
        let mode = detect_file_mode(nested_src)
        tar_write_entry(tb, nested, content, mode)
      }
    } else {
      let content = @fs.read_file_to_bytes(src) catch {
        _ => continue
      }
      let mode = detect_file_mode(src)
      tar_write_entry(tb, rel, content, mode)
    }
  }
  let archive = @zlib.gzip_compress(tar_finish(tb))
  @fs.write_bytes_to_file(join_path(dir, "entry.tar.gz"), archive) catch {
    _ => ()
  }
}

///|
async fn cache_restore(key : String, root : String) -> Unit {
  let dir = entry_dir(key)
  let archive_path = join_path(dir, "entry.tar.gz")
  let gz = @fs.read_file_to_bytes(archive_path) catch {
    _ => return
  }
  let tar = try @zlib.gzip_decompress(gz) catch {
    _ => return
  }
  for entry in tar_iter(tar) {
    let dst = if root.length() == 0 || root == "." {
      entry.name
    } else {
      join_path(root, entry.name)
    }
    let parent = dirname(dst)
    if parent.length() > 0 {
      mkdir_p(parent)
    }
    @fs.write_bytes_to_file(dst, entry.content) catch {
      _ => continue
    }
    // Preserve the recorded mode (executable bit, etc.). Best-effort:
    // chmod failures are swallowed so a read-only target FS doesn't
    // abort the restore.
    @xfs.chmod(dst.view(), entry.mode) catch {
      _ => ()
    }
  }
}

// ---------------------------------------------------------------------------
// Remote cache (HTTP). Layered on top of the local CAS — every fetch
// warms local, every store fires-and-forgets to remote. Failures on
// the remote path are silent (logged at most); they never block the
// task. The wire layout mirrors the local one to keep the swap
// trivial:
//
//   <base>/cas/<key[0:2]>/<key[2:]>/manifest
//   <base>/cas/<key[0:2]>/<key[2:]>/outputs/<rel>
//
// One GET / PUT per file. Archive support deferred to a follow-up
// (would need tar + zstd, neither shipped in the MoonBit ecosystem
// today).
// ---------------------------------------------------------------------------

///|
fn remote_base() -> String? {
  match @sys.get_env_var("PKFIRE_MBT_REMOTE_CACHE") {
    Some(s) =>
      if s.length() == 0 {
        None
      } else if s.has_suffix("/") {
        Some(s.substring(start=0, end=s.length() - 1))
      } else {
        Some(s)
      }
    None => None
  }
}

///|
fn remote_token() -> String? {
  @sys.get_env_var("PKFIRE_MBT_REMOTE_TOKEN")
}

///|
fn remote_headers() -> Map[String, String] {
  let h : Map[String, String] = Map([], capacity=2)
  match remote_token() {
    Some(t) => h["Authorization"] = "Bearer " + t
    None => ()
  }
  h
}

///|
fn remote_entry_url(base : String, key : String) -> String {
  let head = key.substring(start=0, end=2)
  let tail = key.substring(start=2, end=key.length())
  base + "/cas/" + head + "/" + tail
}

///|
async fn remote_get_bytes(url : String) -> Bytes? {
  let headers = remote_headers()
  match (try? @http.get(url, headers~)) {
    Ok((resp, data)) =>
      if resp.code == 200 {
        // `&Data::binary` returns the raw response bytes without any
        // UTF-8 round-trip. `data.text().to_bytes()` would re-encode
        // the bytes as UTF-16 (MoonBit's String.to_bytes default),
        // wrecking binary payloads (Mach-O / ELF / archives).
        Some(data.binary())
      } else {
        None
      }
    Err(_) => None
  }
}

///|
async fn remote_put_bytes(url : String, bytes : Bytes) -> Bool {
  let headers = remote_headers()
  match (try? @http.put(url, bytes, headers~)) {
    Ok((resp, _)) => resp.code >= 200 && resp.code < 300
    Err(_) => false
  }
}

///|
async fn cache_remote_fetch(key : String, root : String) -> Bool {
  // Pull from the remote cache into the local CAS, then restore.
  // Single archive at <base>/cas/<key[0:2]>/<key[2:]>/entry.tar.gz —
  // one HTTP round-trip per entry.
  let base = match remote_base() {
    Some(b) => b
    None => return false
  }
  let entry_url = remote_entry_url(base, key) + "/entry.tar.gz"
  let archive = match remote_get_bytes(entry_url) {
    Some(b) => b
    None => return false
  }
  let dir = entry_dir(key)
  mkdir_p(dir)
  @fs.write_bytes_to_file(join_path(dir, "entry.tar.gz"), archive) catch {
    _ => {
      rm_rf(dir)
      return false
    }
  }
  cache_restore(key, root)
  true
}

///|
async fn cache_remote_push(key : String) -> Unit {
  // Best-effort upload after a successful local store. Single PUT
  // of the local entry.tar.gz. Failures are logged once.
  let base = match remote_base() {
    Some(b) => b
    None => return
  }
  let dir = entry_dir(key)
  let archive_path = join_path(dir, "entry.tar.gz")
  let body = @fs.read_file_to_bytes(archive_path) catch {
    _ => return
  }
  let entry_url = remote_entry_url(base, key) + "/entry.tar.gz"
  let ok = remote_put_bytes(entry_url, body)
  if !ok {
    println(
      "pkf: remote cache PUT failed for \{key.substring(start=0, end=8)} (ignored)",
    )
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
    if cache_remote_fetch(k, repo_root) {
      println("pkf: # \{task.name} (remote cache hit \{k.substring(start=0, end=8)})")
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
  // C2: always run the task command in the Taskfile's directory (repo_root)
  // so that inputs/outputs resolve relative to the project root, not the
  // caller's cwd. If task.workdir is set, resolve it against repo_root.
  let task_cwd = match task.workdir {
    Some(wd) =>
      if wd.has_prefix("/") {
        wd
      } else if repo_root.length() == 0 || repo_root == "." {
        wd
      } else {
        repo_root + "/" + wd
      }
    None =>
      if repo_root.length() == 0 {
        "."
      } else {
        repo_root
      }
  }
  let code = @process.run_inherit(
    task.shell.view(),
    argv[:],
    extra_env~,
    inherit_env=task.inherit_env,
    cwd=task_cwd.view(),
  )
  stop_services(running)
  if code == 0 {
    match key {
      Some(k) => {
        let resolved_outputs = expand_inputs(repo_root, task.outputs)
        cache_store(k, repo_root, resolved_outputs)
        cache_remote_push(k)
      }
      None => ()
    }
  }
  code
}

///|
/// Returns the parent directory of dir, or dir itself if dir is the filesystem root.
/// Uses the existing dirname() helper; handles the root "/" sentinel.
fn parent_dir(dir : String) -> String {
  let d = dirname(dir)
  // dirname returns "" when there is no slash (single component without a
  // leading "/").  Treat that as the root sentinel so the walk terminates.
  if d.length() == 0 { dir } else { d }
}

///|
/// Locate Taskfile.pkl: use explicit path if given, otherwise walk up from cwd.
/// Returns the absolute path to the Taskfile.pkl.
fn locate_taskfile(explicit : String?) -> String {
  match explicit {
    Some(p) =>
      if @fs.path_exists(p) {
        p
      } else {
        die("Taskfile.pkl not found: \{p}")
        panic()
      }
    None => {
      let cwd = match @env.current_dir() {
        Some(d) => d
        None => {
          die("Taskfile.pkl not found: could not determine current directory")
          panic()
        }
      }
      let mut dir = cwd
      while true {
        let candidate = dir + "/Taskfile.pkl"
        if @fs.path_exists(candidate) {
          return candidate
        }
        let p = parent_dir(dir)
        if p == dir {
          break
        }
        dir = p
      }
      die("Taskfile.pkl not found in current or any parent directory")
      panic()
    }
  }
}

///|
/// Returns the directory containing the given Taskfile path.
/// Falls back to "." for a bare filename with no directory component.
fn taskfile_dir(taskfile : String) -> String {
  let d = dirname(taskfile)
  if d.length() == 0 { "." } else { d }
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
fn pkf_version() -> String {
  "0.0.1"
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
///|
/// Classic Levenshtein edit distance — number of single-char inserts /
/// deletes / substitutions to transform `a` into `b`. Used by
/// `suggest_task_name` to find typo candidates for `pkf run <unknown>`.
fn levenshtein(a : String, b : String) -> Int {
  let m = a.length()
  let n = b.length()
  if m == 0 {
    return n
  }
  if n == 0 {
    return m
  }
  let stride = n + 1
  let dp : Array[Int] = Array::make((m + 1) * stride, 0)
  for i = 0; i <= m; i = i + 1 {
    dp[i * stride] = i
  }
  for j = 0; j <= n; j = j + 1 {
    dp[j] = j
  }
  for i = 1; i <= m; i = i + 1 {
    for j = 1; j <= n; j = j + 1 {
      let cost = if a[i - 1] == b[j - 1] { 0 } else { 1 }
      let del = dp[(i - 1) * stride + j] + 1
      let ins = dp[i * stride + (j - 1)] + 1
      let sub = dp[(i - 1) * stride + (j - 1)] + cost
      let m1 = if del < ins { del } else { ins }
      dp[i * stride + j] = if m1 < sub { m1 } else { sub }
    }
  }
  dp[m * stride + n]
}

///|
/// Print an "unknown task" diagnostic with up to 3 suggested near
/// matches (Levenshtein distance ≤ max(2, len/3)). Output goes to
/// stderr-equivalent (println) so it shows alongside the failure
/// summary.
fn suggest_task_name(target : String, plan : Plan) -> Unit {
  let threshold = if target.length() / 3 > 2 { target.length() / 3 } else { 2 }
  let pairs : Array[(Int, String)] = []
  for name in plan.task_order {
    let d = levenshtein(target, name)
    if d <= threshold {
      pairs.push((d, name))
    }
  }
  println("pkf run: unknown task `\{target}`")
  if pairs.length() == 0 {
    return
  }
  // Simple selection sort — task counts are small.
  for i = 0; i < pairs.length(); i = i + 1 {
    let mut min_j = i
    for j = i + 1; j < pairs.length(); j = j + 1 {
      if pairs[j].0 < pairs[min_j].0 {
        min_j = j
      }
    }
    if min_j != i {
      let tmp = pairs[i]
      pairs[i] = pairs[min_j]
      pairs[min_j] = tmp
    }
  }
  let take = if pairs.length() < 3 { pairs.length() } else { 3 }
  println("did you mean:")
  for i = 0; i < take; i = i + 1 {
    println("  \{pairs[i].1}")
  }
}

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
async fn affected_cmd(explicit_taskfile : String?, args : ArrayView[String]) -> Int {
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
  let taskfile = locate_taskfile(explicit_taskfile)
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
      Some(path) => {
        // Newline-separated paths — the canonical feed is
        // `git diff --name-only`. Trim whitespace and skip blanks.
        let content = @fs.read_file_to_string(path) catch {
          _ => {
            die("pkf affected: cannot read --changed=\{path}")
            return 2
          }
        }
        for line in content.split("\n") {
          let s = line.to_string().trim_space().to_string()
          if s.length() > 0 {
            changed.push(s)
          }
        }
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
async fn list_cmd(explicit_taskfile : String?, args : ArrayView[String]) -> Int {
  let mut verbose = false
  let mut show_all = false
  let mut json_flag = false
  for arg in args {
    match arg {
      "-v" | "--verbose" => verbose = true
      "--all" => show_all = true
      "--json" => json_flag = true
      _ => {
        die("pkf list: unknown flag `\{arg}`")
        return 2
      }
    }
  }
  let taskfile = locate_taskfile(explicit_taskfile)
  let raw_json = eval_taskfile(taskfile)
  let plan = parse_plan(raw_json)
  if json_flag {
    let arr : Array[Json] = []
    for t in sorted_visible_tasks(plan, show_all) {
      arr.push(task_to_json(t, false, None))
    }
    let root : Map[String, Json] = Map([], capacity=1)
    root["tasks"] = Json::array(arr)
    println(Json::object(root).stringify())
    return 0
  }
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
async fn graph_cmd(explicit_taskfile : String?, args : ArrayView[String]) -> Int {
  let mut show_all = false
  let mut json_flag = false
  for arg in args {
    match arg {
      "--all" => show_all = true
      "--json" => json_flag = true
      _ => {
        die("pkf graph: unknown flag `\{arg}`")
        return 2
      }
    }
  }
  let taskfile = locate_taskfile(explicit_taskfile)
  let raw_json = eval_taskfile(taskfile)
  let plan = parse_plan(raw_json)
  if json_flag {
    let visible = sorted_visible_tasks(plan, show_all)
    // Build the visible-name set for filtering deps/edges (mirrors Go's
    // `keep` map passed to filterGraphRefs / writeGraphJSON).
    let keep : Map[String, Bool] = Map([], capacity=visible.length())
    for t in visible {
      keep[t.name] = true
    }
    let tasks_arr : Array[Json] = []
    for t in visible {
      tasks_arr.push(task_to_json(t, true, Some(keep)))
    }
    let edges_arr : Array[Json] = []
    for t in visible {
      for dep in t.deps {
        if keep.get(dep) is Some(true) {
          let e : Map[String, Json] = Map([], capacity=2)
          e["from"] = Json::string(dep)
          e["to"] = Json::string(t.name)
          edges_arr.push(Json::object(e))
        }
      }
    }
    let root : Map[String, Json] = Map([], capacity=2)
    root["tasks"] = Json::array(tasks_arr)
    root["edges"] = Json::array(edges_arr)
    println(Json::object(root).stringify())
    return 0
  }
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
/// Skip paths that should never trigger a re-run: build output, VCS state,
/// dependency caches, OS metadata.
fn watch_exclude(path : String) -> Bool {
  path.contains("/_build/") ||
  path.contains("/_build") ||
  path.contains("/.git/") ||
  path.contains("/.git") ||
  path.contains("/node_modules/") ||
  path.contains("/node_modules") ||
  path.contains("/.cache/") ||
  path.contains("/target/") ||
  path.has_suffix("/.DS_Store") ||
  path.has_suffix("~")
}

///|
async fn[X] watch_cmd(
  explicit_taskfile : String?,
  group : @async.TaskGroup[X],
  args : ArrayView[String],
) -> Int {
  // `pkf watch [task...]` — optional task names scope the re-runs to a
  // subset of the plan. With no scope, every affected task runs.
  let scope_set : Map[String, Bool] = Map([], capacity=args.length())
  for a in args {
    if a.has_prefix("--") {
      die("pkf watch: unknown flag `\{a}`")
      return 2
    }
    scope_set[a] = true
  }
  let taskfile = locate_taskfile(explicit_taskfile)
  let raw_json = eval_taskfile(taskfile)
  let plan = parse_plan(raw_json)
  let repo_root = taskfile_dir(taskfile)
  println("pkf watch: monitoring `.` (Ctrl-C to stop)")
  let watcher = @fswatch.start([repo_root], exclude=watch_exclude)
  for ;; {
    let events = watcher.next()
    if events.length() == 0 {
      break // watcher closed
    }
    let seen : Map[String, Bool] = Map([], capacity=events.length())
    let changed : Array[String] = []
    for e in events {
      if !seen.contains(e.path) {
        seen[e.path] = true
        changed.push(e.path)
      }
    }
    let (_, affected) = compute_affected(plan, changed)
    let to_run : Array[String] = []
    for name in affected {
      if scope_set.is_empty() || scope_set.contains(name) {
        let t = plan.tasks.get(name)
        if t is Some(task) && !task.service {
          to_run.push(name)
        }
      }
    }
    if to_run.length() == 0 {
      continue
    }
    let summary = if changed.length() == 1 {
      "1 file changed"
    } else {
      "\{changed.length()} files changed"
    }
    println("pkf watch: \{summary}; running \{to_run.length()} task(s)")
    for name in to_run {
      let task = plan.tasks.get(name).unwrap()
      let resolved_params = match
        resolve_task_params(task, Map([], capacity=0)) {
        Some(m) => m
        None => continue
      }
      let code = run_task(group, plan, task, repo_root, resolved_params, [])
      if code != 0 {
        println(
          "pkf watch: task `\{name}` failed with exit code \{code}; continuing",
        )
      }
    }
  }
  0
}

///|
/// FFI: install custom SIGINT/SIGTERM handler that flips a sig_atomic_t
/// flag. Used only by `pkf up` — we don't want moonbitlang/async's
/// global signal handling for other subcommands (it terminates the whole
/// runtime, which is what `pkf run` wants).
extern "C" fn pkf_signal_install_ffi() -> Int = "mizchi_pkf_signal_install"

///|
extern "C" fn pkf_signal_check_ffi() -> Int = "mizchi_pkf_signal_check"

///|
async fn[X] up_cmd(
  explicit_taskfile : String?,
  group : @async.TaskGroup[X],
  args : ArrayView[String],
) -> Int {
  // `pkf up [service...]` — bring up service tasks (or just the named
  // subset) in the foreground, poll a SIGINT flag, tear them down on
  // Ctrl-C.
  let scope_set : Map[String, Bool] = Map([], capacity=args.length())
  for a in args {
    if a.has_prefix("--") {
      die("pkf up: unknown flag `\{a}`")
      return 2
    }
    scope_set[a] = true
  }
  let taskfile = locate_taskfile(explicit_taskfile)
  let raw_json = eval_taskfile(taskfile)
  let plan = parse_plan(raw_json)
  // Pick service tasks in authored order so dependents start after their
  // backends (matches Apple pkfire's reuse semantics).
  let services_to_start : Array[String] = []
  for name in plan.task_order {
    let task = match plan.tasks.get(name) {
      Some(t) => t
      None => continue
    }
    if !task.service {
      continue
    }
    if scope_set.is_empty() || scope_set.contains(name) {
      services_to_start.push(name)
    }
  }
  if services_to_start.length() == 0 {
    if scope_set.is_empty() {
      println("pkf up: no `service = true` tasks declared")
    } else {
      println("pkf up: none of the named tasks are services")
    }
    return 0
  }
  // Install the signal handler *before* starting any service so a very
  // fast Ctrl-C still hits our handler and not the runtime default.
  if pkf_signal_install_ffi() != 0 {
    println("pkf up: warning — could not install SIGINT/SIGTERM handler")
  }
  let running : Array[RunningService] = []
  for name in services_to_start {
    let task = plan.tasks.get(name).unwrap()
    let resolved_params = match
      resolve_task_params(task, Map([], capacity=0)) {
      Some(m) => m
      None => {
        println("pkf up: skipping `\{name}` — param resolution failed")
        continue
      }
    }
    let svc = try start_service(group, plan, task, resolved_params) catch {
      err => {
        println("pkf up: failed to start `\{name}`: \{err}")
        // Tear down whatever did start before bailing.
        stop_services(running)
        return 1
      }
    }
    running.push(svc)
  }
  println("pkf up: \{running.length()} service(s) up. Ctrl-C to stop.")
  // Poll the SIGINT flag. 250 ms cadence keeps Ctrl-C latency well
  // below human-perceived "responsiveness" while burning ~no CPU.
  for ;; {
    if pkf_signal_check_ffi() != 0 {
      break
    }
    @async.sleep(250)
  }
  println("\npkf up: signal received, shutting down...")
  stop_services(running)
  0
}

///|
/// Scan the Taskfile source for the `amends "<URI>"` line.
/// Returns (amends_uri, schema_version) — both may be None.
/// The schema_version is extracted from the `pkfire@<version>` token
/// in the URI (just the version string, e.g. "0.10.0").
fn scan_amends_and_schema(taskfile_path : String) -> (String?, String?) {
  let src = @fs.read_file_to_string(taskfile_path) catch {
    _ => return (None, None)
  }
  let mut amends : String? = None
  for line_view in src.split("\n") {
    let line = line_view.to_string().trim_space().to_string()
    if line.has_prefix("amends ") {
      // Find the first `"` in the line.
      let mut start = -1
      for i in 0..<line.length() {
        if line[i] == '"' {
          start = i
          break
        }
      }
      if start >= 0 {
        // Find the closing `"` after position start.
        // Use a while loop since MoonBit range literals require constants.
        let mut j = start + 1
        let mut end = -1
        while j < line.length() {
          if line[j] == '"' {
            end = j
            break
          }
          j = j + 1
        }
        if end > start {
          amends = Some(line.substring(start=start + 1, end=end))
        }
      }
      break
    }
  }
  let schema : String? = match amends {
    Some(uri) => {
      // Look for `pkfire@` in the URI and extract up to the next `#` or `"`.
      match uri.find("pkfire@") {
        Some(idx) => {
          let after = uri.substring(start=idx + 7, end=uri.length())
          // End at `#` or end of string.
          let mut end = after.length()
          for i in 0..<after.length() {
            if after[i] == '#' || after[i] == '"' {
              end = i
              break
            }
          }
          if end > 0 {
            Some(after.substring(start=0, end=end))
          } else {
            None
          }
        }
        None => None
      }
    }
    None => None
  }
  (amends, schema)
}

///|
async fn info_cmd(explicit_taskfile : String?, args : ArrayView[String]) -> Int {
  let mut json_flag = false
  let mut all_flag = false
  for arg in args {
    match arg {
      "--json" => json_flag = true
      "--all" => all_flag = true
      _ => {
        if arg.has_prefix("--") {
          die("pkf info: unknown flag `\{arg}`")
          return 2
        } else {
          die("info takes no positional args, got `\{arg}`")
          return 2
        }
      }
    }
  }
  let taskfile = locate_taskfile(explicit_taskfile)
  let raw_json = eval_taskfile(taskfile)
  let plan = parse_plan(raw_json)
  let (amends, schema) = scan_amends_and_schema(taskfile)
  if json_flag {
    let root : Map[String, Json] = Map([], capacity=8)
    root["taskfile"] = Json::string(taskfile)
    match schema {
      Some(v) => root["schemaVersion"] = Json::string(v)
      None => ()
    }
    match amends {
      Some(a) => root["amends"] = Json::string(a)
      None => ()
    }
    // defaults: always emit since the schema defines bash/-c as defaults
    // and parse_plan always carries shell/shellFlags.
    let defaults_o : Map[String, Json] = Map([], capacity=3)
    defaults_o["shell"] = Json::string(plan.default_shell)
    defaults_o["shellFlags"] = jstr_array(plan.default_shell_flags)
    if plan.default_env.length() > 0 {
      let env_o : Map[String, Json] = Map([], capacity=plan.default_env.length())
      for k, v in plan.default_env {
        env_o[k] = Json::string(v)
      }
      defaults_o["env"] = Json::object(env_o)
    }
    root["defaults"] = Json::object(defaults_o)
    let tasks_arr : Array[Json] = []
    for t in sorted_visible_tasks(plan, all_flag) {
      tasks_arr.push(task_to_json(t, false, None))
    }
    root["tasks"] = Json::array(tasks_arr)
    if plan.workflow_tests.length() > 0 {
      let wt_arr : Array[Json] = []
      for wt in plan.workflow_tests {
        let wt_o : Map[String, Json] = Map([], capacity=4)
        wt_o["name"] = Json::string(wt.name)
        if wt.changed.length() > 0 {
          wt_o["changed"] = jstr_array(wt.changed)
        }
        if wt.tasks.length() > 0 {
          wt_o["tasks"] = jstr_array(wt.tasks)
        }
        if wt.direct.length() > 0 {
          wt_o["direct"] = jstr_array(wt.direct)
        }
        wt_arr.push(Json::object(wt_o))
      }
      root["workflowTests"] = Json::array(wt_arr)
    }
    println(Json::object(root).stringify())
    return 0
  }
  // Plain text summary.
  println("taskfile:      " + taskfile)
  match schema {
    Some(v) => println("schemaVersion: pkfire@" + v)
    None =>
      match amends {
        Some(a) => println("amends:        " + a)
        None => ()
      }
  }
  println("defaults:      shell=" + plan.default_shell + " flags=" + join_list(plan.default_shell_flags))
  let visible = sorted_visible_tasks(plan, all_flag)
  println("tasks:         " + visible.length().to_string())
  if plan.workflow_tests.length() > 0 {
    println("workflowTests: " + plan.workflow_tests.length().to_string())
  }
  0
}

///|
fn completion_bash() -> String {
  #|# pkf bash completion.
  #|# Source this file, or save into /usr/local/etc/bash_completion.d/.
  #|# Suggested install:  pkf completion bash > ~/.bash_completion.d/pkf
  #|#
  #|# Dynamic task-name completion calls back to `pkf list` (without -v
  #|# so the output is one name per line, prefix-trimmable).
  #|
  #|_pkf() {
  #|  local cur prev
  #|  COMPREPLY=()
  #|  cur="${COMP_WORDS[COMP_CWORD]}"
  #|  prev="${COMP_WORDS[COMP_CWORD-1]}"
  #|
  #|  # First positional = subcommand.
  #|  if [ "$COMP_CWORD" -eq 1 ]; then
  #|    COMPREPLY=($(compgen -W "init list describe info run up doctor lint format hooks affected clean cache completion graph explain migrate pkl-cache version help" -- "$cur"))
  #|    return
  #|  fi
  #|
  #|  local sub="${COMP_WORDS[1]}"
  #|  case "$sub" in
  #|    list)
  #|      if [[ "$prev" == "--color" ]]; then
  #|        COMPREPLY=($(compgen -W "auto always never" -- "$cur"))
  #|      elif [[ "$cur" == -* ]]; then
  #|        COMPREPLY=($(compgen -W "-f --file -v --verbose --long --json --all --unsorted --source-order --color" -- "$cur"))
  #|      fi
  #|      ;;
  #|    lint)
  #|      if [[ "$cur" == -* ]]; then
  #|        COMPREPLY=($(compgen -W "-f --file --json --fix --dry-run" -- "$cur"))
  #|      fi
  #|      ;;
  #|    doctor)
  #|      if [[ "$cur" == -* ]]; then
  #|        COMPREPLY=($(compgen -W "-f --file --json --fix --dry-run" -- "$cur"))
  #|      fi
  #|      ;;
  #|    affected)
  #|      if [[ "$cur" == -* ]]; then
  #|        COMPREPLY=($(compgen -W "-f --file --since --files --explain --check --dry-run --no-cache --refresh --timing --quiet --keep-going --profile --watch -j --jobs" -- "$cur"))
  #|        return
  #|      fi
  #|      local tasks
  #|      tasks=$(pkf list 2>/dev/null | awk '{print $1}')
  #|      COMPREPLY=($(compgen -W "$tasks" -- "$cur"))
  #|      ;;
  #|    run)
  #|      if [[ "$cur" == -* ]]; then
  #|        COMPREPLY=($(compgen -W "-f --file --watch --dry-run --print-hash --explain-cache --no-cache --refresh --timing --quiet --keep-going --profile --on-fail --remote-only -j --jobs" -- "$cur"))
  #|        return
  #|      fi
  #|      local tasks
  #|      tasks=$(pkf list 2>/dev/null | awk '{print $1}')
  #|      COMPREPLY=($(compgen -W "$tasks" -- "$cur"))
  #|      ;;
  #|    clean|up)
  #|      if [[ "$cur" == -* ]]; then return; fi
  #|      local tasks
  #|      tasks=$(pkf list 2>/dev/null | awk '{print $1}')
  #|      COMPREPLY=($(compgen -W "$tasks" -- "$cur"))
  #|      ;;
  #|    describe)
  #|      if [[ "$cur" == -* ]]; then
  #|        COMPREPLY=($(compgen -W "-f --file --json" -- "$cur"))
  #|        return
  #|      fi
  #|      local tasks
  #|      tasks=$(pkf list --all 2>/dev/null | awk '{print $1}')
  #|      COMPREPLY=($(compgen -W "$tasks" -- "$cur"))
  #|      ;;
  #|    info)
  #|      if [[ "$cur" == -* ]]; then
  #|        COMPREPLY=($(compgen -W "-f --file --json --all" -- "$cur"))
  #|      fi
  #|      ;;
  #|    hooks)
  #|      if [ "$COMP_CWORD" -eq 2 ]; then
  #|        COMPREPLY=($(compgen -W "install uninstall list" -- "$cur"))
  #|      fi
  #|      ;;
  #|    cache)
  #|      if [ "$COMP_CWORD" -eq 2 ]; then
  #|        COMPREPLY=($(compgen -W "stats prune rm clear" -- "$cur"))
  #|      fi
  #|      ;;
  #|    completion)
  #|      if [ "$COMP_CWORD" -eq 2 ]; then
  #|        COMPREPLY=($(compgen -W "bash zsh fish" -- "$cur"))
  #|      fi
  #|      ;;
  #|    graph)
  #|      if [[ "$prev" == "--format" ]]; then
  #|        COMPREPLY=($(compgen -W "dot mermaid tree json" -- "$cur"))
  #|      elif [[ "$cur" == -* ]]; then
  #|        COMPREPLY=($(compgen -W "-f --file --format --json --target --all --unsorted --source-order --depth" -- "$cur"))
  #|      fi
  #|      ;;
  #|    explain)
  #|      if [[ "$cur" == -* ]]; then
  #|        COMPREPLY=($(compgen -W "-f --file --diff" -- "$cur"))
  #|        return
  #|      fi
  #|      local tasks
  #|      tasks=$(pkf list 2>/dev/null | awk '{print $1}')
  #|      COMPREPLY=($(compgen -W "$tasks" -- "$cur"))
  #|      ;;
  #|    migrate)
  #|      if [[ "$cur" == -* ]]; then
  #|        COMPREPLY=($(compgen -W "-f --file --to --dry-run --skip-verify" -- "$cur"))
  #|      fi
  #|      ;;
  #|    pkl-cache)
  #|      if [ "$COMP_CWORD" -eq 2 ]; then
  #|        COMPREPLY=($(compgen -W "warm" -- "$cur"))
  #|      elif [[ "$cur" == -* ]]; then
  #|        COMPREPLY=($(compgen -W "-f --file" -- "$cur"))
  #|      fi
  #|      ;;
  #|  esac
  #|}
  #|complete -F _pkf pkf
}

///|
fn completion_zsh() -> String {
  #|#compdef pkf
  #|# pkf zsh completion.
  #|# Suggested install:  pkf completion zsh > "${fpath[1]}/_pkf"
  #|# then `compinit` (re-source ~/.zshrc).
  #|
  #|_pkf() {
  #|  local -a subcommands
  #|  subcommands=(
  #|    'init:write a starter Taskfile.pkl'
  #|    'list:list declared tasks'
  #|    'describe:show a single task'\''s desc / params / inputs / outputs / cache / deps'
  #|    'info:structured snapshot (schema version + defaults + tasks + workflowTests)'
  #|    'run:run one or more tasks'
  #|    'up:supervise long-running services'
  #|    'doctor:diagnose pkfire setup'
  #|    'lint:detect Taskfile issues'
  #|    'format:pkl format -w wrapper'
  #|    'hooks:manage .git/hooks shims'
  #|    'affected:run tasks whose inputs changed since <ref>'
  #|    'clean:remove declared outputs'
  #|    'cache:inspect / clean the local CAS'
  #|    'completion:emit shell completion script'
  #|    'graph:emit DAG (dot / mermaid / tree / json)'
  #|    'explain:dump or compare inputs to the action key'
  #|    'migrate:rewrite Taskfile schema version'
  #|    'pkl-cache:warm the local Pkl package cache'
  #|    'version:print pkf version'
  #|    'help:show usage'
  #|  )
  #|
  #|  if (( CURRENT == 2 )); then
  #|    _describe 'subcommand' subcommands
  #|    return
  #|  fi
  #|
  #|  case "${words[2]}" in
  #|    list)
  #|      if [[ "${words[$((CURRENT-1))]}" == "--color" ]]; then
  #|        _values 'color' auto always never
  #|      elif [[ "${words[$CURRENT]}" == -* ]]; then
  #|        _values 'list option' \
  #|          '-f[path to Taskfile.pkl]' \
  #|          '--file[path to Taskfile.pkl]' \
  #|          '-v[show cmd preview and deps]' \
  #|          '--verbose[show cmd preview and deps]' \
  #|          '--long[show compact audit table]' \
  #|          '--json[emit machine-readable output]' \
  #|          '--all[include internal tasks]' \
  #|          '--unsorted[use declaration order]' \
  #|          '--source-order[use declaration order]' \
  #|          '--color[when to color output]'
  #|      fi
  #|      ;;
  #|    lint)
  #|      if [[ "${words[$CURRENT]}" == -* ]]; then
  #|        _values 'lint option' \
  #|          '-f[path to Taskfile.pkl]' \
  #|          '--file[path to Taskfile.pkl]' \
  #|          '--json[emit machine-readable output]' \
  #|          '--fix[apply safe fixes]' \
  #|          '--dry-run[show fixes without writing files]'
  #|      fi
  #|      ;;
  #|    doctor)
  #|      if [[ "${words[$CURRENT]}" == -* ]]; then
  #|        _values 'doctor option' \
  #|          '-f[path to Taskfile.pkl]' \
  #|          '--file[path to Taskfile.pkl]' \
  #|          '--json[emit machine-readable output]' \
  #|          '--fix[apply safe fixes]' \
  #|          '--dry-run[show fixes without writing files]'
  #|      fi
  #|      ;;
  #|    affected)
  #|      if [[ "${words[$CURRENT]}" == -* ]]; then
  #|        _values 'affected option' \
  #|          '-f[path to Taskfile.pkl]' \
  #|          '--file[path to Taskfile.pkl]' \
  #|          '--since[git ref to diff against]' \
  #|          '--files[simulate changed file paths]' \
  #|          '--explain[show matching input patterns]' \
  #|          '--check[run workflowTests]' \
  #|          '--dry-run[preview plan without running]' \
  #|          '--no-cache[disable cache for this run]' \
  #|          '--refresh[skip lookup but store outputs]' \
  #|          '--timing[print task durations]' \
  #|          '--quiet[suppress per-task log lines]' \
  #|          '--keep-going[do not stop on first failure]' \
  #|          '--profile[profile name for cache keys]' \
  #|          '--watch[recompute affected set on change]' \
  #|          '-j[max concurrent tasks]' \
  #|          '--jobs[max concurrent tasks]'
  #|      else
  #|        local -a tasks
  #|        tasks=(${(f)"$(pkf list 2>/dev/null | awk '{print $1}')"})
  #|        _describe 'task' tasks
  #|      fi
  #|      ;;
  #|    run)
  #|      if [[ "${words[$CURRENT]}" == -* ]]; then
  #|        _values 'run option' \
  #|          '-f[path to Taskfile.pkl]' \
  #|          '--file[path to Taskfile.pkl]' \
  #|          '--watch[re-run on input changes]' \
  #|          '--dry-run[preview plan without running]' \
  #|          '--print-hash[print action keys and exit]' \
  #|          '--explain-cache[explain cache decisions and exit]' \
  #|          '--no-cache[disable cache for this run]' \
  #|          '--refresh[skip lookup but store outputs]' \
  #|          '--timing[print task durations]' \
  #|          '--quiet[suppress per-task log lines]' \
  #|          '--keep-going[do not stop on first failure]' \
  #|          '--profile[profile name for cache keys]' \
  #|          '--on-fail[action on task failure]' \
  #|          '--remote-only[consult only remote cache]' \
  #|          '-j[max concurrent tasks]' \
  #|          '--jobs[max concurrent tasks]'
  #|      else
  #|        local -a tasks
  #|        tasks=(${(f)"$(pkf list 2>/dev/null | awk '{print $1}')"})
  #|        _describe 'task' tasks
  #|      fi
  #|      ;;
  #|    clean|up)
  #|      local -a tasks
  #|      tasks=(${(f)"$(pkf list 2>/dev/null | awk '{print $1}')"})
  #|      _describe 'task' tasks
  #|      ;;
  #|    describe)
  #|      if [[ "${words[$CURRENT]}" == -* ]]; then
  #|        _values 'describe option' \
  #|          '-f[path to Taskfile.pkl]' \
  #|          '--file[path to Taskfile.pkl]' \
  #|          '--json[emit machine-readable output]'
  #|      else
  #|        local -a tasks
  #|        tasks=(${(f)"$(pkf list --all 2>/dev/null | awk '{print $1}')"})
  #|        _describe 'task' tasks
  #|      fi
  #|      ;;
  #|    info)
  #|      if [[ "${words[$CURRENT]}" == -* ]]; then
  #|        _values 'info option' \
  #|          '-f[path to Taskfile.pkl]' \
  #|          '--file[path to Taskfile.pkl]' \
  #|          '--json[emit machine-readable output]' \
  #|          '--all[include internal tasks]'
  #|      fi
  #|      ;;
  #|    hooks)
  #|      if (( CURRENT == 3 )); then
  #|        _values 'hooks subcommand' install uninstall list
  #|      fi
  #|      ;;
  #|    cache)
  #|      if (( CURRENT == 3 )); then
  #|        _values 'cache subcommand' stats prune rm clear
  #|      fi
  #|      ;;
  #|    completion)
  #|      if (( CURRENT == 3 )); then
  #|        _values 'shell' bash zsh fish
  #|      fi
  #|      ;;
  #|    graph)
  #|      if [[ "${words[$((CURRENT-1))]}" == "--format" ]]; then
  #|        _values 'format' dot mermaid tree json
  #|      elif [[ "${words[$CURRENT]}" == -* ]]; then
  #|        _values 'graph option' \
  #|          '-f[path to Taskfile.pkl]' \
  #|          '--file[path to Taskfile.pkl]' \
  #|          '--format[output format]' \
  #|          '--json[emit machine-readable output]' \
  #|          '--target[render only one task subgraph]' \
  #|          '--all[include internal tasks]' \
  #|          '--unsorted[use declaration order]' \
  #|          '--source-order[use declaration order]' \
  #|          '--depth[limit dependency traversal]'
  #|      fi
  #|      ;;
  #|    explain)
  #|      if [[ "${words[$CURRENT]}" == -* ]]; then
  #|        _values 'explain option' \
  #|          '-f[path to Taskfile.pkl]' \
  #|          '--file[path to Taskfile.pkl]' \
  #|          '--diff[compare against another Taskfile.pkl]'
  #|      else
  #|        local -a tasks
  #|        tasks=(${(f)"$(pkf list 2>/dev/null | awk '{print $1}')"})
  #|        _describe 'task' tasks
  #|      fi
  #|      ;;
  #|    migrate)
  #|      if [[ "${words[$CURRENT]}" == -* ]]; then
  #|        _values 'migrate option' \
  #|          '-f[path to Taskfile.pkl]' \
  #|          '--file[path to Taskfile.pkl]' \
  #|          '--to[target schema version]' \
  #|          '--dry-run[preview rewrite without writing]' \
  #|          '--skip-verify[skip post-migration pkl eval]'
  #|      fi
  #|      ;;
  #|    pkl-cache)
  #|      if (( CURRENT == 3 )); then
  #|        _values 'pkl-cache subcommand' warm
  #|      elif [[ "${words[$CURRENT]}" == -* ]]; then
  #|        _values 'pkl-cache option' \
  #|          '-f[path to Taskfile.pkl]' \
  #|          '--file[path to Taskfile.pkl]'
  #|      fi
  #|      ;;
  #|  esac
  #|}
  #|
  #|_pkf "$@"
}

///|
fn completion_fish() -> String {
  #|# pkf fish completion.
  #|# Suggested install:  pkf completion fish > ~/.config/fish/completions/pkf.fish
  #|
  #|function __pkf_tasks
  #|    pkf list 2>/dev/null | awk '{print $1}'
  #|end
  #|
  #|# Subcommands when no subcommand has been picked yet.
  #|complete -c pkf -f -n '__fish_use_subcommand' -a init      -d 'write a starter Taskfile.pkl'
  #|complete -c pkf -f -n '__fish_use_subcommand' -a list      -d 'list declared tasks'
  #|complete -c pkf -f -n '__fish_use_subcommand' -a describe  -d 'show a single task surface'
  #|complete -c pkf -f -n '__fish_use_subcommand' -a info      -d 'structured snapshot of the Taskfile'
  #|complete -c pkf -f -n '__fish_use_subcommand' -a run       -d 'run one or more tasks'
  #|complete -c pkf -f -n '__fish_use_subcommand' -a up        -d 'supervise long-running services'
  #|complete -c pkf -f -n '__fish_use_subcommand' -a doctor    -d 'diagnose pkfire setup'
  #|complete -c pkf -f -n '__fish_use_subcommand' -a lint      -d 'detect Taskfile issues'
  #|complete -c pkf -f -n '__fish_use_subcommand' -a format    -d 'pkl format -w wrapper'
  #|complete -c pkf -f -n '__fish_use_subcommand' -a hooks     -d 'manage .git/hooks shims'
  #|complete -c pkf -f -n '__fish_use_subcommand' -a affected  -d 'run tasks whose inputs changed since <ref>'
  #|complete -c pkf -f -n '__fish_use_subcommand' -a clean     -d 'remove declared outputs'
  #|complete -c pkf -f -n '__fish_use_subcommand' -a cache     -d 'inspect / clean the local CAS'
  #|complete -c pkf -f -n '__fish_use_subcommand' -a completion -d 'emit shell completion script'
  #|complete -c pkf -f -n '__fish_use_subcommand' -a graph     -d 'emit DAG (dot / mermaid / tree / json)'
  #|complete -c pkf -f -n '__fish_use_subcommand' -a explain   -d 'dump or compare inputs to the action key'
  #|complete -c pkf -f -n '__fish_use_subcommand' -a migrate   -d 'rewrite Taskfile schema version'
  #|complete -c pkf -f -n '__fish_use_subcommand' -a pkl-cache -d 'warm the local Pkl package cache'
  #|complete -c pkf -f -n '__fish_use_subcommand' -a version   -d 'print pkf version'
  #|complete -c pkf -f -n '__fish_use_subcommand' -a help      -d 'show usage'
  #|
  #|# Dynamic task names for the subcommands that take them.
  #|complete -c pkf -f -n '__fish_seen_subcommand_from run affected clean up explain describe' -a '(__pkf_tasks)'
  #|
  #|# Nested subcommand completions.
  #|complete -c pkf -f -n '__fish_seen_subcommand_from hooks' -a 'install uninstall list'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from cache' -a 'stats prune rm clear'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from completion' -a 'bash zsh fish'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from list' -l color -a 'auto always never'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from list' -s v -l verbose -d 'show cmd preview and deps'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from list' -l long -d 'show compact audit table'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from list' -l json -d 'emit machine-readable output'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from list' -l all -d 'include internal tasks'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from list' -l unsorted -d 'use declaration order'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from list' -l source-order -d 'use declaration order'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from lint' -l json -d 'emit machine-readable output'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from lint' -l fix -d 'apply safe fixes'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from lint' -l dry-run -d 'show fixes without writing files'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from doctor' -l json -d 'emit machine-readable output'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from doctor' -l fix -d 'apply safe fixes'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from doctor' -l dry-run -d 'show fixes without writing files'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from affected' -l since -d 'git ref to diff against'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from affected' -l files -d 'simulate changed file paths'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from affected' -l explain -d 'show matching input patterns'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from affected' -l check -d 'run workflowTests'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from affected' -l dry-run -d 'preview plan without running'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from affected' -l no-cache -d 'disable cache for this run'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from affected' -l refresh -d 'skip lookup but store outputs'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from affected' -l timing -d 'print task durations'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from affected' -l quiet -d 'suppress per-task log lines'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from affected' -l keep-going -d 'do not stop on first failure'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from affected' -l profile -d 'profile name for cache keys'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from affected' -l watch -d 'recompute affected set on change'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from affected' -s j -l jobs -d 'max concurrent tasks'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from run' -l watch -d 're-run on input changes'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from run' -l dry-run -d 'preview plan without running'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from run' -l print-hash -d 'print action keys and exit'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from run' -l explain-cache -d 'explain cache decisions and exit'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from run' -l no-cache -d 'disable cache for this run'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from run' -l refresh -d 'skip lookup but store outputs'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from run' -l timing -d 'print task durations'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from run' -l quiet -d 'suppress per-task log lines'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from run' -l keep-going -d 'do not stop on first failure'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from run' -l profile -d 'profile name for cache keys'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from run' -l on-fail -d 'action on task failure'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from run' -l remote-only -d 'consult only remote cache'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from run' -s j -l jobs -d 'max concurrent tasks'
  #|
  #|# `pkf graph --format <TAB>`.
  #|complete -c pkf -f -n '__fish_seen_subcommand_from graph' -l format -a 'dot mermaid tree json'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from graph' -l json -d 'emit machine-readable output'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from graph' -l target -d 'render only one task subgraph'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from graph' -l all -d 'include internal tasks'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from graph' -l unsorted -d 'use declaration order'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from graph' -l source-order -d 'use declaration order'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from graph' -l depth -d 'limit dependency traversal'
  #|
  #|complete -c pkf -f -n '__fish_seen_subcommand_from explain' -s f -l file -d 'path to Taskfile.pkl'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from explain' -l diff -d 'compare against another Taskfile.pkl'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from describe' -s f -l file -d 'path to Taskfile.pkl'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from describe' -l json -d 'emit machine-readable output'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from info' -s f -l file -d 'path to Taskfile.pkl'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from info' -l json -d 'emit machine-readable output'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from info' -l all -d 'include internal tasks'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from migrate' -s f -l file -d 'path to Taskfile.pkl'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from migrate' -l to -d 'target schema version'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from migrate' -l dry-run -d 'preview rewrite without writing'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from migrate' -l skip-verify -d 'skip post-migration pkl eval'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from pkl-cache' -a warm -d 'pre-evaluate Pkl files'
  #|complete -c pkf -f -n '__fish_seen_subcommand_from pkl-cache' -s f -l file -d 'path to Taskfile.pkl'
}


///|
fn usage_text() -> String {
  let msg =
    #|usage: pkf <command> [args...]
    #|
    #|commands:
    #|  run <task> [--name=value]... [-- positional...]
    #|  list [-v] [--all]
    #|  graph [--all]
    #|  affected <path>... | --check
    #|  watch [task...]
    #|  up [service...]
    #|  info [--json] [--all]
    #|  completion <bash|zsh|fish>
  msg
}

///|
// Consume leading -f/--file/--file= flags (the flag region, before the
// first positional). Stops at the first non-flag token; tokens that are
// other flags are kept in the remaining slice. Mirrors Go's flag.Parse.
fn extract_file_flag(args : ArrayView[String]) -> (String?, Array[String]) {
  let remaining : Array[String] = []
  let mut explicit : String? = None
  let mut i = 0
  let mut seen_positional = false
  while i < args.length() {
    let a = args[i]
    if !seen_positional && (a == "-f" || a == "--file") {
      if i + 1 < args.length() {
        explicit = Some(args[i + 1])
        i = i + 2
      } else {
        die("flag \{a} needs a value")
        panic()
      }
      continue
    }
    if !seen_positional && a.has_prefix("--file=") {
      explicit = Some(a.substring(start=7, end=a.length()))
      i = i + 1
      continue
    }
    if !a.has_prefix("-") {
      seen_positional = true
    }
    remaining.push(a)
    i = i + 1
  }
  (explicit, remaining)
}

///|
async fn[X] run_main(group : @async.TaskGroup[X], args : Array[String]) -> Int {
  if args.length() < 1 {
    println(usage_text())
    return 0
  }
  // Dispatch directly on args[0]. Each subcommand extracts -f/--file from
  // its own leading flag region (Go flag semantics: flags before first
  // positional). A -f/--file at argv[0] means the subcommand name is the
  // flag value, which is unknown → fall through to unknown-subcommand.
  match args[0] {
    "help" | "--help" | "-h" => {
      println(usage_text())
      0
    }
    "list" => {
      let (explicit_taskfile, rest) = extract_file_flag(args[1:])
      list_cmd(explicit_taskfile, rest[:])
    }
    "graph" => {
      let (explicit_taskfile, rest) = extract_file_flag(args[1:])
      graph_cmd(explicit_taskfile, rest[:])
    }
    "affected" => {
      let (explicit_taskfile, rest) = extract_file_flag(args[1:])
      affected_cmd(explicit_taskfile, rest[:])
    }
    "watch" => {
      let (explicit_taskfile, rest) = extract_file_flag(args[1:])
      watch_cmd(explicit_taskfile, group, rest[:])
    }
    "up" => {
      let (explicit_taskfile, rest) = extract_file_flag(args[1:])
      up_cmd(explicit_taskfile, group, rest[:])
    }
    "run" => {
      let (explicit_taskfile, rest) = extract_file_flag(args[1:])
      let parsed = parse_run_args(rest[:])
      if parsed.target.length() == 0 {
        die("pkf run: missing <task> argument")
      }
      let target = parsed.target
      let taskfile = locate_taskfile(explicit_taskfile)
      let raw_json = eval_taskfile(taskfile)
      let plan = parse_plan(raw_json)
      match plan.tasks.get(target) {
        Some(t) =>
          if t.service {
            die(
              "task `\{target}` is a `service` (start it with `pkf up`, not `pkf run`)",
            )
            return 2
          }
        None => {
          suggest_task_name(target, plan)
          return 2
        }
      }
      let order = topo_sort_for(target, plan)
      let repo_root = taskfile_dir(taskfile)
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
    "describe" => {
      let (explicit_taskfile, rest) = extract_file_flag(args[1:])
      // Detect --json flag; stop flag parsing at the first positional
      // (mirrors Go's flag.Parse: flags-before-positionals only).
      let mut json_flag = false
      let task_names : Array[String] = []
      let mut seen_positional = false
      for a in rest {
        if seen_positional {
          // Everything after the first positional is a positional, even if
          // it looks like a flag — matching Go's flag.Parse stop-at-first-
          // positional semantics.
          task_names.push(a)
        } else if a == "--json" {
          json_flag = true
        } else if a.has_prefix("--") {
          die("pkf describe: unknown flag `\{a}`")
          return 2
        } else {
          seen_positional = true
          task_names.push(a)
        }
      }
      if task_names.length() == 0 {
        die("usage: pkf describe [-f FILE] [--json] <task>")
        return 2
      }
      if task_names.length() > 1 {
        die("describe takes a single task name, got \{join_list(task_names)}")
        return 2
      }
      let task_name = task_names[0]
      let taskfile = locate_taskfile(explicit_taskfile)
      let raw_json = eval_taskfile(taskfile)
      let plan = parse_plan(raw_json)
      let task = match plan.tasks.get(task_name) {
        Some(t) => t
        None => {
          die("unknown task: \"\{task_name}\" (try `pkf list --all`)")
          return 2
        }
      }
      if json_flag {
        println(describe_to_json(task).stringify())
      } else {
        // Plain text: readable multi-line summary.
        println("task: " + task.name)
        match task.description {
          Some(d) => println("  description: " + d)
          None => ()
        }
        println("  visibility: " + task.visibility)
        println("  cache: " + task.cache.to_string())
        println("  cmd: " + task.cmd)
        if task.inputs.length() > 0 {
          println("  inputs: " + join_list(task.inputs))
        }
        if task.outputs.length() > 0 {
          println("  outputs: " + join_list(task.outputs))
        }
        if task.deps.length() > 0 {
          println("  deps: " + join_list(task.deps))
        }
        if task.params.length() > 0 {
          println("  params:")
          for p in task.params {
            let default = match p.default {
              Some(d) => " (default: " + d + ")"
              None => ""
            }
            println("    --" + p.name + " : " + p.ptype + default)
          }
        }
      }
      0
    }
    "info" => {
      let (explicit_taskfile, rest) = extract_file_flag(args[1:])
      info_cmd(explicit_taskfile, rest[:])
    }
    "version" | "--version" | "-v" => {
      println(pkf_version())
      0
    }
    "completion" => {
      if args.length() < 2 {
        die("usage: pkf completion <bash|zsh|fish>")
        return 1
      }
      match args[1] {
        "bash" => println(completion_bash())
        "zsh" => println(completion_zsh())
        "fish" => println(completion_fish())
        _ => {
          die("usage: pkf completion <bash|zsh|fish>")
          return 1
        }
      }
      0
    }
    other => {
      eprintln("pkf: unknown subcommand `\{other}`")
      eprintln(usage_text())
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
