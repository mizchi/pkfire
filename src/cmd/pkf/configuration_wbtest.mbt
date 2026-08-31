// Tests for configuration transitions.
//
// The bug this fixes was silent: a cross build's dependencies were
// resolved and keyed for the host, so two different cross builds shared
// one entry for a shared library. Nothing in the output said so. What
// is pinned here is the propagation itself and every rule about when it
// stops — an over-eager transition would make `targetPlatform` unusable
// under a `ci` umbrella, and a missing one puts the bug back.

///|
fn cfg_task(
  name : String,
  inputs : Array[String],
  outputs : Array[String],
  deps : Array[String],
  platform : String?,
  settings~ : Array[(String, String)] = [],
) -> Task {
  let config : Map[String, String] = Map([], capacity=settings.length())
  for pair in settings {
    config[pair.0] = pair.1
  }
  {
    ..graph_test_task(name, inputs, outputs, deps, None),
    target_platform: platform,
    config,
  }
}

///|
fn platform_of(
  tasks : Array[Task],
  targets : Array[String],
  name : String,
) -> String {
  let plan = graph_test_plan(tasks)
  let graph = build_action_graph(plan, ".", targets)
  let (configs, _) = resolve_configurations(plan, graph)
  config_of(configs, name).target_platform
}

///|
/// The build settings `name` is built with, as `key=value` strings.
fn settings_of(
  tasks : Array[Task],
  targets : Array[String],
  name : String,
  seed~ : Array[(String, String)] = [],
) -> Array[String] {
  let plan = graph_test_plan(tasks)
  let graph = build_action_graph(plan, ".", targets)
  let seed_map : Map[String, String] = Map([], capacity=seed.length())
  for pair in seed {
    seed_map[pair.0] = pair.1
  }
  let (configs, _) = resolve_configurations(
    plan,
    graph,
    seed=config_with_settings("", seed_map),
  )
  let out : Array[String] = []
  for pair in config_of(configs, name).settings {
    out.push(pair.0 + "=" + pair.1)
  }
  out
}

///|
fn conflict_of(
  tasks : Array[Task],
  targets : Array[String],
) -> ConfigConflict? {
  let plan = graph_test_plan(tasks)
  let graph = build_action_graph(plan, ".", targets)
  resolve_configurations(plan, graph).1
}

///|
test "a dependency of a cross build is built for the same target" {
  // The bug. `lib` is part of the arm64 build, so keying it for the
  // host both shares an entry with a host build that used a different
  // compiler and misses the arm64 build that should hit.
  let lib = cfg_task("lib", ["src/**"], [], [], None)
  let app = cfg_task("app", [], [], ["lib"], Some("linux/arm64"))
  assert_eq(platform_of([lib, app], ["app"], "lib"), "linux/arm64")
  assert_eq(platform_of([lib, app], ["app"], "app"), "linux/arm64")
}

///|
test "the transition follows artifact edges, not just declared deps" {
  // A consumer that never named its producer in `deps` still gets the
  // edge from what it reads, so it has to transition it too — otherwise
  // whether the configuration propagates would depend on how the author
  // happened to spell the dependency.
  //
  // Both are named on the command line because an artifact edge orders
  // a producer already in the run set; it does not pull one in. That is
  // the existing contract (see the `artifact-order` scenario), not
  // something transitions change.
  let gen = cfg_task("gen", ["src/**"], ["dist/out.txt"], [], None)
  let app = cfg_task("app", ["dist/out.txt"], [], [], Some("linux/arm64"))
  assert_eq(platform_of([gen, app], ["gen", "app"], "gen"), "linux/arm64")
}

///|
test "the transition reaches all the way down" {
  // Two hops. A transition that stopped at the first dependency would
  // leave the rest of the subtree keyed for the host.
  let base = cfg_task("base", ["src/**"], [], [], None)
  let mid = cfg_task("mid", [], [], ["base"], None)
  let app = cfg_task("app", [], [], ["mid"], Some("linux/arm64"))
  assert_eq(platform_of([base, mid, app], ["app"], "mid"), "linux/arm64")
  assert_eq(platform_of([base, mid, app], ["app"], "base"), "linux/arm64")
}

///|
test "a task that declares its own platform is not transitioned" {
  // The host-tool-inside-a-cross-build case: a code generator has to
  // run where the build runs, whatever the thing being built targets.
  let codegen = cfg_task("codegen", ["src/**"], [], [], Some("linux/amd64"))
  let app = cfg_task("app", [], [], ["codegen"], Some("linux/arm64"))
  assert_eq(platform_of([codegen, app], ["app"], "codegen"), "linux/amd64")
}

