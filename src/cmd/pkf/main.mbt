// pkf — MoonBit re-implementation of pkfire.
//
// `pkf run <task>` flow:
//   1. Locate Taskfile.pkl (`./Taskfile.pkl` by default).
//   2. Evaluate it fully in-process via the embedded Pkl loader
//      (`@loader.eval_module_path`) — no subprocess. The loader resolves
//      local, cached, remote `package://`, `http(s)://` and glob-import
//      modules itself, then renders the module's `output.value` as the
//      same JSON envelope (taskOrder + tasks Mapping) Apple Pkl produces.
//   3. Parse the Rendered JSON envelope (taskOrder + tasks Mapping).
//   4. Topo-sort tasks via their `deps` list.
//   5. For each task, spawn `<shell> <shellFlags> <cmd>` with merged env.
//   6. Stream stdout/stderr through, return the first non-zero exit.
//
// The embedded loader is the sole Taskfile evaluator; there is no longer
// a fallback to an external eval subprocess. (The Apple `pkl` CLI is still
// invoked for the `format`/`pkl` passthrough subcommands.)

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
      die("could not parse Taskfile eval JSON output")
      panic()
    }
  }
  let entries = match root {
    Object(e) => e
    _ => {
      die("Taskfile eval JSON output is not an object")
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
        path[0:idx].to_owned()
      }
    None => ""
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
/// FFI: stat(2) → st_mtime as seconds since epoch, or 0 on failure.
#borrow(path)
extern "C" fn file_mtime_sec(path : Bytes) -> Int64 = "mizchi_pkf_mtime_sec"

///|
/// FFI: stat(2) → st_size as bytes, or -1 on failure.
#borrow(path)
extern "C" fn file_size_bytes(path : Bytes) -> Int64 = "mizchi_pkf_file_size"

///|
/// FFI: time(2) → current wall-clock time as seconds since epoch.
extern "C" fn now_sec() -> Int64 = "mizchi_pkf_now_sec"

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
  p : Array[StringView],
  pi : Int,
  s : Array[StringView],
  si : Int,
) -> Bool {
  let mut pi = pi
  let mut si = si
  for ;; {
    if pi >= p.length() {
      return si >= s.length()
    }
    let seg = p[pi].to_owned()
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
    if !glob_segment_matches(seg, s[si].to_owned()) {
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
  for ;; {
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
// pkf's cache uses a different hash family (SHA-256) and a different
// on-disk layout from go pkfire's BLAKE3 + tar.zst, so the two cannot
// share local cache. The action-key *string* still mirrors go pkfire's
// canonical form so a future BLAKE3 backend can produce wire-compatible
// keys by swapping the hash function.
// ---------------------------------------------------------------------------

///|
fn hex_digit(n : Int) -> Char {
  if n < 10 {
    (n + '0'.to_int()).unsafe_to_char()
  } else {
    (n - 10 + 'a'.to_int()).unsafe_to_char()
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
  h.update(@utf8.encode("cmd:" + task.cmd + "\n"))
  h.update(@utf8.encode("shell:" + task.shell + "\n"))
  for i, flag in task.shell_flags {
    let line = "shell-flag:" + i.to_string() + ":" + flag + "\n"
    h.update(@utf8.encode(line))
  }
  let env_keys = sorted_keys(task.env)
  for k in env_keys {
    let v = task.env.get(k).unwrap()
    h.update(@utf8.encode("env:" + k + "=" + v + "\n"))
  }
  let tool_keys = sorted_keys(task.tools)
  for k in tool_keys {
    let v = task.tools.get(k).unwrap()
    h.update(@utf8.encode("tool:" + k + "=" + v + "\n"))
  }
  for entry in input_hashes {
    let path = entry.0
    let digest = entry.1
    h.update(@utf8.encode("in:" + path + ":" + hex_encode(digest) + "\n"))
  }
  let param_keys = sorted_keys(params)
  for k in param_keys {
    let v = params.get(k).unwrap()
    h.update(@utf8.encode("param:" + k + "=" + v + "\n"))
  }
  for i, arg in positionals {
    h.update(@utf8.encode("arg:" + i.to_string() + ":" + arg + "\n"))
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
  let head = key[0:2].to_owned()
  let tail = key[2:key.length()].to_owned()
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
        Some(s[0:s.length() - 1].to_owned())
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
  let head = key[0:2].to_owned()
  let tail = key[2:key.length()].to_owned()
  base + "/cas/" + head + "/" + tail
}

///|
async fn remote_get_bytes(url : String) -> Bytes? {
  let headers = remote_headers()
  try {
    let (resp, data) = @http.get(url, headers~)
    if resp.code == 200 {
      // `&Data::binary` returns the raw response bytes without any
      // UTF-8 round-trip. `data.text().to_bytes()` would re-encode
      // the bytes as UTF-16 (MoonBit's String.to_bytes default),
      // wrecking binary payloads (Mach-O / ELF / archives).
      Some(data.binary())
    } else {
      None
    }
  } catch {
    _ => None
  }
}

///|
async fn remote_put_bytes(url : String, bytes : Bytes) -> Bool {
  let headers = remote_headers()
  try {
    let (resp, _) = @http.put(url, bytes, headers~)
    resp.code >= 200 && resp.code < 300
  } catch {
    _ => false
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
      "pkf: remote cache PUT failed for \{key[0:8].to_owned()} (ignored)",
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
  try {
    let tcp = @socket.Tcp::connect(addr)
    tcp.close()
    true
  } catch {
    _ => false
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
    raise Failure::Failure(
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
  try {
    @process.collect_output("pkill", ["-" + sig_name, "-P", pid.to_string()])
    |> ignore
  } catch {
    _ => ()
  }
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
          let waited = try { p.try_wait() } catch {
            _ => None
          }
          if waited is Some(_) {
            exited = true
            break
          }
          @async.sleep(50)
          ignore(j)
        }
        if !exited {
          // SIGKILL is not in mizchi/x/signal.Signal — fall back to the
          // subprocess `kill -KILL` for the hard shutdown path.
          try {
            @process.collect_output("pkill", ["-KILL", "-P", p.pid.to_string()])
            |> ignore
          } catch {
            _ => ()
          }
          try {
            @process.collect_output("kill", ["-KILL", p.pid.to_string()]) |> ignore
          } catch {
            _ => ()
          }
        }
        try p.wait() |> ignore catch {
          _ => ()
        }
      }
      None => ()
    }
  }
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
      println("pkf: # \{task.name} (cache hit \{k[0:8].to_owned()})")
      cache_restore(k, repo_root)
      return 0
    }
    if cache_remote_fetch(k, repo_root) {
      println("pkf: # \{task.name} (remote cache hit \{k[0:8].to_owned()})")
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
    try {
      let rs = start_service(group, plan, service_task, params)
      running.push(rs)
    } catch {
      err => {
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
  // The embedded Pkl loader evaluates the Taskfile fully in-process — local,
  // cached, remote `package://`, `http(s)://` and glob-import modules are all
  // resolved here, with no eval subprocess to fall back to.
  let result = try {
    @loader.eval_module_path(taskfile)
  } catch {
    err => {
      die("evaluate \{taskfile}: \{err.message()}")
      panic()
    }
  }
  match result {
    @pkl.EvalOk(value) =>
      @pkl.render_value_as_json(extract_output_value(value))
    @pkl.EvalError(errors) => {
      for e in errors {
        println("pkf: " + e.message)
      }
      die("pkl eval failed")
      panic()
    }
  }
}

///|
fn extract_output_value(value : @pkl.Value) -> @pkl.Value {
  // Module is rendered as ObjectValue with an `output { value = ... }`
  // member. Peel that off so the JSON we hand parse_plan looks the same
  // as `pkl eval -f json` would have produced.
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
      let stripped = arg[2:arg.length()].to_owned()
      match stripped.find("=") {
        Some(idx) => {
          let key = stripped[0:idx].to_owned()
          let value = stripped[idx + 1:stripped.length()].to_owned()
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
      try {
        @string.parse_int64(value) |> ignore
        true
      } catch {
        _ => {
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
  "0.12.1"
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
      changed_file = Some(arg[10:arg.length()].to_owned())
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
          let s = line.to_owned().trim().to_owned()
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
struct LocalTaskDecl {
  var_name : String
  task_name : String
  line : Int
}

///|
/// Mask `//` line comments, `/* */` block comments, and the *contents* of
/// `"..."` / `"""..."""` string literals with spaces, preserving the exact
/// length (so offsets and line numbers stay correct) and preserving newlines.
/// Mirrors Go's maskPklTrivia/maskPklString. The masked text is used for
/// brace counting and decl detection so braces/decls that appear inside
/// strings or comments do not skew the scan; the original source is kept for
/// extracting actual `name = "..."` values at the same offsets.
fn mask_pkl_trivia(src : String) -> String {
  let out : Array[Char] = []
  for c in src {
    out.push(c)
  }
  let n = out.length()
  let mut i = 0
  while i < n {
    let c = out[i]
    if c == '/' && i + 1 < n && out[i + 1] == '/' {
      while i < n && out[i] != '\n' {
        out[i] = ' '
        i = i + 1
      }
    } else if c == '/' && i + 1 < n && out[i + 1] == '*' {
      out[i] = ' '
      out[i + 1] = ' '
      i = i + 2
      while i + 1 < n && !(out[i] == '*' && out[i + 1] == '/') {
        if out[i] != '\n' {
          out[i] = ' '
        }
        i = i + 1
      }
      if i + 1 < n {
        out[i] = ' '
        out[i + 1] = ' '
        i = i + 2
      }
    } else if c == '"' {
      i = mask_pkl_string(out, i)
    } else {
      i = i + 1
    }
  }
  let sb = StringBuilder::new()
  for ch in out {
    sb.write_char(ch)
  }
  sb.to_string()
}

///|
/// Mask the contents of a string literal that starts at index `start`
/// (where `out[start] == '"'`). Handles `"""..."""` multi-line and `"..."`
/// single-line forms. Returns the index just past the closing quote(s).
fn mask_pkl_string(out : Array[Char], start : Int) -> Int {
  let n = out.length()
  let mut quote_count = 1
  while start + quote_count < n && out[start + quote_count] == '"' {
    quote_count = quote_count + 1
  }
  if quote_count >= 3 {
    let mut j = 0
    while j < quote_count && start + j < n {
      out[start + j] = ' '
      j = j + 1
    }
    let mut i = start + quote_count
    while i + quote_count - 1 < n {
      if repeated_char_at(out, i, '"', quote_count) {
        let mut k = 0
        while k < quote_count {
          out[i + k] = ' '
          k = k + 1
        }
        return i + quote_count
      }
      if out[i] != '\n' {
        out[i] = ' '
      }
      i = i + 1
    }
    return n
  }
  out[start] = ' '
  let mut i = start + 1
  while i < n {
    if out[i] == '\\' {
      out[i] = ' '
      if i + 1 < n && out[i + 1] != '\n' {
        out[i + 1] = ' '
        i = i + 2
        continue
      }
      i = i + 1
      continue
    }
    if out[i] == '"' {
      out[i] = ' '
      return i + 1
    }
    if out[i] != '\n' {
      out[i] = ' '
    }
    i = i + 1
  }
  i
}

///|
/// Report whether `count` consecutive chars starting at `start` all equal `b`.
fn repeated_char_at(out : Array[Char], start : Int, b : Char, count : Int) -> Bool {
  if start + count > out.length() {
    return false
  }
  let mut i = 0
  while i < count {
    if out[start + i] != b {
      return false
    }
    i = i + 1
  }
  true
}

///|
/// Scan source text for `local <id> = new Task { ... }` declarations.
/// Handles single-line and multi-line forms. Returns a list of
/// (var_name, task_name, 1-based line number) tuples; task_name may be ""
/// when the `name = "..."` pattern is not found within the block.
///
/// Algorithm:
///   1. Split into lines; for each line, detect `local <id> = new Task`.
///   2. Collect everything from `{` to the matching `}` (possibly spanning
///      multiple lines) as the "body".
///   3. Extract `name = "<value>"` from the body (first static occurrence).
fn scan_local_task_decls(src : String) -> Array[LocalTaskDecl] {
  // Mask comments/strings before any structural scan so braces or `local
  // ... = new Task { ... }` text appearing inside strings/comments cannot
  // skew detection or brace matching. The original `src` is kept so the
  // real `name = "..."` value is read back at the same offsets.
  let masked = mask_pkl_trivia(src)
  let lines : Array[String] = []
  for lv in masked.split("\n") {
    lines.push(lv.to_owned())
  }
  let result : Array[LocalTaskDecl] = []
  let mut i = 0
  while i < lines.length() {
    let line = lines[i]
    // Detect the pattern: `local <id>` followed by `= new` and `Task` and `{`
    // Strip leading whitespace for detection.
    let trimmed = line.trim().to_owned()
    if trimmed.has_prefix("local ") {
      // Extract the identifier after "local ".
      let after_local = trimmed[6:trimmed.length()].to_owned()
      // Identifier ends at whitespace or '='.
      let mut id_end = after_local.length()
      for k in 0..<after_local.length() {
        let c = after_local[k]
        if c == ' ' || c == '\t' || c == '=' || c == ':' {
          id_end = k
          break
        }
      }
      let var_name = after_local[0:id_end].to_owned()
      if var_name.length() == 0 {
        i = i + 1
        continue
      }
      // Check that the rest of the declaration references `Task` and has `{`.
      let rest = after_local[id_end:after_local.length()].to_owned()
      if !rest.contains("Task") || !rest.contains("{") {
        // Could be multi-line: check if `new Task {` appears across next lines.
        // Simplified: if no `Task` and `{` on this line, skip.
        i = i + 1
        continue
      }
      // Now collect the body from `{` to matching `}`. All structural
      // scanning (offsets, braces) runs on `masked`; the actual `name`
      // value is read from the original `src` at the same offsets.
      let line_start_in_src = find_line_offset(masked, i)
      let line_text_start = line_start_in_src
      // Find the first `{` in or after the current line.
      let mut open_pos = -1
      let search_start = line_text_start
      let mut j = search_start
      while j < masked.length() {
        if masked[j] == '{' {
          open_pos = j
          break
        }
        // Don't cross into the next statement (stop at newline if no `{` yet
        // would mean no opening brace; but we already checked contains("{")).
        j = j + 1
      }
      if open_pos < 0 {
        i = i + 1
        continue
      }
      // Find matching `}` in the masked text.
      let close_pos = find_matching_brace(masked, open_pos)
      if close_pos < 0 {
        i = i + 1
        continue
      }
      // Extract body (inclusive of braces) from the ORIGINAL source so the
      // real `name = "..."` value is preserved.
      let body = src[open_pos:close_pos + 1].to_owned()
      // Find `name = "<value>"` inside body.
      let task_name = extract_static_name(body)
      result.push(LocalTaskDecl::{
        var_name,
        task_name: match task_name {
          Some(n) => n
          None => ""
        },
        line: i + 1, // 1-based
      })
      // Advance past the closing brace; figure out which line it's on.
      let close_line = count_newlines_before(masked, close_pos)
      if close_line > i {
        i = close_line + 1
      } else {
        i = i + 1
      }
    } else {
      i = i + 1
    }
  }
  result
}

///|
/// Return the byte offset of the start of line `line_index` (0-based) in `src`.
fn find_line_offset(src : String, line_index : Int) -> Int {
  if line_index == 0 {
    return 0
  }
  let mut count = 0
  for i in 0..<src.length() {
    if src[i] == '\n' {
      count = count + 1
      if count == line_index {
        return i + 1
      }
    }
  }
  src.length()
}

///|
/// Count how many newlines appear in `src` before position `pos`.
fn count_newlines_before(src : String, pos : Int) -> Int {
  let mut count = 0
  for i in 0..<pos {
    if i >= src.length() {
      break
    }
    if src[i] == '\n' {
      count = count + 1
    }
  }
  count
}

///|
/// Find the matching `}` for a `{` at position `open` in `src`.
/// Returns -1 if not found.
fn find_matching_brace(src : String, open : Int) -> Int {
  let mut depth = 0
  let mut i = open
  while i < src.length() {
    let c = src[i]
    if c == '{' {
      depth = depth + 1
    } else if c == '}' {
      depth = depth - 1
      if depth == 0 {
        return i
      }
    }
    i = i + 1
  }
  -1
}

///|
/// Extract the first `name = "<value>"` (no interpolation) from a block body.
/// Returns None if not found or if the value contains `\(` (interpolation).
fn extract_static_name(body : String) -> String? {
  // Search for `name` followed by `=` and a quoted string.
  let mut i = 0
  while i < body.length() {
    // Look for `name` token.
    if i + 4 <= body.length() && body[i:i + 4].to_owned() == "name" {
      // Must be preceded by non-identifier char (or start of string).
      let ok_before = if i == 0 {
        true
      } else {
        let c = body[i - 1]
        !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') && !(c >= '0' && c <= '9') && c != '_'
      }
      if ok_before {
        // Skip whitespace then `=`.
        let mut j = i + 4
        while j < body.length() && (body[j] == ' ' || body[j] == '\t') {
          j = j + 1
        }
        if j < body.length() && body[j] == '=' {
          j = j + 1
          // Skip whitespace then `"`.
          while j < body.length() && (body[j] == ' ' || body[j] == '\t') {
            j = j + 1
          }
          if j < body.length() && body[j] == '"' {
            // Collect until closing `"`.
            let mut k = j + 1
            let mut end_k = -1
            while k < body.length() {
              if body[k] == '"' {
                end_k = k
                break
              }
              k = k + 1
            }
            if end_k > j {
              let value = body[j + 1:end_k].to_owned()
              // Reject interpolated values.
              if !value.contains("\\(") {
                return Some(value)
              }
            }
          }
        }
      }
    }
    i = i + 1
  }
  None
}

///|
/// Whether `cmd` contains `needle` as a "wordish" token (mirrors Go's
/// commandContainsWordish): exact match, prefix `needle `, or surrounded by
/// one of the shell-ish delimiters.
fn command_contains_wordish(cmd : String, needle : String) -> Bool {
  if cmd == needle || cmd.has_prefix(needle + " ") {
    return true
  }
  cmd.contains(" " + needle + " ") ||
  cmd.contains(" " + needle + "\n") ||
  cmd.contains("\n" + needle + " ") ||
  cmd.contains("(" + needle + " ") ||
  cmd.contains("&& " + needle + " ") ||
  cmd.contains("; " + needle + " ")
}

///|
/// Mirrors Go's buildLikeTaskWithoutOutputs: a cached, non-service task with
/// a cmd that looks like it produces build artifacts but declares no outputs.
fn build_like_task_without_outputs(name : String, t : Task) -> Bool {
  if t.service || !t.cache || t.cmd == "" || t.outputs.length() > 0 {
    return false
  }
  let lower_cmd = t.cmd.to_lower()
  let build_commands = [
    "go build", "cargo build", "npm run build", "pnpm build", "pnpm run build",
    "yarn build", "yarn run build", "bun build", "bun run build", "vite build",
    "next build", "tsc", "webpack", "rollup", "esbuild",
  ]
  for needle in build_commands {
    if command_contains_wordish(lower_cmd, needle) {
      return true
    }
  }
  let lower_name = name.to_lower()
  lower_name.contains("build") && command_contains_wordish(lower_cmd, "build")
}

///|
/// A lint finding as a (line, message, json) triple so the merged list can be
/// sorted by (line, message) before serialization, mirroring Go's lintFindings.
struct LintFinding {
  line : Int
  message : String
  level : String
  json : Json
}

///|
/// Build the 5 rendered-task lint rules over `plan.tasks`, iterating task
/// names in sorted order. `line_of` maps a task name to its source line
/// (from the local decl scan), defaulting to 1. Mirrors Go's lintRenderedTasks.
fn lint_rendered_tasks(
  taskfile : String,
  plan : Plan,
  line_of : Map[String, Int],
) -> Array[LintFinding] {
  let names : Array[String] = []
  for name, _ in plan.tasks {
    names.push(name)
  }
  names.sort_by(fn(a, b) { lex_cmp(a, b) })
  let findings : Array[LintFinding] = []
  fn mk(
    line : Int,
    level : String,
    kind : String,
    task : String,
    message : String,
    suggestion : String,
    fixable : Bool,
  ) -> Unit {
    let f : Map[String, Json] = Map([], capacity=8)
    f["path"] = Json::string(taskfile)
    f["line"] = Json::number(line.to_double())
    f["level"] = Json::string(level)
    f["kind"] = Json::string(kind)
    f["task"] = Json::string(task)
    f["message"] = Json::string(message)
    f["suggestion"] = Json::string(suggestion)
    if fixable {
      f["fixable"] = Json::boolean(true)
    }
    findings.push(LintFinding::{
      line,
      message,
      level,
      json: Json::object(f),
    })
  }

  for name in names {
    let t = match plan.tasks.get(name) {
      Some(t) => t
      None => continue
    }
    let line = match line_of.get(name) {
      Some(l) if l != 0 => l
      _ => 1
    }
    // Rule 1: noop-task — neither cmd nor deps.
    if t.cmd == "" && t.deps.length() == 0 {
      mk(
        line,
        "error",
        "noop-task",
        name,
        "task \"\{name}\" has neither cmd nor deps; it is a no-op task",
        "add deps for an umbrella task, add cmd for an executable task, or remove the task",
        false,
      )
    }
    // Rule 2: outputs-without-inputs — cached with outputs but no inputs.
    if t.cache && t.outputs.length() > 0 && t.inputs.length() == 0 {
      mk(
        line,
        "error",
        "outputs-without-inputs",
        name,
        "task \"\{name}\" declares outputs but no inputs; cache can go stale because only config changes invalidate it",
        "declare every input the command reads, or set cache = false when the task is intentionally uncached",
        true,
      )
    }
    // Rule 3: service-without-readiness — service with no probe.
    if t.service && t.ready_port == 0 && t.ready_cmd == "" {
      mk(
        line,
        "error",
        "service-without-readiness",
        name,
        "task \"\{name}\" has service=true but no readiness probe; add readyPort or readyCmd so dependents do not race startup",
        "add readyPort when the service opens a TCP port, otherwise add readyCmd",
        false,
      )
    }
    // Rule 4: inputs-without-cache — non-service, uncached, has cmd + inputs.
    if !(t.service) && !(t.cache) && t.cmd != "" && t.inputs.length() > 0 {
      mk(
        line,
        "warning",
        "inputs-without-cache",
        name,
        "task \"\{name}\" declares inputs but cache=false, so input hashes only help affected/watch and cannot produce cache hits",
        "remove cache = false once the task is deterministic, or remove inputs if they are only decorative",
        false,
      )
    }
    // Rule 5: build-without-outputs.
    if build_like_task_without_outputs(name, t) {
      mk(
        line,
        "warning",
        "build-without-outputs",
        name,
        "task \"\{name}\" looks like it produces build artifacts but declares no outputs",
        "declare the artifact paths in outputs so cache hits can restore them, or set cache = false if the command should always run",
        false,
      )
    }
  }
  findings
}

///|
async fn lint_cmd(explicit_taskfile : String?, args : ArrayView[String]) -> Int {
  for arg in args {
    match arg {
      // lint always emits JSON; `--json` is accepted for symmetry but is a no-op.
      "--json" => ()
      "--fix" | "--dry-run" => () // not implemented: silently ignore
      _ => {
        if arg.has_prefix("--") {
          die("pkf lint: unknown flag `\{arg}`")
          return 2
        } else {
          die("lint takes no positional args, got `\{arg}`")
          return 2
        }
      }
    }
  }
  let taskfile = locate_taskfile(explicit_taskfile)
  let raw_json = eval_taskfile(taskfile)
  let plan = parse_plan(raw_json)
  let src = @fs.read_file_to_string(taskfile) catch {
    _ => {
      die("could not read Taskfile source: \{taskfile}")
      panic()
    }
  }
  let decls = scan_local_task_decls(src)
  // First task line per name, for rendered-rule line numbers (taskNameLineMap).
  let line_of : Map[String, Int] = Map([], capacity=decls.length())
  for decl in decls {
    if decl.task_name.length() == 0 {
      continue
    }
    if line_of.get(decl.task_name) is None {
      line_of[decl.task_name] = decl.line
    }
  }
  let merged : Array[LintFinding] = []
  // Dead-local findings.
  for decl in decls {
    if decl.task_name.length() == 0 {
      continue
    }
    if plan.tasks.get(decl.task_name) is None {
      let message = "local task \"\{decl.var_name}\" declares name \"\{decl.task_name}\" but is not included in tasks"
      let f : Map[String, Json] = Map([], capacity=8)
      f["path"] = Json::string(taskfile)
      f["line"] = Json::number(decl.line.to_double())
      f["level"] = Json::string("error")
      f["kind"] = Json::string("dead-local-task")
      f["task"] = Json::string(decl.task_name)
      f["message"] = Json::string(message)
      f["suggestion"] = Json::string(
        "remove local task \"\{decl.var_name}\" or include it in tasks { ... }",
      )
      merged.push(LintFinding::{
        line: decl.line,
        message,
        level: "error",
        json: Json::object(f),
      })
    }
  }
  // Rendered-task rule findings.
  for f in lint_rendered_tasks(taskfile, plan, line_of) {
    merged.push(f)
  }
  // Sort by (line, message) like Go's lintFindings.
  merged.sort_by(fn(a, b) {
    if a.line != b.line {
      return a.line.compare(b.line)
    }
    a.message.compare(b.message)
  })
  let findings : Array[Json] = []
  let mut error_count = 0
  for f in merged {
    findings.push(f.json)
    if f.level == "error" {
      error_count = error_count + 1
    }
  }
  let root : Map[String, Json] = Map([], capacity=1)
  root["findings"] = Json::array(findings)
  println(Json::object(root).stringify())
  if error_count > 0 {
    let plural = if error_count == 1 { "" } else { "s" }
    eprintln("pkf: lint found \{error_count} error\{plural}")
    return 1
  }
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
    let line = line_view.to_owned().trim().to_owned()
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
          amends = Some(line[start + 1:end].to_owned())
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
          let after = uri[idx + 7:uri.length()].to_owned()
          // End at `#` or end of string.
          let mut end = after.length()
          for i in 0..<after.length() {
            if after[i] == '#' || after[i] == '"' {
              end = i
              break
            }
          }
          if end > 0 {
            Some(after[0:end].to_owned())
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
  (   // wrapped: multiline string as a parenthesized expr
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
  )
}

///|
fn completion_zsh() -> String {
  (   // wrapped: multiline string as a parenthesized expr
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
  )
}

///|
fn completion_fish() -> String {
  (   // wrapped: multiline string as a parenthesized expr
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
  )
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
      explicit = Some(a[7:a.length()].to_owned())
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
/// `pkf doctor [--json]` — diagnose the pkfire setup.
/// Checks: pkf-path, pkl, cache, remote, taskfile.
/// Messages are environment-specific; the conformance contract checks only
/// labels + structure + exit, not message values.
async fn doctor_cmd(explicit_taskfile : String?, args : ArrayView[String]) -> Int {
  let mut json_flag = false
  for arg in args {
    match arg {
      "--json" => json_flag = true
      _ => {
        if arg.has_prefix("--") {
          die("pkf doctor: unknown flag `\{arg}`")
          return 2
        }
      }
    }
  }
  // Accumulate checks: each is {level, label, message}.
  let check_levels : Array[String] = []
  let check_labels : Array[String] = []
  let check_messages : Array[String] = []
  fn report(level : String, label : String, message : String) -> Unit {
    check_levels.push(level)
    check_labels.push(label)
    check_messages.push(message)
    if !json_flag {
      println("  \{level}  \{label}  \{message}")
    }
  }

  // 1. pkf-path — best-effort: try to find pkf in PATH via `which pkf`.
  let pkf_path_msg : String = try {
    let (code, data) = @process.collect_stdout("which", ["pkf"])
    if code == 0 {
      let p = data.text().trim().to_owned()
      "pkf found at \{p}"
    } else {
      "pkf not found in PATH"
    }
  } catch {
    _ => "pkf not found in PATH"
  }
  let pkf_path_level = if pkf_path_msg.contains("not found") { "WARN" } else { "OK" }
  report(pkf_path_level, "pkf-path", pkf_path_msg)

  // 2. pkl CLI — run `pkl --version`.
  let pkl_msg : String = try {
    let (code, data) = @process.collect_stdout("pkl", ["--version"])
    if code == 0 {
      let ver = data.text().trim().to_owned()
      "\{ver}"
    } else {
      "pkl found but --version failed (exit \{code})"
    }
  } catch {
    _ => "pkl not in PATH — install from https://pkl-lang.org/"
  }
  let pkl_level = if pkl_msg.contains("not in PATH") || pkl_msg.contains("failed") { "ERROR" } else { "OK" }
  report(pkl_level, "pkl", pkl_msg)

  // 3. cache directory.
  let cache_dir = cache_root()
  let cache_msg : String = {
    if @fs.path_exists(cache_dir) {
      let is_dir = @fs.is_dir(cache_dir) catch {
        _ => false
      }
      if !is_dir {
        "\{cache_dir} exists but is not a directory"
      } else {
        // Count entries in cas/ subdirectory if it exists.
        let cas_dir = join_path(cache_dir, "cas")
        let entries = @fs.read_dir(cas_dir) catch {
          _ => []
        }
        "\{cache_dir} (\{entries.length()} top-level CAS shards)"
      }
    } else {
      "\{cache_dir} (empty — will be created on first run)"
    }
  }
  let cache_level = if cache_msg.contains("not a directory") { "ERROR" } else { "OK" }
  report(cache_level, "cache", cache_msg)

  // 4. remote cache — check PKFIRE_MBT_REMOTE_CACHE env var.
  let remote_msg : String = match @sys.get_env_var("PKFIRE_MBT_REMOTE_CACHE") {
    Some(url) =>
      if url.length() == 0 {
        "PKFIRE_MBT_REMOTE_CACHE not set (local-only)"
      } else {
        "PKFIRE_MBT_REMOTE_CACHE=\{url}"
      }
    None => "PKFIRE_MBT_REMOTE_CACHE not set (local-only)"
  }
  report("OK", "remote", remote_msg)

  // 5. taskfile — best-effort; doctor should work outside any project.
  // Mimic locate_taskfile's walk-up logic but don't die() on miss.
  let found_taskfile : String? = match explicit_taskfile {
    Some(p) =>
      if @fs.path_exists(p) {
        Some(p)
      } else {
        None
      }
    None => {
      let cwd_opt = @env.current_dir()
      match cwd_opt {
        None => None
        Some(cwd) => {
          let mut dir = cwd
          let mut found : String? = None
          while true {
            let candidate = dir + "/Taskfile.pkl"
            if @fs.path_exists(candidate) {
              found = Some(candidate)
              break
            }
            let p = parent_dir(dir)
            if p == dir {
              break
            }
            dir = p
          }
          found
        }
      }
    }
  }
  let (taskfile_level, taskfile_msg) : (String, String) = match found_taskfile {
    None =>
      match @env.current_dir() {
        Some(cwd) => ("WARN", "no Taskfile.pkl found near \{cwd}")
        None => ("WARN", "no Taskfile.pkl found")
      }
    Some(tf) =>
      // Report the path and existence. Evaluating + parsing is best-effort
      // and would call die() on failure, which exits the process. Since
      // doctor should always complete gracefully, we just confirm the file
      // exists and is readable.
      ("OK", "\{tf} (found)")
  }
  report(taskfile_level, "taskfile", taskfile_msg)

  // Emit JSON or plain footer.
  if json_flag {
    let checks_arr : Array[Json] = []
    for i in 0..<check_levels.length() {
      let o : Map[String, Json] = Map([], capacity=3)
      o["level"] = Json::string(check_levels[i])
      o["label"] = Json::string(check_labels[i])
      o["message"] = Json::string(check_messages[i])
      checks_arr.push(Json::object(o))
    }
    let root : Map[String, Json] = Map([], capacity=2)
    root["version"] = Json::string(pkf_version())
    root["checks"] = Json::array(checks_arr)
    println(Json::object(root).stringify())
  } else {
    println("")
  }
  0
}

///|
/// `pkf explain <task>` — print the action-key surface for a single task.
///
/// Output is plain text; the action-key hash (SHA-256 here vs BLAKE3 in
/// Go pkfire) and the absolute workdir are environment-specific, so the
/// conformance scenario verifies structural markers only, not values.
async fn explain_cmd(
  explicit_taskfile : String?,
  args : ArrayView[String],
) -> Int {
  // Collect positional task name; ignore --diff (out of scope) and
  // reject any other unknown flags.
  let positionals : Array[String] = []
  for a in args {
    if a == "--diff" {
      // --diff is out of scope for pkf — silently skip.
      ()
    } else if a.has_prefix("--") {
      die("pkf explain: unknown flag `\{a}`")
      return 2
    } else {
      positionals.push(a)
    }
  }
  if positionals.length() == 0 {
    die("usage: pkf explain [-f FILE] <task>")
    return 2
  }
  if positionals.length() > 1 {
    die("pkf explain: too many task names; expected exactly one")
    return 2
  }
  let task_name = positionals[0]
  let taskfile = locate_taskfile(explicit_taskfile)
  let raw_json = eval_taskfile(taskfile)
  let plan = parse_plan(raw_json)
  let task = match plan.tasks.get(task_name) {
    Some(t) => t
    None => {
      die("unknown task: \"\{task_name}\" (try `pkf list --all`)")
      return 1
    }
  }
  let repo_root = taskfile_dir(taskfile)
  // Compute the effective workdir (abs path where the task runs).
  let effective_workdir = match task.workdir {
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
  // Compute the action key for this task (with zero input hashes — no
  // file I/O here, consistent with `explain` being a fast introspection
  // command). The hash value intentionally differs from Go pkfire (SHA-256
  // vs BLAKE3); the conformance scenario checks only that the field is
  // present, not the value.
  let action_key = compute_action_key(task, [], Map([], capacity=0), [])
  // Reverse deps: O(n*m) scan over all tasks.
  let dependents : Array[String] = []
  for dep_name in plan.task_order {
    match plan.tasks.get(dep_name) {
      Some(other) => {
        for d in other.deps {
          if d == task_name {
            dependents.push(dep_name)
            break
          }
        }
      }
      None => ()
    }
  }
  // Print the action-key surface — plain text.
  println("task:        " + task.name)
  println("action key:  " + action_key)
  println("cache:       " + task.cache.to_string())
  println("workdir:     " + effective_workdir + "  (Taskfile dir)")
  if task.deps.length() == 0 {
    println("deps:        (none)")
  } else {
    let joined_deps = {
      let mut s = ""
      for i, d in task.deps {
        if i > 0 {
          s = s + ", "
        }
        s = s + d
      }
      s
    }
    println("deps:        " + joined_deps)
  }
  if dependents.length() == 0 {
    println("dependents:  (none)")
  } else {
    let joined = {
      let mut s = ""
      for i, d in dependents {
        if i > 0 {
          s = s + ", "
        }
        s = s + d
      }
      s
    }
    println("dependents:  " + joined)
  }
  println("")
  println("cmd:")
  println("  " + task.cmd)
  println("")
  println("shell:       " + task.shell)
  let flags_joined = {
    let mut s = ""
    for i, f in task.shell_flags {
      if i > 0 {
        s = s + " "
      }
      s = s + f
    }
    s
  }
  println("shell flags: " + flags_joined)
  println("")
  println("env (\{task.env.length()}):")
  if task.env.length() == 0 {
    println("  (none)")
  } else {
    let env_keys = sorted_keys(task.env)
    for k in env_keys {
      let v = task.env.get(k).unwrap()
      println("  " + k + "=" + v)
    }
  }
  println("")
  println("tools (\{task.tools.length()}):")
  if task.tools.length() == 0 {
    println("  (none)")
  } else {
    let tool_keys = sorted_keys(task.tools)
    for k in tool_keys {
      let v = task.tools.get(k).unwrap()
      println("  " + k + "=" + v)
    }
  }
  println("")
  println("input patterns (\{task.inputs.length()}):")
  if task.inputs.length() == 0 {
    println("  (none)")
  } else {
    for pat in task.inputs {
      println("  " + pat)
    }
  }
  0
}

///|
fn init_template() -> String {
  (   // wrapped: multiline string as a parenthesized expr
  #|/// Generated by `pkf init`. See https://github.com/mizchi/pkfire.
  #|///
  #|/// Author each task as a `Task` instance with a unique `name`, then
  #|/// list it in the module-level `tasks`. Refer to other tasks with their
  #|/// local binding (e.g. `deps { build }`) — typos are caught by Pkl
  #|/// at evaluation time, before the runner ever starts.
  #|amends "https://raw.githubusercontent.com/mizchi/pkfire/main/pkl/Taskfile.pkl"
  #|
  #|local hello = new Task {
  #|  name = "hello"
  #|  description = "Smoke task — replace with your own"
  #|  cmd = "echo hello from pkfire"
  #|}
  #|
  #|tasks { hello }
  #|
  )
}

///|
///|
/// Expand glob patterns in `targets` against the task map.
/// Returns expanded list if any target contains `*` or `?`; else returns empty
/// (caller falls back to literal lookup).
fn expand_task_patterns(
  targets : Array[String],
  tasks : Map[String, Task],
) -> Array[String] {
  let mut any_pattern = false
  for t in targets {
    if t.contains("*") || t.contains("?") {
      any_pattern = true
      break
    }
  }
  if !any_pattern {
    return []
  }
  let seen : Map[String, Bool] = Map([], capacity=tasks.length())
  let out : Array[String] = []
  let all_names : Array[String] = []
  for name, _ in tasks {
    all_names.push(name)
  }
  all_names.sort_by(fn(a, b) { lex_cmp(a, b) })
  for t in targets {
    if !t.contains("*") && !t.contains("?") {
      if !seen.contains(t) {
        seen[t] = true
        out.push(t)
      }
      continue
    }
    let mut matched = false
    for name in all_names {
      if glob_match(t, name) {
        matched = true
        if !seen.contains(name) {
          seen[name] = true
          out.push(name)
        }
      }
    }
    if !matched {
      // Keep literal so the "unknown task" path surfaces the error.
      out.push(t)
    }
  }
  out
}

/// clean_cmd removes the declared `outputs` of one or more tasks.
/// Mirrors Go's cmdClean: literal output paths joined with task_root,
/// existence-checked via @fs.path_exists, then removed via rm_rf.
/// stdout: "removed: <abs-path>  (<task-name>)"
/// stderr: advisory messages when there is nothing to do.
async fn clean_cmd(explicit_taskfile : String?, args : ArrayView[String]) -> Int {
  // Parse args: collect task names (positional), ignore --dry-run silently
  // to avoid breaking users who copy Go invocations.
  let requested : Array[String] = []
  for a in args {
    if a == "--dry-run" {
      // dry-run not implemented: silently no-op (output still printed)
      ()
    } else if a == "-h" || a == "--help" {
      println("pkf clean — remove tasks' declared outputs")
      println("")
      println("usage:")
      println("  pkf clean [-f FILE] [task...]")
      return 0
    } else if a.has_prefix("-") {
      die("pkf clean: unknown flag `\{a}`")
      return 1
    } else {
      requested.push(a)
    }
  }
  let taskfile = locate_taskfile(explicit_taskfile)
  let raw_json = eval_taskfile(taskfile)
  let plan = parse_plan(raw_json)
  let repo_root = taskfile_dir(taskfile)

  // Resolve the set of task names to clean.
  let names : Array[String] = []
  if requested.length() == 0 {
    // Default: all tasks that declare at least one output, sorted.
    for name, task in plan.tasks {
      if task.outputs.length() > 0 {
        names.push(name)
      }
    }
    names.sort_by(fn(a, b) { lex_cmp(a, b) })
  } else {
    // Expand glob patterns if any target contains * or ?
    let expanded = expand_task_patterns(requested, plan.tasks)
    let actual_requested = if expanded.length() > 0 { expanded } else { requested }
    for n in actual_requested {
      match plan.tasks.get(n) {
        Some(_) => names.push(n)
        None => {
          die("unknown task: \"\{n}\"")
          return 1
        }
      }
    }
  }

  if names.length() == 0 {
    eprintln("[pkf] clean: no tasks declare outputs — nothing to do")
    return 0
  }

  let mut removed = 0
  for name in names {
    let task = plan.tasks.get(name).unwrap()
    if task.outputs.length() == 0 {
      eprintln("[pkf] \{name}: no outputs declared — skipping")
      continue
    }
    // Compute task_root (mirrors Go's TaskRoot / MBT's task_cwd logic).
    let task_root = match task.workdir {
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
    for out in task.outputs {
      let path = if task_root.length() == 0 || task_root == "." {
        out
      } else {
        task_root + "/" + out
      }
      if !@fs.path_exists(path) {
        continue
      }
      rm_rf(path)
      println("removed: \{path}  (\{name})")
      removed = removed + 1
    }
  }
  if removed == 0 {
    eprintln("[pkf] clean: nothing to remove (no declared outputs exist on disk)")
  }
  0
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
    "clean" => {
      let (explicit_taskfile, rest) = extract_file_flag(args[1:])
      clean_cmd(explicit_taskfile, rest[:])
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
        if !task.accepts_args &&
          name == target &&
          parsed.positionals.length() > 0 &&
          !(is_git_hook_event(target)) {
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
    "doctor" => {
      let (explicit_taskfile, rest) = extract_file_flag(args[1:])
      doctor_cmd(explicit_taskfile, rest[:])
    }
    "info" => {
      let (explicit_taskfile, rest) = extract_file_flag(args[1:])
      info_cmd(explicit_taskfile, rest[:])
    }
    "lint" => {
      let (explicit_taskfile, rest) = extract_file_flag(args[1:])
      lint_cmd(explicit_taskfile, rest[:])
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
    "explain" => {
      let (explicit_taskfile, rest) = extract_file_flag(args[1:])
      explain_cmd(explicit_taskfile, rest[:])
    }
    "init" => {
      let mut force = false
      let mut dest = "Taskfile.pkl"
      let rest = args[1:]
      let mut i = 0
      while i < rest.length() {
        let a = rest[i]
        if a == "--force" {
          force = true
        } else if a == "-f" || a == "--file" {
          i = i + 1
          if i >= rest.length() {
            die("pkf init: -f/--file requires a value")
            return 1
          }
          dest = rest[i]
        } else if a.has_prefix("-f") && a.length() > 2 {
          dest = a[2:a.length()].to_owned()
        } else if a == "-h" || a == "--help" {
          println("pkf init — write a starter Taskfile.pkl")
          println("")
          println("usage:")
          println("  pkf init [-f FILE] [--force]")
          println("")
          println("flags:")
          println("  -f, --file FILE   destination (default: ./Taskfile.pkl)")
          println("      --force       overwrite if FILE already exists")
          return 0
        } else if !a.has_prefix("-") {
          eprintln("pkf: init takes no positional args, got [\{a}]")
          return 1
        }
        i = i + 1
      }
      if @fs.path_exists(dest) && !force {
        die("\{dest} already exists (use --force to overwrite)")
        return 1
      }
      let content = init_template()
      @fs.write_bytes_to_file(dest, @utf8.encode(content)) catch {
        e => {
          die("failed to write \{dest}: \{e}")
          return 1
        }
      }
      eprintln("wrote \{dest}")
      eprintln("  next: pkf list      # see declared tasks")
      eprintln("        pkf run hello # smoke the generated example")
      0
    }
    "format" => {
      let (explicit_taskfile, rest) = extract_file_flag(args[1:])
      format_cmd(explicit_taskfile, rest[:])
    }
    "migrate" => {
      let (explicit_taskfile, rest) = extract_file_flag(args[1:])
      migrate_cmd(explicit_taskfile, rest[:])
    }
    "hooks" => {
      let (explicit_taskfile, rest) = extract_file_flag(args[1:])
      hooks_cmd(explicit_taskfile, rest[:])
    }
    "cache" => {
      let cache_args : Array[String] = []
      for i in 1..<args.length() {
        cache_args.push(args[i])
      }
      cache_cmd(cache_args)
    }
    "pkl-cache" => {
      let sub_args : Array[String] = []
      for i in 1..<args.length() {
        sub_args.push(args[i])
      }
      pkl_cache_cmd(sub_args[:])
    }
    other => {
      eprintln("pkf: unknown subcommand `\{other}`")
      eprintln(usage_text())
      1
    }
  }
}

///|
/// format_cmd is a thin wrapper around `pkl format`.
/// With no positional PATH args, it discovers the Taskfile and formats
/// its directory — same walk-up behaviour as every other subcommand.
/// --check flips to `pkl format --diff-name-only` (exit 11 on violations).
async fn format_cmd(
  explicit_taskfile : String?,
  args : ArrayView[String],
) -> Int {
  let mut check = false
  let paths : Array[String] = []
  for arg in args {
    match arg {
      "--check" => check = true
      "-h" | "--help" => {
        println("pkf format — wrapper for 'pkl format -w'")
        println("")
        println("usage:")
        println("  pkf format [-f FILE] [--check] [PATH...]")
        println("")
        println("flags:")
        println("  -f, --file FILE  Taskfile.pkl path (used when no PATH is given)")
        println("      --check      report unformatted files without writing (exit 11 if any)")
        return 0
      }
      _ =>
        if !arg.has_prefix("-") {
          paths.push(arg)
        }
    }
  }
  // If no explicit paths, discover the Taskfile and use its directory.
  if paths.length() == 0 {
    let taskfile = locate_taskfile(explicit_taskfile)
    let dir = taskfile_dir(taskfile)
    paths.push(dir)
  }
  let pkl_args : Array[String] = ["format"]
  if check {
    pkl_args.push("--diff-name-only")
  } else {
    pkl_args.push("-w")
  }
  for p in paths {
    pkl_args.push(p)
  }
  let pkl_exit = @process.run_inherit("pkl", pkl_args[:])
  if pkl_exit != 0 {
    eprintln("pkf: pkl format exited \{pkl_exit}")
    return 1
  }
  0
}

///|
/// replace_pkfire_version replaces occurrences of `pkfire@N.N.N` (exactly 3
/// numeric parts) in the given source string with `pkfire@<new_ver>`. Tokens
/// that don't have exactly 3 numeric parts (e.g. `pkfire@0.4` or
/// `pkfire@1.2.3.4`) are left untouched.
///
/// Returns (new_body, changed, found) where:
///   found   = true  iff at least one valid `pkfire@N.N.N` token was seen
///   changed = true  iff at least one token was rewritten (old ≠ new_ver)
fn replace_pkfire_version(src : String, new_ver : String) -> (String, Bool, Bool) {
  let marker = "pkfire@"
  let mlen = marker.length()
  let buf = StringBuilder::new(size_hint=src.length())
  let mut i = 0
  let mut changed = false
  let mut found = false
  while i < src.length() {
    let remaining = src.length() - i
    if remaining >= mlen && src[i:i + mlen].to_owned() == marker {
      // Try to parse exactly N.N.N after the marker.
      let j0 = i + mlen
      let mut j = j0
      // Part 1: digits
      while j < src.length() && src[j] >= '0' && src[j] <= '9' {
        j = j + 1
      }
      let part1_len = j - j0
      if part1_len > 0 && j < src.length() && src[j] == '.' {
        j = j + 1
        let j1 = j
        // Part 2: digits
        while j < src.length() && src[j] >= '0' && src[j] <= '9' {
          j = j + 1
        }
        let part2_len = j - j1
        if part2_len > 0 && j < src.length() && src[j] == '.' {
          j = j + 1
          let j2 = j
          // Part 3: digits
          while j < src.length() && src[j] >= '0' && src[j] <= '9' {
            j = j + 1
          }
          let part3_len = j - j2
          if part3_len > 0 {
            // Valid 3-part version found.
            found = true
            let old_ver = src[i + mlen:j].to_owned()
            if old_ver != new_ver {
              changed = true
            }
            buf.write_string(marker)
            buf.write_string(new_ver)
            i = j
            continue
          }
        }
      }
      // Not a valid 3-part version — write marker verbatim and continue.
      buf.write_string(marker)
      i = i + mlen
    } else {
      let c = src[i]
      buf.write_char(c.to_int().unsafe_to_char())
      i = i + 1
    }
  }
  (buf.to_string(), changed, found)
}

///|
/// `pkf migrate --to=<ver> [-f FILE] [--dry-run] [--skip-verify]`
/// Rewrites the `pkfire@<old>` token in the amends URI to `<ver>`.
/// `--dry-run` prints the changed lines without writing.
/// `--skip-verify` skips the post-rewrite `pkl eval` check.
async fn migrate_cmd(
  explicit_taskfile : String?,
  args : ArrayView[String],
) -> Int {
  // Parse flags.
  let mut to : String? = None
  let mut dry_run = false
  let mut skip_verify = false
  let mut i = 0
  while i < args.length() {
    let a = args[i]
    if a == "--dry-run" {
      dry_run = true
    } else if a == "--skip-verify" {
      skip_verify = true
    } else if a == "-h" || a == "--help" {
      println("pkf migrate — rewrite Taskfile.pkl's amends URI to a new schema version")
      println("")
      println("usage:")
      println("  pkf migrate --to=<ver> [-f FILE] [--dry-run] [--skip-verify]")
      println("")
      println("flags:")
      println("      --to VER       target schema version (e.g. --to=0.11.0)")
      println("  -f, --file FILE    Taskfile.pkl path")
      println("      --dry-run      print the new amends line without writing")
      println("      --skip-verify  skip the post-rewrite pkl eval verification")
      return 0
    } else if a.has_prefix("--to=") {
      to = Some(a[5:].to_owned())
    } else if a == "--to" {
      i = i + 1
      if i >= args.length() {
        eprintln("pkf: --to requires a value")
        return 1
      }
      to = Some(args[i])
    } else if a.has_prefix("--") {
      eprintln("pkf: migrate: unknown flag `\{a}`")
      return 1
    }
    i = i + 1
  }
  let ver = match to {
    Some(v) => v
    None => {
      eprintln("pkf: --to=<version> is required (e.g. --to=0.5.0)")
      return 1
    }
  }
  let taskfile = locate_taskfile(explicit_taskfile)
  let src = @fs.read_file_to_string(taskfile) catch {
    e => {
      eprintln("pkf: migrate: failed to read \{taskfile}: \{e}")
      return 1
    }
  }
  let (new_body, changed, found) = replace_pkfire_version(src, ver)
  if !found {
    eprintln(
      "pkf: no pkfire@<version> reference found in \{taskfile} — is it amending the published schema?",
    )
    return 1
  }
  if !changed {
    println(
      "\{taskfile} already pins pkfire@\{ver} — nothing to migrate",
    )
    return 0
  }
  if dry_run {
    println("would migrate \{taskfile}")
    // Show the diff: lines that changed.
    let old_lines : Array[String] = []
    for lv in src.split("\n") {
      old_lines.push(lv.to_owned())
    }
    let new_lines : Array[String] = []
    for lv in new_body.split("\n") {
      new_lines.push(lv.to_owned())
    }
    let mut li = 0
    while li < old_lines.length() && li < new_lines.length() {
      let old_line = old_lines[li]
      let new_line = new_lines[li]
      if old_line != new_line {
        println("  -\{old_line}")
        println("  +\{new_line}")
      }
      li = li + 1
    }
    return 0
  }
  // Write the file.
  @fs.write_bytes_to_file(taskfile, @utf8.encode(new_body)) catch {
    e => {
      eprintln("pkf: write \{taskfile}: \{e}")
      return 1
    }
  }
  println("migrated \{taskfile} → pkfire@\{ver}")
  if skip_verify {
    return 0
  }
  // Run `pkl eval` to verify.
  let pkl_code = @process.run_inherit("pkl", ["eval", taskfile][:])
  if pkl_code != 0 {
    // Revert the file.
    @fs.write_bytes_to_file(taskfile, @utf8.encode(src)) catch {
      _ => ()
    }
    eprintln(
      "pkf: post-migration `pkl eval` failed (file reverted): exit \{pkl_code}",
    )
    return 1
  }
  println("verified: \{taskfile} evaluates against pkfire@\{ver}")
  0
}

// ---------------------------------------------------------------------------
// hooks subcommand — manage .git/hooks shims that delegate to pkf run.
// ---------------------------------------------------------------------------

///| The pkfHookMarker sentinel written into every managed shim.
///  Uninstall refuses to remove hooks that don't contain it.
let pkf_hook_marker : String = "# managed by pkf hooks install"

///| Recognised git client-side hook names (server-side hooks excluded).
let git_hook_events : Array[String] = [
  "pre-commit",
  "prepare-commit-msg",
  "commit-msg",
  "post-commit",
  "pre-rebase",
  "post-checkout",
  "post-merge",
  "pre-push",
  "post-rewrite",
]

///| Render the shim script for a single git hook event.
fn hook_script(event : String) -> String {
  "#!/bin/sh\n" + pkf_hook_marker + "\nexec pkf run " + event + " -- \"$@\"\n"
}

///| True when `name` is a recognised git client-side hook event. Used to
///  exempt hook tasks from the "task does not accept positional args"
///  guard: git always hands hook scripts argv (e.g. pre-push gets
///  `<remote> <url>`), and `pkf hooks install` forwards it as
///  `pkf run <event> -- "$@"`, so rejecting it would break every
///  installed hook. The args are still dropped unless the task sets
///  acceptsArgs (run_task only forwards positionals when accepts_args).
fn is_git_hook_event(name : String) -> Bool {
  for e in git_hook_events {
    if e == name {
      return true
    }
  }
  false
}

///| Walk up from `start_dir` looking for a `.git` entry; return the hooks
///  directory. Returns None when not inside a git repository.
fn find_git_hooks_dir(start_dir : String) -> String? {
  let mut dir = start_dir
  for ;; {
    let git = join_path(dir, ".git")
    if @fs.path_exists(git) {
      let is_dir = @fs.is_dir(git) catch {
        _ => false
      }
      if is_dir {
        return Some(join_path(git, "hooks"))
      } else {
        // .git is a file (worktree / submodule): parse `gitdir: <path>`.
        let data = @fs.read_file_to_string(git) catch {
          _ => return None
        }
        let line = data.trim().to_owned()
        let prefix = "gitdir:"
        let raw = if line.has_prefix(prefix) {
          line[prefix.length():line.length()].to_owned().trim().to_owned()
        } else {
          line
        }
        let abs_raw = if raw.has_prefix("/") {
          raw
        } else {
          join_path(dir, raw)
        }
        return Some(join_path(abs_raw, "hooks"))
      }
    }
    let parent = dirname(dir)
    if parent == dir || parent.length() == 0 {
      break
    }
    dir = parent
  }
  None
}

///| `pkf hooks install|uninstall|list [-f FILE] [--force]`
async fn hooks_cmd(
  explicit_taskfile : String?,
  args : ArrayView[String],
) -> Int {
  if args.length() == 0 {
    eprintln("pkf: usage: pkf hooks <install|uninstall|list> [-f FILE] [--force]")
    return 1
  }
  let sub = args[0]
  if sub == "-h" || sub == "--help" {
    println("pkf hooks — manage .git/hooks shims")
    println("")
    println("usage:")
    println("  pkf hooks <install|uninstall|list> [-f FILE] [--force]")
    println("")
    println("subcommands:")
    println("  install     create .git/hooks/<event> shims for tasks named pre-commit, pre-push, commit-msg, ...")
    println("  uninstall   remove the shims installed by 'pkf hooks install'")
    println("  list        list every git event that has an installed shim")
    println("")
    println("flags:")
    println("  -f, --file FILE  Taskfile.pkl path")
    println("      --force      overwrite hooks not managed by pkfire")
    return 0
  }

  // Parse remaining flags after the subcommand.
  let mut force = false
  let positionals : Array[String] = []
  let mut i = 1
  while i < args.length() {
    let a = args[i]
    if a == "--force" {
      force = true
    } else if a == "-h" || a == "--help" {
      // help handled above via sub == --help; honour here too
      println("pkf hooks — manage .git/hooks shims")
      return 0
    } else if a.has_prefix("-") && a != "-f" && a != "--file" && !a.has_prefix("--file=") {
      // Unknown flag
      eprintln("pkf: hooks: unknown flag `\{a}`")
      return 1
    } else if !a.has_prefix("-") {
      positionals.push(a)
    }
    i = i + 1
  }
  if positionals.length() > 0 {
    eprintln("pkf: hooks \{sub} takes no positional args, got \{positionals[0]}")
    return 1
  }

  let taskfile = locate_taskfile(explicit_taskfile)
  let raw_json = eval_taskfile(taskfile)
  let plan = parse_plan(raw_json)
  let task_dir = taskfile_dir(taskfile)

  let hooks_dir = match find_git_hooks_dir(task_dir) {
    Some(d) => d
    None => {
      eprintln("pkf: not inside a git repository (no .git found from \{task_dir})")
      return 1
    }
  }

  match sub {
    "install" => hooks_install(plan, hooks_dir, force)
    "uninstall" => hooks_uninstall(hooks_dir)
    "list" => hooks_list(plan, hooks_dir)
    _ => {
      eprintln("pkf: unknown hooks subcommand \"\{sub}\" (want install|uninstall|list)")
      1
    }
  }
}

///| Join an Array[String] with a separator (used for events list).
fn join_with(items : Array[String], sep : String) -> String {
  let buf = StringBuilder::new(size_hint=64)
  for i, item in items {
    if i > 0 {
      buf.write_string(sep)
    }
    buf.write_string(item)
  }
  buf.to_string()
}

///| Install pkfire-managed hook shims for every task whose name is a
///  recognised git hook event. Matches Go's hooksInstall exactly.
async fn hooks_install(plan : Plan, hooks_dir : String, force : Bool) -> Int {
  // Ensure the hooks directory exists.
  mkdir_p(hooks_dir)
  let mut matched = 0
  let mut wrote = 0
  let mut skipped = 0
  for event in git_hook_events {
    match plan.tasks.get(event) {
      None => continue
      Some(task) => {
        matched = matched + 1
        if task.cache {
          eprintln("[pkf] warning: task \"\{event}\" has cache=true; hooks typically want cache=false")
        }
        let path = join_path(hooks_dir, event)
        let want = hook_script(event)
        let existing_opt : String? = try {
          Some(@fs.read_file_to_string(path))
        } catch {
          _ => None
        }
        match existing_opt {
          Some(existing) =>
            if existing == want {
              // Bit-identical: silent idempotent no-op.
              continue
            } else if existing.contains(pkf_hook_marker) {
              // Pkfire-managed but stale — overwrite + report.
              ()
            } else {
              // Written by someone else.
              if !force {
                eprintln("[pkf] \{event}: not managed by pkfire, skipping (use --force to overwrite)")
                skipped = skipped + 1
                continue
              }
            }
          None =>
            // File does not exist (or unreadable): write it.
            ()
        }
        @fs.write_bytes_to_file(path, @utf8.encode(want)) catch {
          e => {
            eprintln("pkf: write \{path}: \{e}")
            return 1
          }
        }
        // Set executable bit 0o755 via @xfs.chmod.
        @xfs.chmod(path.view(), 0o755) catch {
          _ => ()
        }
        println("installed \{path} → pkf run \{event}")
        wrote = wrote + 1
      }
    }
  }
  ignore(wrote)
  ignore(skipped)
  if matched == 0 {
    println("no installable hooks: the Taskfile declares no task named after a git hook event")
    println("  recognized events: " + join_with(git_hook_events, ", "))
  }
  0
}

///| Remove pkfire-managed hook shims. Non-pkfire hooks are left alone.
fn hooks_uninstall(hooks_dir : String) -> Int {
  let mut removed = 0
  for event in git_hook_events {
    let path = join_path(hooks_dir, event)
    let data = try {
      @fs.read_file_to_string(path)
    } catch {
      _ => continue
    }
    if !data.contains(pkf_hook_marker) {
      eprintln("[pkf] \{event}: not managed by pkfire, leaving alone")
      continue
    }
    @fs.remove_file(path) catch {
      e => {
        eprintln("pkf: remove \{path}: \{e}")
        return 1
      }
    }
    println("removed \{path}")
    removed = removed + 1
  }
  if removed == 0 {
    println("no pkfire-managed hooks found")
  }
  0
}

///| List the install state of every recognised git hook event.
fn hooks_list(plan : Plan, hooks_dir : String) -> Int {
  println("hooks dir: \{hooks_dir}\n")
  for event in git_hook_events {
    let has_task = plan.tasks.get(event) is Some(_)
    let task_state = if has_task { "task declared" } else { "no task" }
    let state = try {
      let data = @fs.read_file_to_string(join_path(hooks_dir, event))
      if data.contains(pkf_hook_marker) {
        "installed (pkfire)"
      } else {
        "installed (other)"
      }
    } catch {
      _ => "—"
    }
    // Match Go's %-20s  %-20s  %s column layout.
    let e_pad = pad_right(event, 20)
    let s_pad = pad_right(state, 20)
    println("  \{e_pad}  \{s_pad}  \{task_state}")
  }
  0
}

///| Right-pad a string to `width` chars with spaces.
fn pad_right(s : String, width : Int) -> String {
  let len = s.length()
  if len >= width {
    s
  } else {
    let buf = StringBuilder::new(size_hint=width)
    buf.write_string(s)
    for _ in 0..<(width - len) {
      buf.write_char(' ')
    }
    buf.to_string()
  }
}

// ---------------------------------------------------------------------------
// cache subcommand — inspect / clean the local CAS.
//
// `pkf cache <stats|prune|rm|clear>` mirrors Go's cmdCache.
// The MoonBit cache lives in $PKFIRE_MBT_CACHE_DIR (default
// ~/.cache/pkfire-mbt) and uses a cas/<aa>/<rest>/entry.tar.gz layout.
// Stats/prune use the new mtime/size C FFIs added to stat_native.c.
// ---------------------------------------------------------------------------

///|
fn human_bytes(n : Int64) -> String {
  let unit : Int64 = 1024
  if n < unit {
    return n.to_string() + " B"
  }
  let mut div = unit
  let mut exp = 0
  let mut x = n / unit
  while x >= unit {
    div = div * unit
    exp = exp + 1
    x = x / unit
  }
  let suffixes = ["K", "M", "G", "T", "P", "E"]
  let suffix = if exp < suffixes.length() { suffixes[exp] } else { "?" }
  // Simple 1-decimal formatting.
  let scaled_10 = (n * 10L) / div
  let whole = scaled_10 / 10L
  let frac = scaled_10 % 10L
  whole.to_string() + "." + frac.to_string() + " " + suffix + "B"
}

///|
fn format_duration_sec(sec : Int64) -> String {
  if sec < 60L {
    return sec.to_string() + "s"
  } else if sec < 3600L {
    return (sec / 60L).to_string() + "m"
  } else if sec < 86400L {
    return (sec / 3600L).to_string() + "h"
  } else {
    return (sec / 86400L).to_string() + "d"
  }
}

///|
fn format_timestamp(sec : Int64) -> String {
  // Produce a rough ISO-8601 date from a Unix timestamp.
  // We don't have stdlib time, so emit a decimal epoch for brevity.
  // Go emits RFC3339; we emit "YYYY-MM-DD (approx)" via epoch arithmetic.
  let days_since_epoch = sec / 86400L
  // Simple Gregorian approximation from Julian Day Number.
  let jdn = days_since_epoch + 2440588L // Unix epoch = JDN 2440588
  let a = jdn + 32044L
  let b = (4L * a + 3L) / 146097L
  let c = a - (146097L * b) / 4L
  let d = (4L * c + 3L) / 1461L
  let e = c - (1461L * d) / 4L
  let m = (5L * e + 2L) / 153L
  let year = 100L * b + d - 4800L + m / 10L
  let month = m + 3L - 12L * (m / 10L)
  let day = e - (153L * m + 2L) / 5L + 1L
  let yy = year.to_string()
  let mm = if month < 10L { "0" + month.to_string() } else { month.to_string() }
  let dd = if day < 10L { "0" + day.to_string() } else { day.to_string() }
  yy + "-" + mm + "-" + dd
}

///|
/// Walk the CAS directory and call `cb` for each entry.
/// Entry path: <cas_dir>/<prefix2>/<rest>/entry.tar.gz
/// cb receives (hex_key, entry_dir, archive_size_bytes, mtime_sec).
fn walk_cas_entries(
  cas_dir : String,
  cb : (String, String, Int64, Int64) -> Unit,
) -> Unit {
  // Guard: if cas directory doesn't exist yet (cold cache), skip silently.
  if !@fs.path_exists(cas_dir) {
    return
  }
  let prefixes = @fs.read_dir(cas_dir) catch {
    _ => return
  }
  for prefix in prefixes {
    if prefix.length() != 2 {
      continue
    }
    let prefix_dir = join_path(cas_dir, prefix)
    let is_dir = @fs.is_dir(prefix_dir) catch {
      _ => false
    }
    if !is_dir {
      continue
    }
    let rests = @fs.read_dir(prefix_dir) catch {
      _ => continue
    }
    for rest in rests {
      let entry_dir = join_path(prefix_dir, rest)
      let is_entry_dir = @fs.is_dir(entry_dir) catch {
        _ => false
      }
      if !is_entry_dir {
        continue
      }
      let archive_path = join_path(entry_dir, "entry.tar.gz")
      let path_z = @utf8.encode(archive_path + "\u{00}")
      let size = file_size_bytes(path_z)
      let mtime = file_mtime_sec(path_z)
      cb(prefix + rest, entry_dir, if size < 0L { 0L } else { size }, mtime)
    }
  }
}

///|
fn cache_stats_cmd(cas_dir : String) -> Int {
  let mut count = 0
  let mut total_size : Int64 = 0L
  let mut oldest : Int64 = 0L
  let mut newest : Int64 = 0L
  walk_cas_entries(cas_dir, fn(_, _, size, mtime) {
    count = count + 1
    total_size = total_size + size
    if oldest == 0L || mtime < oldest {
      oldest = mtime
    }
    if mtime > newest {
      newest = mtime
    }
  })
  println("cache dir: \{cache_root()}")
  println("entries:   \{count}")
  println("size:      \{human_bytes(total_size)}")
  if count > 0 {
    let now = now_sec()
    println(
      "oldest:    \{format_timestamp(oldest)} (\{format_duration_sec(now - oldest)} ago)",
    )
    println(
      "newest:    \{format_timestamp(newest)} (\{format_duration_sec(now - newest)} ago)",
    )
  }
  0
}

///|
fn parse_duration_to_sec(s : String) -> Int64 {
  // Supports: Nd (days), Nh (hours), Nm (minutes), Ns (seconds).
  if s.has_suffix("d") {
    let num_str = s[:s.length() - 1].to_owned()
    try {
      return @string.parse_int(num_str, base=10).to_int64() * 86400L
    } catch {
      _ => ()
    }
  } else if s.has_suffix("h") {
    let num_str = s[:s.length() - 1].to_owned()
    try {
      return @string.parse_int(num_str, base=10).to_int64() * 3600L
    } catch {
      _ => ()
    }
  } else if s.has_suffix("m") {
    let num_str = s[:s.length() - 1].to_owned()
    try {
      return @string.parse_int(num_str, base=10).to_int64() * 60L
    } catch {
      _ => ()
    }
  } else if s.has_suffix("s") {
    let num_str = s[:s.length() - 1].to_owned()
    try {
      return @string.parse_int(num_str, base=10).to_int64()
    } catch {
      _ => ()
    }
  }
  // Default fallback: treat as seconds.
  try {
    return @string.parse_int(s, base=10).to_int64()
  } catch {
    _ => ()
  }
  // Default 30d if unrecognized.
  30L * 86400L
}

///|
fn cache_prune_cmd(cas_dir : String, args : ArrayView[String]) -> Int {
  let mut older_than = "30d"
  let mut dry_run = false
  for arg in args {
    if arg == "--dry-run" {
      dry_run = true
    } else if arg.has_prefix("--older-than=") {
      older_than = arg[13:arg.length()].to_owned()
    } else if arg == "--older-than" {
      // Space-separated value not supported without lookahead in ArrayView;
      // users should use --older-than=VAL form.
      ()
    }
  }
  // Parse the next arg after --older-than (space-separated form).
  let mut i = 0
  while i < args.length() {
    if args[i] == "--older-than" && i + 1 < args.length() {
      older_than = args[i + 1]
      i = i + 2
      continue
    }
    i = i + 1
  }
  let threshold_sec = parse_duration_to_sec(older_than)
  let cutoff = now_sec() - threshold_sec
  let mut removed = 0
  let mut freed : Int64 = 0L
  walk_cas_entries(cas_dir, fn(hex, entry_dir, size, mtime) {
    if mtime > cutoff {
      return
    }
    freed = freed + size
    removed = removed + 1
    let short_hex = if hex.length() > 12 {
      hex[0:12].to_owned()
    } else {
      hex
    }
    let age = now_sec() - mtime
    if dry_run {
      println(
        "would remove \{short_hex} (\{human_bytes(size)}, \{format_duration_sec(age)} old)",
      )
      return
    }
    rm_rf(entry_dir)
    println(
      "removed \{short_hex} (\{human_bytes(size)}, \{format_duration_sec(age)} old)",
    )
  })
  println("")
  if dry_run {
    println("would remove \{removed} entries (\{human_bytes(freed)})")
  } else {
    println("removed \{removed} entries (\{human_bytes(freed)} freed)")
  }
  0
}

///|
fn cache_rm_cmd(cas_dir : String, keys : Array[String]) -> Int {
  if keys.length() == 0 {
    eprintln("pkf: usage: pkf cache rm <action-key-hex>")
    return 1
  }
  let mut removed = 0
  for key in keys {
    if key.length() < 2 {
      eprintln("pkf: cache rm: action key \"\{key}\" too short (need >= 2 hex chars)")
      return 1
    }
    let prefix2 = key[:2].to_owned()
    let bucket = join_path(cas_dir, prefix2)
    if key.length() >= 64 {
      // Full 64-char hex: direct path.
      let rest = key[2:].to_owned()
      let entry_dir = join_path(bucket, rest)
      if !@fs.path_exists(entry_dir) {
        eprintln("[pkf] cache rm: no entry at \{key}")
        continue
      }
      rm_rf(entry_dir)
      println("removed \{key}")
      removed = removed + 1
    } else {
      // Prefix match.
      let rest_prefix = key[2:].to_owned()
      let candidates = @fs.read_dir(bucket) catch {
        _ => {
          eprintln("[pkf] cache rm: no entry matching \{key}")
          continue
        }
      }
      let matches : Array[String] = []
      for cand in candidates {
        if cand.has_prefix(rest_prefix) {
          matches.push(cand)
        }
      }
      if matches.length() == 0 {
        eprintln("[pkf] cache rm: no entry matching \{key}")
        continue
      } else if matches.length() > 1 {
        eprintln(
          "pkf: cache rm: prefix \"\{key}\" matches \{matches.length()} entries; disambiguate",
        )
        return 1
      }
      let entry_dir = join_path(bucket, matches[0])
      rm_rf(entry_dir)
      println("removed \{key}")
      removed = removed + 1
    }
  }
  println("")
  println("removed \{removed} entries")
  0
}

///|
fn cache_clear_cmd(cas_dir : String, args : ArrayView[String]) -> Int {
  let mut yes = false
  for arg in args {
    if arg == "--yes" {
      yes = true
    }
  }
  if !@fs.path_exists(cas_dir) {
    println("cache already empty")
    return 0
  }
  if !yes {
    eprintln(
      "pkf: refusing to clear \{cas_dir} without --yes (use --yes for scripts)",
    )
    return 1
  }
  rm_rf(cas_dir)
  println("cleared \{cas_dir}")
  0
}

///|
fn cache_cmd(args : Array[String]) -> Int {
  if args.length() == 0 {
    println("pkf cache — inspect / clean the local CAS")
    println("")
    println("usage:")
    println("  pkf cache <stats|prune|rm|clear> [args]")
    println("")
    println("subcommands:")
    println("  stats                                 print cache dir, entry count, total size, oldest/newest mtime")
    println("  prune [--older-than DUR] [--dry-run]  drop entries older than DUR (default 30d)")
    println("  rm <action-key-hex>...                remove specific entries")
    println("  clear [--yes]                         remove every entry")
    return 0
  }
  let sub = args[0]
  let cas_dir = join_path(cache_root(), "cas")
  match sub {
    "stats" => cache_stats_cmd(cas_dir)
    "prune" => cache_prune_cmd(cas_dir, args[1:])
    "rm" => {
      let keys : Array[String] = []
      for i in 1..<args.length() {
        keys.push(args[i])
      }
      cache_rm_cmd(cas_dir, keys)
    }
    "clear" => cache_clear_cmd(cas_dir, args[1:])
    other => {
      die(
        "unknown cache subcommand \"\{other}\" (want stats|prune|rm|clear)",
      )
      1
    }
  }
}

///|
/// pkl_cache_cmd pre-evaluates Pkl files so ~/.pkl/cache is populated
/// before parallel jobs. Mirrors Go's cmdPklCache / pklCacheWarm.
///
/// Usage: pkf pkl-cache [warm] [-f FILE] [PATH...]
///
/// With no subcommand, defaults to warm (Go does the same).
/// Unknown subcommands → die with exit 1.
async fn pkl_cache_cmd(args : ArrayView[String]) -> Int {
  // Default to warm when no subcommand given (mirrors Go).
  let sub = if args.length() == 0 { "warm" } else { args[0] }
  match sub {
    "warm" => {
      let warm_args = if args.length() == 0 { args } else { args[1:] }
      pkl_cache_warm_cmd(warm_args)
    }
    _ => {
      die("unknown pkl-cache subcommand \"\{sub}\" (want: warm)")
      1
    }
  }
}

///|
/// pkl_cache_warm_cmd evaluates each path via `pkl eval` to populate
/// ~/.pkl/cache. When no paths are given, warms the located Taskfile.
async fn pkl_cache_warm_cmd(args : ArrayView[String]) -> Int {
  let (explicit_taskfile, rest) = extract_file_flag(args)
  // Collect extra positional paths.
  let extra_paths : Array[String] = []
  for a in rest {
    extra_paths.push(a)
  }
  // Build the list of paths to warm.
  let paths : Array[String] = if extra_paths.length() > 0 {
    extra_paths
  } else {
    [locate_taskfile(explicit_taskfile)]
  }
  let mut warmed = 0
  for p in paths {
    println("warming \{p}...")
    // Run `pkl eval <p>`; discard output (inherit so stderr is visible).
    // We use collect_output so stdout is suppressed but stderr still shows.
    let (code, _stdout, _stderr) = @process.collect_output("pkl", ["eval", p][:])
    if code != 0 {
      die("pkl eval \{p}: exited with code \{code}")
      return 1
    }
    warmed = warmed + 1
  }
  println("warmed \{warmed} file(s); ~/.pkl/cache is now populated")
  0
}

///|
async fn main {
  let args = @sys.get_cli_args()
  // The first argv entry is the binary path; skip it.
  let trimmed : Array[String] = []
  for i in 1..<args.length() {
    trimmed.push(args[i])
  }
  let code = @async.with_task_group(group => run_main(group, trimmed))
  @sys.exit(code)
}
