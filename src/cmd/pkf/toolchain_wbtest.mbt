// Tests for toolchain resolution and the target platform.
//
// Resolution itself spawns subprocesses and is covered end to end by
// the `toolchains` CI smoke step, where a tool is upgraded in place and
// the key has to move. What is worth pinning here is the parsing and
// the key plumbing: a version line taken wrong puts a build timestamp
// in the key, and a field that never reaches the descriptor makes the
// whole feature a no-op that still looks like it works.

///|
test "the version is the first non-empty line, trimmed" {
  // Version commands are chatty. Taking all of the output would put a
  // banner, a plugin list, or a build timestamp into the key.
  assert_eq(first_line("go version go1.26.2 darwin/arm64\n"), "go version go1.26.2 darwin/arm64")
  assert_eq(first_line("\n\n  rustc 1.88.0  \nextra\n"), "rustc 1.88.0")
  assert_eq(first_line(""), "")
  assert_eq(first_line("\n \t \n"), "")
}

///|
test "trimming leaves interior spacing alone" {
  assert_eq(trim_ascii("  go version 1.2  "), "go version 1.2")
  assert_eq(trim_ascii("\t\r\nx\n\r\t"), "x")
  assert_eq(trim_ascii(""), "")
  assert_eq(trim_ascii("   "), "")
  assert_eq(trim_ascii("no-padding"), "no-padding")
}

///|
test "a tool name reaches the shell as one word, whatever it contains" {
  // The name goes into `command -v <name>`. A name with a space or a
  // quote in it would otherwise become two words, or end the string.
  assert_eq(shell_quote("go"), "'go'")
  assert_eq(shell_quote("/opt/my tools/go"), "'/opt/my tools/go'")
  assert_eq(shell_quote("it's"), "'it'\\''s'")
}

///|
fn bare_toolchain(name : String) -> Toolchain {
  Toolchain::{
    name,
    version_cmd: "",
    hash_binary: false,
    optional: false,
    for_target: Map([], capacity=0),
  }
}

///|
test "the default version command follows the selection" {
  let bare = bare_toolchain("go")
  assert_eq(toolchain_version_command(bare, "go"), "go --version")
  // A `cc` that resolved to a cross compiler must be asked *its*
  // version, not the host compiler's.
  assert_eq(
    toolchain_version_command(bare_toolchain("cc"), "aarch64-linux-gnu-gcc"),
    "aarch64-linux-gnu-gcc --version",
  )
  // An explicit command is taken literally: the author said what to run.
  assert_eq(
    toolchain_version_command({ ..bare, version_cmd: "go env GOVERSION" }, "go"),
    "go env GOVERSION",
  )
}

///|
test "the target platform selects which executable is resolved" {
  let cc = {
    ..bare_toolchain("cc"),
    for_target: Map([
      ("linux/arm64", "aarch64-linux-gnu-gcc"),
      ("linux/amd64", "x86_64-linux-gnu-gcc"),
    ]),
  }
  assert_eq(toolchain_executable(cc, "linux/arm64"), "aarch64-linux-gnu-gcc")
  assert_eq(toolchain_executable(cc, "linux/amd64"), "x86_64-linux-gnu-gcc")
  // No target, or one with no entry, falls back to the declared name —
  // a native build needs no special case, and an unrecognised target
  // degrades to the host compiler rather than to an error.
  assert_eq(toolchain_executable(cc, ""), "cc")
  assert_eq(toolchain_executable(cc, "windows/arm64"), "cc")
  assert_eq(toolchain_executable(bare_toolchain("go"), "linux/arm64"), "go")
}

