// Tests for the sandbox's directory layout.
//
// The rest of the executor is I/O whose failure modes are filesystem
// failures, and it is covered end to end by the `sandbox-undeclared-read`
// and `sandbox-undeclared-write` conformance scenarios. What is worth
// pinning here is which directory the sandbox mirrors, because getting
// it wrong is silent: the command runs, finds nothing where it expected
// its inputs, and fails for a reason that looks like the sandbox
// working.

///|
/// Run `body` with the cache root — and therefore the sandbox base —
/// pointed at a scratch directory.
fn with_sandbox_cache(dir : String, body : () -> Unit raise) -> Unit raise {
  let previous = @env.get_env_var("PKFIRE_MBT_CACHE_DIR")
  @env.set_env_var("PKFIRE_MBT_CACHE_DIR", dir)
  body()
  match previous {
    Some(v) => @env.set_env_var("PKFIRE_MBT_CACHE_DIR", v)
    // No unset in the env API; an empty value falls through to
    // XDG_CACHE_HOME / HOME the same way an absent one does not, so
    // restore something harmless and scoped to this process.
    None => @env.set_env_var("PKFIRE_MBT_CACHE_DIR", dir)
  }
}

///|
/// Suffix check that tolerates the absolute prefix the sandbox base
/// carries, which depends on where the test process is running.
fn ends_with_path(path : String, suffix : String) -> Bool {
  path == suffix || path.has_suffix("/" + suffix)
}

///|
test "a task inside the repo runs in the mirrored subdirectory" {
  let scratch = "_build/sandbox-test-inside"
  rm_rf(scratch)
  with_sandbox_cache(scratch, () => {
    let box = sandbox_create(".", "./js").unwrap()
    // The command runs where its own root is; artifacts, which are
    // repo-relative, land at the sandbox root.
    assert_true(ends_with_path(box.cwd, "js"))
    assert_eq(box.artifact_root, box.root)
    assert_true(box.cwd.has_prefix(box.root))
    assert_true(@fs.path_exists(box.cwd))
    sandbox_destroy(box)
    assert_false(@fs.path_exists(box.root))
  })
  rm_rf(scratch)
}

///|
test "a task root above the repo root still gets a sandbox" {
  // A Taskfile in a subdirectory with `workdir = ".."` — how a
  // repository dogfoods its own runner — has a task root *above* the
  // Taskfile's directory. Rooting the sandbox at the Taskfile dir
  // would leave nowhere to put the working directory, and the whole
  // pattern would silently run unsandboxed.
  let scratch = "_build/sandbox-test-above"
  rm_rf(scratch)
  with_sandbox_cache(scratch, () => {
    let box = sandbox_create("./nested", ".").unwrap()
    assert_eq(box.cwd, box.root)
    assert_true(ends_with_path(box.artifact_root, "nested"))
    assert_true(@fs.path_exists(box.artifact_root))
    sandbox_destroy(box)
  })
  rm_rf(scratch)
}

///|
test "a task root that shares no ancestor with the repo gets no sandbox" {
  // Neither path contains the other, so no single tree holds both.
  // Reporting and running unsandboxed is the honest answer; silently
  // mirroring one of them would claim a guarantee that is not there.
  let scratch = "_build/sandbox-test-disjoint"
  rm_rf(scratch)
  with_sandbox_cache(scratch, () => {
    assert_true(sandbox_create("/tmp/pkf-a", "/tmp/pkf-b") is None)
  })
  rm_rf(scratch)
}

///|
test "the sandbox lives under the cache root, not the workspace" {
  // A sandbox inside the workspace would sit inside somebody's
  // `inputs { "**" }`, so building one would change the very digests
  // the run is about to compute.
  let scratch = "_build/sandbox-test-base"
  with_sandbox_cache(scratch, () => {
    assert_eq(sandbox_base(), scratch + "/sandbox")
  })
}