///|
test "a task below a pinned one inherits the pin, not the grandparent" {
  // The transition is re-originated by the pin, so everything under the
  // host tool is built for the host tool's platform.
  let helper = cfg_task("helper", ["src/**"], [], [], None)
  let codegen = cfg_task("codegen", [], [], ["helper"], Some("linux/amd64"))
  let app = cfg_task("app", [], [], ["codegen"], Some("linux/arm64"))
  assert_eq(platform_of([helper, codegen, app], ["app"], "helper"), "linux/amd64")
}

///|
test "a task with nothing above it is built for the execution platform" {
  let lib = cfg_task("lib", ["src/**"], [], [], None)
  assert_eq(platform_of([lib], ["lib"], "lib"), "")
}

///|
test "a task with no platform passes no opinion down" {
  // The shape most Taskfiles have: a `ci` umbrella over a host task and
  // a cross task that share a library. If an undeclared task propagated
  // the execution platform, `ci` would force it onto `lib` and collide
  // with `app` — and `targetPlatform` would be unusable in any repo
  // whose entry point is an umbrella.
  let lib = cfg_task("lib", ["src/**"], ["dist/lib.txt"], [], None)
  let test_ = cfg_task("test", ["dist/lib.txt"], [], ["lib"], None)
  let app = cfg_task("app", ["dist/lib.txt"], [], ["lib"], Some("linux/arm64"))
  let ci = cfg_task("ci", [], [], ["test", "app"], None)
  let tasks = [lib, test_, app, ci]
  assert_true(conflict_of(tasks, ["ci"]) is None)
  assert_eq(platform_of(tasks, ["ci"], "lib"), "linux/arm64")
  assert_eq(platform_of(tasks, ["ci"], "test"), "")
}

///|
test "one task wanted for two targets in one run is a conflict" {
  // There is one `dist/lib.txt`. Building it once and handing it to
  // both is what happened before, and it is wrong for one of them; a
  // per-configuration output root is what would make this legal.
  let lib = cfg_task("lib", ["src/**"], ["dist/lib.txt"], [], None)
  let arm = cfg_task("arm", ["dist/lib.txt"], [], ["lib"], Some("linux/arm64"))
  let amd = cfg_task("amd", ["dist/lib.txt"], [], ["lib"], Some("linux/amd64"))
  match conflict_of([lib, arm, amd], ["arm", "amd"]) {
    Some(c) => {
      assert_eq(c.task, "lib")
      // Both origins are named, because "conflicting platforms" without
      // the two tasks that wanted them is not an actionable message.
      let origins = [c.first.origin, c.second.origin]
      origins.sort()
      assert_eq(origins, ["amd", "arm"])
    }
    None => fail("the two targets did not conflict")
  }
}

///|
test "each half of a conflict is fine on its own" {
  // The refusal is about one run, not about the Taskfile. Running them
  // separately is the workaround the message suggests, so it has to
  // work.
  let lib = cfg_task("lib", ["src/**"], ["dist/lib.txt"], [], None)
  let arm = cfg_task("arm", ["dist/lib.txt"], [], ["lib"], Some("linux/arm64"))
  let amd = cfg_task("amd", ["dist/lib.txt"], [], ["lib"], Some("linux/amd64"))
  let tasks = [lib, arm, amd]
  assert_true(conflict_of(tasks, ["arm"]) is None)
  assert_true(conflict_of(tasks, ["amd"]) is None)
  assert_eq(platform_of(tasks, ["arm"], "lib"), "linux/arm64")
  assert_eq(platform_of(tasks, ["amd"], "lib"), "linux/amd64")
}

///|
test "a shared task pinning itself resolves the conflict" {
  // The other workaround the message names.
  let lib = cfg_task("lib", ["src/**"], ["dist/lib.txt"], [], Some("linux/amd64"))
  let arm = cfg_task("arm", ["dist/lib.txt"], [], ["lib"], Some("linux/arm64"))
  let amd = cfg_task("amd", ["dist/lib.txt"], [], ["lib"], Some("linux/amd64"))
  let tasks = [lib, arm, amd]
  assert_true(conflict_of(tasks, ["arm", "amd"]) is None)
  assert_eq(platform_of(tasks, ["arm", "amd"], "lib"), "linux/amd64")
}

///|
test "two consumers wanting the same target do not conflict" {
  let lib = cfg_task("lib", ["src/**"], ["dist/lib.txt"], [], None)
  let a = cfg_task("a", ["dist/lib.txt"], [], ["lib"], Some("linux/arm64"))
  let b = cfg_task("b", ["dist/lib.txt"], [], ["lib"], Some("linux/arm64"))
  assert_true(conflict_of([lib, a, b], ["a", "b"]) is None)
  assert_eq(platform_of([lib, a, b], ["a", "b"], "lib"), "linux/arm64")
}

