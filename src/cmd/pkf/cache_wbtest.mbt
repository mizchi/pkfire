// Tests for the pieces the cache's correctness rests on: the archive
// round-trip, the checks that reject a hostile or damaged archive, and
// the action-key derivation.
//
// Each of these covers a defect that shipped: entries whose paths were
// silently truncated, malformed archives that read as short-but-valid,
// and action keys blind to fields that changed what the command did.

///|
fn tar_round_trip(entries : Array[(String, String, Int)]) -> Array[TarEntry] {
  let tb = tar_new()
  for e in entries {
    tar_write_entry(tb, e.0, @utf8.encode(e.1), e.2)
  }
  match tar_iter(tar_finish(tb)) {
    TarOk(out) => out
    TarMalformed(why) => abort("unexpected malformed archive: " + why)
  }
}

///|
test "tar round-trips a name longer than the 100-byte ustar field" {
  // 12 * 12 = 144 bytes — the kind of path a nested node_modules or a
  // Rust target triple produces. Truncating it restores the output to
  // the wrong location.
  let mut deep = "dist"
  for _ in 0..<12 {
    deep = deep + "/abcdefghijk"
  }
  assert_true(@utf8.encode(deep).length() > 100)
  let out = tar_round_trip([(deep, "payload", 0o644)])
  assert_eq(out.length(), 1)
  assert_eq(out[0].name, deep)
  assert_eq(out[0].content, @utf8.encode("payload"))
}

///|
test "tar preserves short names, contents and mode bits" {
  let out = tar_round_trip([
    ("bin/app", "ELF", 0o755),
    ("share/readme.txt", "hello", 0o644),
  ])
  assert_eq(out.length(), 2)
  assert_eq(out[0].name, "bin/app")
  assert_eq(out[0].mode, 0o755)
  assert_eq(out[1].name, "share/readme.txt")
  assert_eq(out[1].mode, 0o644)
}

///|
test "tar rejects a corrupted header instead of returning a short read" {
  let tb = tar_new()
  tar_write_entry(tb, "a.txt", @utf8.encode("one"), 0o644)
  tar_write_entry(tb, "b.txt", @utf8.encode("two"), 0o644)
  let bytes = tar_finish(tb)
  // Flip a byte in the *second* header's name field. Before the
  // checksum check this parsed as a valid archive containing only
  // `a.txt` — a cache entry that restores half a build tree.
  let mutated : FixedArray[Byte] = FixedArray::make(bytes.length(), b'\x00')
  for i in 0..<bytes.length() {
    mutated[i] = bytes[i]
  }
  let second_header = 1024
  mutated[second_header] = b'X'
  match tar_iter(Bytes::from_array(mutated)) {
    TarOk(_) => fail("expected the corrupted header to be rejected")
    TarMalformed(_) => ()
  }
}

///|
test "tar rejects a truncated archive" {
  let tb = tar_new()
  tar_write_entry(tb, "a.txt", @utf8.encode("one"), 0o644)
  let bytes = tar_finish(tb)
  // Drop the trailing zero blocks: a half-transferred remote entry.
  let cut = bytes.length() - 1024
  let short : FixedArray[Byte] = FixedArray::make(cut, b'\x00')
  for i in 0..<cut {
    short[i] = bytes[i]
  }
  match tar_iter(Bytes::from_array(short)) {
    TarOk(_) => fail("expected the truncated archive to be rejected")
    TarMalformed(_) => ()
  }
}

///|
test "archive paths that escape the restore root are rejected" {
  assert_true(is_safe_archive_path("dist/app"))
  assert_true(is_safe_archive_path("a/b/c.txt"))
  // `..` anywhere in the path walks out of the workspace.
  assert_false(is_safe_archive_path("../../.ssh/authorized_keys"))
  assert_false(is_safe_archive_path("dist/../../etc/passwd"))
  assert_false(is_safe_archive_path("dist\\..\\..\\etc\\passwd"))
  // Absolute paths, unix and windows.
  assert_false(is_safe_archive_path("/etc/passwd"))
  assert_false(is_safe_archive_path("\\windows\\system32"))
  assert_false(is_safe_archive_path("C:\\windows\\system32"))
  assert_false(is_safe_archive_path(""))
  // A file literally named `..foo` is fine; only the exact `..`
  // component escapes.
  assert_true(is_safe_archive_path("dist/..foo"))
}

///|
fn key_test_task(name : String) -> Task {
  Task::{
    name,
    cmd: "make build",
    shell: "bash",
    shell_flags: ["-c"],
    inputs: [],
    outputs: ["dist/app"],
    deps: [],
    env: Map([], capacity=0),
    tools: Map([], capacity=0),
    cache: true,
    workdir: None,
    inherit_env: true,
    params: [],
    accepts_args: false,
    service: false,
    quiet: false,
    services: [],
    ready_port: 0,
    ready_cmd: "",
    ready_timeout_seconds: 30,
    shutdown_timeout_seconds: 5,
    description: None,
    visibility: "public",
  }
}

