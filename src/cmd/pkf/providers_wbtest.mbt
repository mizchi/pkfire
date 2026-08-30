// Tests for provider resolution.
//
// The parts worth pinning are the ones whose wrong answer still looks
// like a working build: a path re-rooted one directory too far still
// resolves *somewhere*, an env ordering that depends on Pkl's mapping
// iteration gives two machines two keys for the same action, and a
// provider that reaches two hops puts a variable in front of a command
// that never asked for it. The end-to-end behaviour is covered by the
// `provider-executable` and `provider-env` conformance scenarios.

///|
fn provider_task(
  name : String,
  outputs : Array[String],
  deps : Array[String],
  workdir : String?,
  provides : Providers,
) -> Task {
  { ..graph_test_task(name, [], outputs, deps, workdir), provides, }
}

///|
fn exec_provider(path : String) -> Providers {
  Providers::{ executable: path, env: Map([], capacity=0) }
}

///|
test "a provider reaches the tasks that declare the producer" {
  let build = provider_task(
    "build", ["dist/cli"], [], None, exec_provider("dist/cli"),
  )
  let smoke = provider_task("smoke", [], ["build"], None, Providers::empty())
  let plan = graph_test_plan([build, smoke])
  let values = provided_values(plan, ".", smoke)
  assert_eq(values.length(), 1)
  assert_eq(values[0].name, "PKF_BUILD_EXECUTABLE")
  assert_eq(values[0].value, "dist/cli")
  assert_eq(values[0].producer, "build")
  assert_eq(values[0].kind, "executable")
  // A producer that declares nothing leaves `deps` exactly as it was.
  assert_eq(provided_values(plan, ".", build).length(), 0)
}

///|
test "a provider does not travel a second hop" {
  // `far` never names `build`. Injecting `$PKF_BUILD_EXECUTABLE` into
  // its environment because something in between depends on it would
  // be a variable appearing from a file its author never read.
  let build = provider_task(
    "build", ["dist/cli"], [], None, exec_provider("dist/cli"),
  )
  let mid = provider_task("mid", [], ["build"], None, Providers::empty())
  let far = provider_task("far", [], ["mid"], None, Providers::empty())
  let plan = graph_test_plan([build, mid, far])
  assert_eq(provided_values(plan, ".", far).length(), 0)
  assert_eq(provided_values(plan, ".", mid).length(), 1)
}

///|
test "an executable is re-rooted into the consumer's working directory" {
  // The producer says `target/release/cli` relative to `crates/cli`.
  // From `apps/web` that path does not exist; the consumer needs the
  // walk between the two, which is the thing nobody writes by hand.
  let build = provider_task(
    "build",
    ["target/release/cli"],
    [],
    Some("crates/cli"),
    exec_provider("target/release/cli"),
  )
  let smoke = provider_task(
    "smoke", [], ["build"], Some("apps/web"), Providers::empty(),
  )
  let plan = graph_test_plan([build, smoke])
  let values = provided_values(plan, "/repo", smoke)
  assert_eq(values[0].value, "../../crates/cli/target/release/cli")
}

///|
test "a shared root leaves the declared path alone" {
  let build = provider_task(
    "build", ["dist/cli"], [], Some("pkg"), exec_provider("dist/cli"),
  )
  let smoke = provider_task(
    "smoke", [], ["build"], Some("pkg"), Providers::empty(),
  )
  let plan = graph_test_plan([build, smoke])
  assert_eq(provided_values(plan, "/repo", smoke)[0].value, "dist/cli")
}

///|
test "re-rooting walks up and down without touching the repo prefix" {
  // The shared prefix cancels, which is what makes the result the same
  // on every checkout — and therefore safe to hash into the key.
  assert_eq(reroot_path("/r/a", "/r/b", "out.txt"), "../a/out.txt")
  assert_eq(reroot_path("/r/a/b", "/r", "out.txt"), "a/b/out.txt")
  assert_eq(reroot_path("/r", "/r/a/b", "out.txt"), "../../out.txt")
  assert_eq(reroot_path("/r/a", "/r/a", "out.txt"), "out.txt")
  // A trailing slash or a `.` segment must not count as a level.
  assert_eq(reroot_path("/r/a/", "/r/./b", "out.txt"), "../a/out.txt")
}