///|
test "memoization distinguishes declarations that resolve differently" {
  // Two tasks naming `go` share one resolution; one that also asks for
  // a binary digest must not reuse the answer that has none.
  let plain = bare_toolchain("go")
  assert_eq(
    toolchain_memo_key(plain, ""),
    toolchain_memo_key({ ..plain, optional: true }, ""),
  )
  assert_true(
    toolchain_memo_key(plain, "") !=
    toolchain_memo_key({ ..plain, hash_binary: true }, ""),
  )
  assert_true(
    toolchain_memo_key(plain, "") !=
    toolchain_memo_key({ ..plain, version_cmd: "go env GOVERSION" }, ""),
  )
  assert_true(
    toolchain_memo_key(plain, "") != toolchain_memo_key(bare_toolchain("rustc"), ""),
  )
  // One `cc` declaration resolving to two compilers must not share a
  // memo slot, or the second target is handed the first's version.
  let cc = {
    ..bare_toolchain("cc"),
    for_target: Map([("linux/arm64", "aarch64-linux-gnu-gcc")]),
  }
  assert_true(
    toolchain_memo_key(cc, "linux/arm64") != toolchain_memo_key(cc, ""),
  )
  // A target the declaration says nothing about resolves to the same
  // executable as no target at all, so it may share the slot.
  assert_eq(toolchain_memo_key(cc, "windows/amd64"), toolchain_memo_key(cc, ""))
}

///|
fn key_with_toolchains(
  task : Task,
  plan : Plan,
  toolchains : Array[(String, String)],
) -> String {
  action_key_of(
    action_for_task(
      plan, task, ".", Map([]), [], RunOptions::default(), toolchains~,
    ),
  )
}

///|
test "resolved toolchain facts reach the action key" {
  // The point of resolving is that the answer is hashed. A field that
  // stopped short of the descriptor would leave the feature a no-op
  // that still printed the right thing in `explain`.
  let task = graph_test_task("t", ["src/**"], [], [], None)
  let plan = graph_test_plan([task])
  let before = key_with_toolchains(task, plan, [("toolchain.go.version", "go1.26.2")])
  let after = key_with_toolchains(task, plan, [("toolchain.go.version", "go1.27.0")])
  assert_true(before != after)
  // Absent is a fact too: a run that went ahead without an optional
  // tool did something different from one that had it.
  assert_true(key_with_toolchains(task, plan, [("toolchain.go", "absent")]) != before)
  let none : Array[(String, String)] = []
  assert_true(key_with_toolchains(task, plan, none) != before)
}

///|
test "the target platform is distinct from the platform running the action" {
  // Two cross-compiles issuing the same command on the same machine,
  // differing only in where the result is meant to run.
  let host = graph_test_task("build", ["src/**"], [], [], None)
  let cross = { ..host, target_platform: Some("linux/arm64") }
  let plan = graph_test_plan([host])
  let none : Array[(String, String)] = []
  assert_true(key_with_toolchains(host, plan, none) != key_with_toolchains(cross, plan, none))
  // And it is reported, so a miss is explicable.
  let described = describe_action(
    action_for_task(
      plan, cross, ".", Map([]), [], RunOptions::default(), toolchains=[],
    ),
  )
  assert_true(described.contains("target:     linux/arm64"))
  // An ordinary task builds for the machine it runs on and says
  // nothing extra.
  assert_false(
    describe_action(
      action_for_task(
        plan, host, ".", Map([]), [], RunOptions::default(), toolchains=[],
      ),
    ).contains("target:"),
  )
}

///|
test "a resolved toolchain and a self-reported `tools` entry do not collide" {
  // `tools` is what the Taskfile claims; `toolchains` is what the
  // runner found. They coexist under different property prefixes, so
  // declaring both does not have one silently overwrite the other.
  let task = {
    ..graph_test_task("t", ["src/**"], [], [], None),
    tools: Map([("go", "1.26.2")]),
  }
  let plan = graph_test_plan([task])
  let described = describe_action(
    action_for_task(
      plan,
      task,
      ".",
      Map([]),
      [],
      RunOptions::default(),
      toolchains=[("toolchain.go.version", "go1.26.2")],
    ),
  )
  assert_true(described.contains("tool.go=1.26.2"))
  assert_true(described.contains("toolchain.go.version=go1.26.2"))
}