///|
test "the conflict message names both platforms and both origins" {
  let conflict = ConfigConflict::{
    task: "lib",
    first: ConfigReach::{
      config: config_with_settings("linux/arm64", Map([], capacity=0)),
      origin: "arm-app",
    },
    second: ConfigReach::{ config: Configuration::host(), origin: "host-app" },
  }
  let message = config_conflict_message(conflict)
  assert_true(message.contains("`lib`"))
  assert_true(message.contains("linux/arm64"))
  assert_true(message.contains("`arm-app`"))
  assert_true(message.contains("`host-app`"))
  // And what to do about it, since neither workaround is guessable from
  // the names alone.
  assert_true(message.contains("targetPlatform"))
}

///|
test "an unresolved task falls back to its own declaration" {
  // `describe` and the other callers with no run set have no consumers
  // to inherit from; reading the declaration is what they did before
  // transitions existed and must keep doing.
  let cross = cfg_task("cross", [], [], [], Some("linux/arm64"))
  assert_eq(
    config_or_declared(None, cross).target_platform,
    "linux/arm64",
  )
  // A resolved one wins over the declaration.
  assert_eq(
    config_or_declared(Some(Configuration::host()), cross).target_platform,
    "",
  )
}

///|
test "a build setting reaches everything under the task that declared it" {
  // The point of the feature: "build this subtree in release mode"
  // without duplicating every task or repeating the setting on each.
  let lib = cfg_task("lib", ["src/**"], [], [], None)
  let app = cfg_task(
    "app", [], [], ["lib"], None, settings=[("mode", "release")],
  )
  assert_eq(settings_of([lib, app], ["app"], "lib"), ["mode=release"])
  assert_eq(settings_of([lib, app], ["app"], "app"), ["mode=release"])
  // And not to a task nobody asked for it on.
  assert_eq(settings_of([lib, app], ["lib"], "lib"), [])
}

///|
test "settings merge per key rather than replacing wholesale" {
  // A host tool pinning the one setting it cares about must not lose
  // the rest; making a declaration replace the whole map would force
  // every pinned task to restate settings it has no opinion about.
  let helper = cfg_task("helper", ["src/**"], [], [], None)
  let codegen = cfg_task(
    "codegen", [], [], ["helper"], None, settings=[("mode", "debug")],
  )
  let app = cfg_task(
    "app",
    [],
    [],
    ["codegen"],
    None,
    settings=[("mode", "release"), ("lto", "on")],
  )
  let tasks = [helper, codegen, app]
  // `codegen` overrides `mode` and keeps `lto`.
  assert_eq(settings_of(tasks, ["app"], "codegen"), ["lto=on", "mode=debug"])
  // And its own dependency inherits the merged result.
  assert_eq(settings_of(tasks, ["app"], "helper"), ["lto=on", "mode=debug"])
}

///|
test "settings are sorted, so authoring order cannot move a key" {
  // They reach the action key; a configuration that hashed differently
  // depending on how the Pkl mapping was written would miss every time.
  let app = cfg_task(
    "app", ["src/**"], [], [], None, settings=[("z", "1"), ("a", "2")],
  )
  assert_eq(settings_of([app], ["app"], "app"), ["a=2", "z=1"])
}

///|
test "a platform and a setting travel together" {
  let lib = cfg_task("lib", ["src/**"], [], [], None)
  let app = cfg_task(
    "app",
    [],
    [],
    ["lib"],
    Some("linux/arm64"),
    settings=[("mode", "release")],
  )
  assert_eq(platform_of([lib, app], ["app"], "lib"), "linux/arm64")
  assert_eq(settings_of([lib, app], ["app"], "lib"), ["mode=release"])
}

///|
test "a declared platform replaces the inherited one, settings still merge" {
  // The two halves behave differently on purpose: a host tool inside a
  // cross build is not building for arm64 in any sense, but it is still
  // part of a release build unless it says otherwise.
  let codegen = cfg_task("codegen", ["src/**"], [], [], Some("linux/amd64"))
  let app = cfg_task(
    "app",
    [],
    [],
    ["codegen"],
    Some("linux/arm64"),
    settings=[("mode", "release")],
  )
  assert_eq(platform_of([codegen, app], ["app"], "codegen"), "linux/amd64")
  assert_eq(settings_of([codegen, app], ["app"], "codegen"), ["mode=release"])
}