///|
test "env providers are ordered by name, not by mapping order" {
  // They land in the action key through the merged env overlay. If the
  // order came from Pkl's mapping iteration, two evaluations of the
  // same Taskfile could key differently.
  let env = Map([("ZED", "1"), ("ALPHA", "2"), ("MID", "3")])
  let build = provider_task(
    "build", [], [], None, Providers::{ executable: "", env },
  )
  let use_it = provider_task("use", [], ["build"], None, Providers::empty())
  let plan = graph_test_plan([build, use_it])
  let names : Array[String] = []
  for value in provided_values(plan, ".", use_it) {
    names.push(value.name)
  }
  assert_eq(names, ["ALPHA", "MID", "ZED"])
}

///|
test "a task name becomes a variable name a shell will accept" {
  assert_eq(provider_env_name("build", "EXECUTABLE"), "PKF_BUILD_EXECUTABLE")
  assert_eq(provider_env_name("test:unit", "EXECUTABLE"), "PKF_TEST_UNIT_EXECUTABLE")
  assert_eq(provider_env_name("build-cli", "EXECUTABLE"), "PKF_BUILD_CLI_EXECUTABLE")
  assert_eq(provider_env_name("a/b.c", "EXECUTABLE"), "PKF_A_B_C_EXECUTABLE")
}

///|
test "a provider value reaches the action key" {
  // A provider the command can read and the key cannot see is how a
  // cache goes stale; this is the assertion that it is visible.
  let build = provider_task(
    "build",
    ["dist/cli"],
    [],
    None,
    Providers::{ executable: "dist/cli", env: Map([("API", "v1")]) },
  )
  let smoke = provider_task("smoke", [], ["build"], None, Providers::empty())
  let plan = graph_test_plan([build, smoke])
  // No toolchains declared, so nothing to resolve. The parameter is
  // required rather than defaulted: a caller that silently passed
  // nothing would compute a key the runner does not.
  let described = describe_action(
    action_for_task(
      plan, smoke, ".", Map([]), [], RunOptions::default(), toolchains=[],
    ),
  )
  assert_true(described.contains("PKF_BUILD_EXECUTABLE=dist/cli"))
  assert_true(described.contains("API=v1"))
}

///|
test "a task's own env beats a provider it merely depends on" {
  let build = provider_task(
    "build",
    [],
    [],
    None,
    Providers::{ executable: "", env: Map([("API", "from-provider")]) },
  )
  let smoke = {
    ..provider_task("smoke", [], ["build"], None, Providers::empty()),
    env: Map([("API", "from-task")]),
  }
  let plan = graph_test_plan([build, smoke])
  // No toolchains declared, so nothing to resolve. The parameter is
  // required rather than defaulted: a caller that silently passed
  // nothing would compute a key the runner does not.
  let described = describe_action(
    action_for_task(
      plan, smoke, ".", Map([]), [], RunOptions::default(), toolchains=[],
    ),
  )
  assert_true(described.contains("API=from-task"))
  assert_false(described.contains("API=from-provider"))
}

///|
test "an executable no output produces is refused" {
  // The path would be handed to a dependent, so the failure would be
  // reported against the wrong task — and only at run time.
  let good = provider_task(
    "good", ["dist/**"], [], None, exec_provider("dist/cli"),
  )
  assert_true(provider_declaration_error(good) is None)
  let bad = provider_task(
    "bad", ["lib/**"], [], None, exec_provider("dist/cli"),
  )
  assert_true(provider_declaration_error(bad) is Some(_))
  // A deps-only umbrella produces nothing at all.
  let umbrella = {
    ..provider_task("all", [], [], None, exec_provider("dist/cli")),
    cmd: "",
  }
  assert_true(provider_declaration_error(umbrella) is Some(_))
  // Declaring nothing is always fine.
  assert_true(
    provider_declaration_error(
      provider_task("plain", [], [], None, Providers::empty()),
    )
    is None,
  )
}
