///|
fn assert_glob_witness(left : String, right : String) -> Unit raise {
  let witness = glob_intersection_witness(left, right)
  if witness is None {
    fail("expected glob intersection: \{left} <> \{right}")
  }
  let path = witness.unwrap()
  if !glob_match(left, path) || !glob_match(right, path) {
    fail("invalid witness \"\{path}\": \{left} <> \{right}")
  }
}

///|
fn assert_glob_disjoint(left : String, right : String) -> Unit raise {
  match glob_intersection_witness(left, right) {
    Some(path) => fail("unexpected witness \"\{path}\": \{left} <> \{right}")
    None => ()
  }
}

///|
fn finite_glob_paths() -> Array[String] {
  let segments = [
    "a", "b", "aa", "ab", "ba", "a.txt", "b.txt", "src", "dist", "generated",
  ]
  let paths : Array[String] = []
  for first in segments {
    paths.push(first)
    for second in segments {
      paths.push(first + "/" + second)
      for third in segments {
        paths.push(first + "/" + second + "/" + third)
      }
    }
  }
  paths
}

///|
fn watch_test_task(
  name : String,
  inputs : Array[String],
  outputs : Array[String],
  cache : Bool,
  workdir : String?,
  service : Bool,
) -> Task {
  Task::{
    name,
    cmd: if service {
      "serve"
    } else {
      "build"
    },
    shell: "bash",
    shell_flags: ["-c"],
    inputs,
    outputs,
    deps: [],
    env: Map([], capacity=0),
    tools: Map([], capacity=0),
    cache,
    workdir,
    inherit_env: true,
    params: [],
    accepts_args: false,
    service,
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
fn watch_test_plan(tasks : Array[Task]) -> Plan {
  let task_map : Map[String, Task] = Map([], capacity=tasks.length())
  let order : Array[String] = []
  for task in tasks {
    task_map[task.name] = task
    order.push(task.name)
  }
  Plan::{
    default_env: Map([], capacity=0),
    default_shell: "bash",
    default_shell_flags: ["-c"],
    tasks: task_map,
    task_order: order,
    workflow_tests: [],
  }
}

///|
test "glob intersection returns a witness accepted by both patterns" {
  let witness = glob_intersection_witness(
    "assets/*/manifest?.json", "**/manifest[0-9].json",
  )
  assert_true(witness is Some(_))
  let path = witness.unwrap()
  assert_true(glob_match("assets/*/manifest?.json", path))
  assert_true(glob_match("**/manifest[0-9].json", path))
}

///|
test "glob intersection handles doublestar zero and many segments" {
  assert_eq(glob_intersection_witness("dist/**", "**/*"), Some("dist"))
  let witness = glob_intersection_witness(
    "src/**/generated/*.mbt", "src/{api,web}/**/*.mbt",
  )
  assert_true(witness is Some(_))
  let path = witness.unwrap()
  assert_true(glob_match("src/**/generated/*.mbt", path))
  assert_true(glob_match("src/{api,web}/**/*.mbt", path))
}

///|
test "glob intersection proves disjoint path regions" {
  assert_eq(glob_intersection_witness("src/**/*.mbt", "_build/**/*"), None)
  assert_eq(
    glob_intersection_witness("assets/[a-c].json", "assets/[x-z].json"),
    None,
  )
}

///|
test "glob intersection covers literals wildcards classes braces and malformed classes" {
  let overlapping = [
    ("a", "a"),
    ("*", "?"),
    ("a**b", "a*b"),
    ("file?.[tj]s", "file[0-9].?s"),
    ("[!a]", "[b-d]"),
    ("[a-z]", "[m-z]"),
    ("[!a-z]", "[0-9]"),
    ("[! -~]", "?"),
    ("literal[", "literal["),
    ("{src,lib}/**/*.mbt", "lib/generated/{a,b}.mbt"),
    ("{a,{b,c}}/**", "c/file"),
    ("foo/**", "foo"),
    ("foo/**/bar", "foo/bar"),
    ("**/generated/**", "src/**"),
    ("日本語?.mbt", "日本語*.mbt"),
  ]
  for pair in overlapping {
    assert_glob_witness(pair.0, pair.1)
    assert_glob_witness(pair.1, pair.0)
  }
  let disjoint = [
    ("a", "b"),
    ("?", "aa"),
    ("[!a]", "a"),
    ("[a-f]", "[g-z]"),
    ("*.mbt", "*.js"),
    ("src/**", "dist/**"),
    ("foo/*/bar", "foo/bar"),
    ("{src,lib}/**", "{dist,tmp}/**"),
    ("literal[", "literalx"),
    ("a/**/b", "a/**/c"),
  ]
  for pair in disjoint {
    assert_glob_disjoint(pair.0, pair.1)
    assert_glob_disjoint(pair.1, pair.0)
  }
}

///|
test "glob solver agrees with matcher over a finite adversarial corpus" {
  let patterns = [
    "*", "?", "a", "a*", "*b", "a**b", "[ab]", "[!a]", "[a-c]*", "*.txt", "**", "**/*",
    "src/**", "**/*.txt", "src/*", "src/**/a", "{src,dist}/**", "src/[ab].txt", "dist/**/generated/*",
    "_build/**",
  ]
  let paths = finite_glob_paths()
  for left in patterns {
    for right in patterns {
      let witness = glob_intersection_witness(left, right)
      match witness {
        Some(path) =>
          if !glob_match(left, path) || !glob_match(right, path) {
            fail("solver produced an invalid witness: \{left} <> \{right}")
          }
        None => ()
      }
      assert_eq(
        witness is Some(_),
        glob_intersection_witness(right, left) is Some(_),
      )
      let mut finite_overlap = false
      for path in paths {
        if glob_match(left, path) && glob_match(right, path) {
          finite_overlap = true
          break
        }
      }
      if finite_overlap && witness is None {
        fail("solver missed a finite witness: \{left} <> \{right}")
      }
    }
  }
}

///|
test "watch cycle analysis finds self output and cache loops" {
  let tasks = [
    WatchTaskContract::{
      name: "build",
      inputs: ["**/*"],
      outputs: ["dist/**"],
      writes_cache: true,
    },
  ]
  let cycles = find_watch_cycles(tasks, Some(".pkf-cache/cas/**"))
  assert_eq(cycles.length(), 2)
  assert_eq(cycles[0].tasks, ["build"])
  assert_eq(cycles[0].kind, "cache")
  assert_true(glob_match("**/*", cycles[0].witness))
  assert_true(glob_match(".pkf-cache/cas/**", cycles[0].witness))
  assert_eq(cycles[1].kind, "output")
  assert_true(glob_match("dist/**", cycles[1].witness))
}

///|
test "watch cycle analysis finds a cross-task strongly connected component" {
  let tasks = [
    WatchTaskContract::{
      name: "generate",
      inputs: ["schema/**"],
      outputs: ["src/generated/**"],
      writes_cache: false,
    },
    WatchTaskContract::{
      name: "schema",
      inputs: ["src/generated/**"],
      outputs: ["schema/derived/**"],
      writes_cache: false,
    },
  ]
  let cycles = find_watch_cycles(tasks, None)
  assert_eq(cycles.length(), 1)
  assert_eq(cycles[0].kind, "cross-task")
  assert_eq(cycles[0].tasks, ["generate", "schema"])
}

///|
test "watch cycle analysis ignores one-way output propagation" {
  let tasks = [
    WatchTaskContract::{
      name: "generate",
      inputs: ["schema/**"],
      outputs: ["src/generated/**"],
      writes_cache: false,
    },
    WatchTaskContract::{
      name: "compile",
      inputs: ["src/generated/**"],
      outputs: ["dist/**"],
      writes_cache: false,
    },
  ]
  assert_eq(find_watch_cycles(tasks, None).length(), 0)
}

///|
test "watch cycle analysis finds a three-task SCC without absorbing a tail" {
  let tasks = [
    WatchTaskContract::{
      name: "a",
      inputs: ["a/in/**"],
      outputs: ["b/in/**"],
      writes_cache: false,
    },
    WatchTaskContract::{
      name: "b",
      inputs: ["b/in/**"],
      outputs: ["c/in/**"],
      writes_cache: false,
    },
    WatchTaskContract::{
      name: "c",
      inputs: ["c/in/**"],
      outputs: ["a/in/**"],
      writes_cache: false,
    },
    WatchTaskContract::{
      name: "tail",
      inputs: ["c/in/**"],
      outputs: ["final/**"],
      writes_cache: false,
    },
  ]
  let cycles = find_watch_cycles(tasks, None)
  assert_eq(cycles.length(), 1)
  assert_eq(cycles[0].kind, "cross-task")
  assert_eq(cycles[0].tasks, ["a", "b", "c"])
}

///|
test "watch cycle analysis reports disjoint SCCs separately" {
  let tasks = [
    WatchTaskContract::{
      name: "a",
      inputs: ["a/**"],
      outputs: ["b/**"],
      writes_cache: false,
    },
    WatchTaskContract::{
      name: "b",
      inputs: ["b/**"],
      outputs: ["a/**"],
      writes_cache: false,
    },
    WatchTaskContract::{
      name: "c",
      inputs: ["c/**"],
      outputs: ["d/**"],
      writes_cache: false,
    },
    WatchTaskContract::{
      name: "d",
      inputs: ["d/**"],
      outputs: ["c/**"],
      writes_cache: false,
    },
  ]
  let cycles = find_watch_cycles(tasks, None)
  assert_eq(cycles.length(), 2)
  assert_eq(cycles[0].tasks, ["a", "b"])
  assert_eq(cycles[1].tasks, ["c", "d"])
}

///|
test "watch cycle analysis deduplicates identical declarations" {
  let tasks = [
    WatchTaskContract::{
      name: "build",
      inputs: ["**/*"],
      outputs: ["dist/**", "dist/**"],
      writes_cache: false,
    },
  ]
  assert_eq(find_watch_cycles(tasks, None).length(), 1)
}

///|
test "watch cycle analysis honors watcher exclusions but keeps visible brace alternatives" {
  let excluded = [
    "_build/**", ".git/**", "node_modules/**", ".cache/**", "target/**",
  ]
  for output in excluded {
    let tasks = [
      WatchTaskContract::{
        name: "build",
        inputs: ["**/*"],
        outputs: [output],
        writes_cache: false,
      },
    ]
    assert_eq(find_watch_cycles(tasks, None).length(), 0)
  }
  let visible_alternative = [
    WatchTaskContract::{
      name: "build",
      inputs: ["**/*"],
      outputs: ["{_build,dist}/**"],
      writes_cache: false,
    },
  ]
  let cycles = find_watch_cycles(visible_alternative, None)
  assert_eq(cycles.length(), 1)
  assert_true(cycles[0].witness.has_prefix("dist"))
  let visible_character_alternative = [
    WatchTaskContract::{
      name: "build",
      inputs: ["**/*"],
      outputs: ["[.x]git/**"],
      writes_cache: false,
    },
  ]
  let character_cycles = find_watch_cycles(visible_character_alternative, None)
  assert_eq(character_cycles.length(), 1)
  assert_true(character_cycles[0].witness.has_prefix("xgit"))
}

///|
test "watch exclusions match path segments rather than filename prefixes" {
  assert_true(watch_cycle_path_excluded("_build"))
  assert_true(watch_cycle_path_excluded("pkg/_build/out"))
  assert_true(watch_cycle_path_excluded(".git/config"))
  assert_true(watch_cycle_path_excluded(".cache"))
  assert_true(watch_cycle_path_excluded("target"))
  assert_false(watch_cycle_path_excluded("_builder/source.mbt"))
  assert_false(watch_cycle_path_excluded(".gitignore"))
  assert_false(watch_cycle_path_excluded("pkg/targeted/source.mbt"))
}

///|
test "watch event paths are normalized to repo-relative form" {
  assert_eq(
    repo_relative_watch_path(
      "/workspace/project", "/workspace/project/src/main.mbt",
    ),
    Some("src/main.mbt"),
  )
  assert_eq(
    repo_relative_watch_path("/workspace/project", "/workspace/project"),
    Some(""),
  )
  assert_eq(
    repo_relative_watch_path("/workspace/project", "/workspace/other/file"),
    None,
  )
  assert_eq(
    repo_relative_watch_path("/workspace/project", "./src/main.mbt"),
    Some("src/main.mbt"),
  )
  assert_eq(
    repo_relative_watch_path(
      "/workspace/project/", "/workspace/project/src/../README.md",
    ),
    Some("README.md"),
  )
  assert_eq(
    repo_relative_watch_path("/workspace/project", "src/../README.md"),
    Some("README.md"),
  )
  assert_eq(repo_relative_watch_path("/workspace/project", "../outside"), None)
  assert_eq(
    repo_relative_watch_path("/workspace/project", "/workspace/project2/x"),
    None,
  )
  assert_eq(
    repo_relative_watch_path("/", "/src/main.mbt"),
    Some("src/main.mbt"),
  )
}

///|
test "task output regions are normalized once and include descendants" {
  let task = watch_test_task(
    "build",
    ["**/*"],
    ["dist", "generated/*.js", "already/**", "dist"],
    true,
    Some("packages/app/../web"),
    false,
  )
  assert_eq(task_watch_output_patterns("/repo", task), [
    "packages/web/dist/**", "packages/web/generated/*.js/**", "packages/web/already/**",
  ])
  let outside = watch_test_task(
    "outside",
    ["**/*"],
    ["/repository/dist"],
    false,
    None,
    false,
  )
  assert_eq(task_watch_output_patterns("/repo", outside), [])
}

///|
test "task root output means the whole watched repository" {
  let task = watch_test_task("build", ["**/*"], ["."], false, None, false)
  assert_eq(task_watch_output_patterns("/repo", task), ["**"])
  let plan = watch_test_plan([task])
  assert_eq(
    watch_cycles_for_plan(plan, "/repo", Map([], capacity=0)).length(),
    1,
  )
}

///|
test "workdir scopes both input and output regions for cycle analysis" {
  let task = watch_test_task(
    "build",
    ["dist/**"],
    ["dist"],
    false,
    Some("packages/app"),
    false,
  )
  let plan = watch_test_plan([task])
  assert_eq(task_watch_input_patterns("/repo", task), ["packages/app/dist/**"])
  let cycles = watch_cycles_for_plan(plan, "/repo", Map([], capacity=0))
  assert_eq(cycles.length(), 1)
  assert_eq(cycles[0].witness, "packages/app/dist")
  let (direct, affected) = compute_affected(
    plan,
    ["packages/app/dist/app.js"],
    "/repo",
  )
  assert_eq(direct, ["build"])
  assert_eq(affected, ["build"])
  let (root_direct, _) = compute_affected(plan, ["dist/app.js"], "/repo")
  assert_eq(root_direct, [])
}

///|
test "watch plan respects task scope and skips services" {
  let a = watch_test_task("a", ["a/**"], ["a"], false, None, false)
  let b = watch_test_task("b", ["b/**"], ["b"], false, None, false)
  let service = watch_test_task(
    "service",
    ["service/**"],
    ["service"],
    false,
    None,
    true,
  )
  let plan = watch_test_plan([a, b, service])
  assert_eq(
    watch_cycles_for_plan(plan, "/repo", Map([], capacity=0)).length(),
    2,
  )
  let scope : Map[String, Bool] = Map([], capacity=1)
  scope["a"] = true
  let scoped = watch_cycles_for_plan(plan, "/repo", scope)
  assert_eq(scoped.length(), 1)
  assert_eq(scoped[0].tasks, ["a"])
}

///|
test "cache region is only modeled when it is visible inside the repository" {
  let previous = @env.get_env_var("PKFIRE_MBT_CACHE_DIR")
  @env.set_env_var("PKFIRE_MBT_CACHE_DIR", "/repo/.pkf-cache")
  assert_eq(watch_cache_pattern("/repo"), Some(".pkf-cache/cas/**"))
  @env.set_env_var("PKFIRE_MBT_CACHE_DIR", "/repo/.cache/pkf")
  assert_eq(watch_cache_pattern("/repo"), None)
  @env.set_env_var("PKFIRE_MBT_CACHE_DIR", "/repository/cache")
  assert_eq(watch_cache_pattern("/repo"), None)
  @env.set_env_var("PKFIRE_MBT_CACHE_DIR", "/repo")
  assert_eq(watch_cache_pattern("/repo"), Some("cas/**"))
  match previous {
    Some(value) => @env.set_env_var("PKFIRE_MBT_CACHE_DIR", value)
    None => @env.unset_env_var("PKFIRE_MBT_CACHE_DIR")
  }
}

///|
test "cache outputs declared in workdir are archived repo-relative" {
  let repo = "/tmp/pkf-workdir-output-test"
  rm_rf(repo)
  mkdir_p(repo + "/packages/app/dist")
  @fs.write_string_to_file(repo + "/packages/app/dist/app.js", "generated") catch {
    _ => fail("could not write workdir output fixture")
  }
  let outputs = resolved_task_outputs(repo, repo + "/packages/app", ["dist"])
  assert_eq(outputs, ["packages/app/dist"])
  rm_rf(repo)
}