///|
test "the run seed reaches every target and its dependencies" {
  // `--config mode=release` with no task declaring anything.
  let lib = cfg_task("lib", ["src/**"], [], [], None)
  let app = cfg_task("app", [], [], ["lib"], None)
  assert_eq(
    settings_of([lib, app], ["app"], "lib", seed=[("mode", "release")]),
    ["mode=release"],
  )
}

///|
test "a task's own setting wins over the run seed" {
  // Pinning has to mean something from the outside too, or a host tool
  // would be swept into whatever the command line asked for.
  let codegen = cfg_task(
    "codegen", ["src/**"], [], [], None, settings=[("mode", "debug")],
  )
  let app = cfg_task("app", [], [], ["codegen"], None)
  assert_eq(
    settings_of([codegen, app], ["app"], "codegen", seed=[("mode", "release")]),
    ["mode=debug"],
  )
  // Everything it does not name still comes from the seed.
  assert_eq(
    settings_of(
      [codegen, app],
      ["app"],
      "codegen",
      seed=[("mode", "release"), ("lto", "on")],
    ),
    ["lto=on", "mode=debug"],
  )
}

///|
test "two settings disagreeing on one task is a conflict" {
  let lib = cfg_task("lib", ["src/**"], ["dist/lib.txt"], [], None)
  let rel = cfg_task(
    "rel", ["dist/lib.txt"], [], ["lib"], None, settings=[("mode", "release")],
  )
  let dbg = cfg_task(
    "dbg", ["dist/lib.txt"], [], ["lib"], None, settings=[("mode", "debug")],
  )
  match conflict_of([lib, rel, dbg], ["rel", "dbg"]) {
    Some(c) => assert_eq(c.task, "lib")
    None => fail("two settings did not conflict")
  }
}

///|
test "a task pinning the disputed setting resolves the conflict" {
  // The producer is compared after its own declarations are applied, so
  // two consumers disagreeing about something it pins is not a
  // disagreement about anything.
  let lib = cfg_task(
    "lib", ["src/**"], ["dist/lib.txt"], [], None, settings=[("mode", "fixed")],
  )
  let rel = cfg_task(
    "rel", ["dist/lib.txt"], [], ["lib"], None, settings=[("mode", "release")],
  )
  let dbg = cfg_task(
    "dbg", ["dist/lib.txt"], [], ["lib"], None, settings=[("mode", "debug")],
  )
  let tasks = [lib, rel, dbg]
  assert_true(conflict_of(tasks, ["rel", "dbg"]) is None)
  assert_eq(settings_of(tasks, ["rel", "dbg"], "lib"), ["mode=fixed"])
}

///|
test "consumers agreeing on a setting do not conflict" {
  let lib = cfg_task("lib", ["src/**"], ["dist/lib.txt"], [], None)
  let a = cfg_task(
    "a", ["dist/lib.txt"], [], ["lib"], None, settings=[("mode", "release")],
  )
  let b = cfg_task(
    "b", ["dist/lib.txt"], [], ["lib"], None, settings=[("mode", "release")],
  )
  assert_true(conflict_of([lib, a, b], ["a", "b"]) is None)
}

///|
test "the conflict message names only what differs" {
  // Two configurations sharing three settings and differing on one: the
  // reader should not have to diff two rendered configurations by eye.
  let first = config_with_settings("", Map([("lto", "on"), ("mode", "debug")]))
  let second = config_with_settings(
    "", Map([("lto", "on"), ("mode", "release")]),
  )
  let diffs = config_differences(first, second)
  assert_eq(diffs, ["mode: debug vs release"])
  let message = config_conflict_message(ConfigConflict::{
    task: "lib",
    first: ConfigReach::{ config: first, origin: "dbg" },
    second: ConfigReach::{ config: second, origin: "rel" },
  })
  assert_true(message.contains("mode: debug vs release"))
  // Named for what it is: nothing here is about a target platform, and
  // saying so would send the reader to the wrong field.
  assert_true(message.contains("two build configurations"))
  assert_true(message.contains("its own `config`"))
}

///|
test "a setting present on one side only is a difference" {
  let first = config_with_settings("", Map([("mode", "release")]))
  let second = config_with_settings("", Map([]))
  assert_eq(config_differences(first, second), ["mode: release vs (unset)"])
}

///|
test "a build setting reaches the command under a prefixed name" {
  // Prefixed so it cannot shadow a param (`$MODE`) or an `env` entry.
  assert_eq(config_env_name("mode"), "PKF_CONFIG_MODE")
  assert_eq(config_env_name("opt_level"), "PKF_CONFIG_OPT_LEVEL")
}