///|
fn key_test_plan(task : Task, default_env : Map[String, String]) -> Plan {
  let tasks : Map[String, Task] = Map([], capacity=1)
  tasks[task.name] = task
  Plan::{
    default_env,
    default_shell: "bash",
    default_shell_flags: ["-c"],
    tasks,
    task_order: [task.name],
    workflow_tests: [],
  }
}

///|
fn key_of(task : Task, plan : Plan) -> String {
  action_key_of(
    lower_task_to_action(plan, task, [], Map([], capacity=0), [], ""),
  )
}

///|
test "action key covers the module-level defaults.env" {
  // `defaults.env` reaches the command but used to be invisible to the
  // key, so flipping a shared NODE_ENV silently reused the other
  // build's outputs.
  let task = key_test_task("build")
  let base = key_of(task, key_test_plan(task, Map([], capacity=0)))
  let dev : Map[String, String] = Map([], capacity=1)
  dev["NODE_ENV"] = "development"
  let prod : Map[String, String] = Map([], capacity=1)
  prod["NODE_ENV"] = "production"
  let dev_key = key_of(task, key_test_plan(task, dev))
  let prod_key = key_of(task, key_test_plan(task, prod))
  assert_not_eq(base, dev_key)
  assert_not_eq(dev_key, prod_key)
}

///|
test "action key covers inheritEnv, outputs and workdir" {
  let task = key_test_task("build")
  let plan = key_test_plan(task, Map([], capacity=0))
  let base = key_of(task, plan)
  assert_not_eq(base, key_of({ ..task, inherit_env: false }, plan))
  assert_not_eq(base, key_of({ ..task, outputs: ["dist/other"] }, plan))
  assert_not_eq(base, key_of({ ..task, workdir: Some("packages/app") }, plan))
}

///|
test "action key ignores workdir spellings that mean the same directory" {
  let task = key_test_task("build")
  let plan = key_test_plan(task, Map([], capacity=0))
  let base = key_of(task, plan)
  assert_eq(base, key_of({ ..task, workdir: Some(".") }, plan))
  assert_eq(
    key_of({ ..task, workdir: Some("packages/app") }, plan),
    key_of({ ..task, workdir: Some("./packages/app/") }, plan),
  )
}

///|
test "action key is stable across map iteration order" {
  // `env` and `tools` are hash maps; the key must not depend on the
  // order they happen to enumerate in.
  let a : Map[String, String] = Map([], capacity=3)
  a["A"] = "1"
  a["B"] = "2"
  a["C"] = "3"
  let b : Map[String, String] = Map([], capacity=3)
  b["C"] = "3"
  b["B"] = "2"
  b["A"] = "1"
  let task = key_test_task("build")
  let plan = key_test_plan(task, Map([], capacity=0))
  assert_eq(key_of({ ..task, env: a }, plan), key_of({ ..task, env: b }, plan))
  assert_eq(
    key_of({ ..task, tools: a }, plan),
    key_of({ ..task, tools: b }, plan),
  )
}

///|
test "canonical form is unambiguous across field boundaries" {
  // Without length prefixes, a value containing the serializer's own
  // separators could forge a neighbouring field and collide with a
  // genuinely different action.
  let task = key_test_task("build")
  let plan = key_test_plan(task, Map([], capacity=0))
  let sneaky = { ..task, cmd: "make build\nenv=0:\ninput.path=5:evil\n" }
  assert_not_eq(key_of(task, plan), key_of(sneaky, plan))
}

///|
test "action key separates params from positional args" {
  let task = key_test_task("build")
  let plan = key_test_plan(task, Map([], capacity=0))
  let params : Map[String, String] = Map([], capacity=1)
  params["version"] = "1.2.3"
  let with_param = action_key_of(
    lower_task_to_action(plan, task, [], params, [], ""),
  )
  let with_arg = action_key_of(
    lower_task_to_action(
      plan,
      { ..task, accepts_args: true },
      [],
      Map([], capacity=0),
      ["1.2.3"],
      "",
    ),
  )
  assert_not_eq(with_param, with_arg)
}

///|
test "profile partitions the cache" {
  let task = key_test_task("build")
  let plan = key_test_plan(task, Map([], capacity=0))
  let plain = action_key_of(
    lower_task_to_action(plan, task, [], Map([], capacity=0), [], ""),
  )
  let ci = action_key_of(
    lower_task_to_action(plan, task, [], Map([], capacity=0), [], "ci"),
  )
  assert_not_eq(plain, ci)
}

///|
test "literal outputs exclude glob patterns" {
  let task = {
    ..key_test_task("build"),
    outputs: ["dist/app", "dist/*.map", "out/{a,b}", "x[0-9].bin", "q?.txt"],
  }
  assert_eq(literal_outputs(task), ["dist/app"])
}
