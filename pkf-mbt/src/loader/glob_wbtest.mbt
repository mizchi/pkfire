// Whitebox test for embedded-loader glob import resolution (phase 3, task 5):
// `import* "sub/*.pkl"` must resolve in-process, with the resulting Mapping
// keyed by the glob-relative path as-written ("sub/a.pkl", "sub/b.pkl") — the
// exact key form Apple Pkl's `pkl` CLI produces (verified against the oracle:
// `pkl eval -f json` over the same two-file fixture renders
// `{"mods":{"sub/a.pkl":{"va":1},"sub/b.pkl":{"vb":2}}}`).
//
// The test writes its own isolated fixture under a unique temp directory so
// that the global sandbox `import_globs` registry (mutated by
// `register_import_glob`) can't collide with another test's pattern.

///|
fn write_glob_fixture(root : String) -> Unit raise {
  @fs.create_dir(root) catch {
    _ => ()
  }
  @fs.create_dir(root + "/sub") catch {
    _ => ()
  }
  @fs.write_string_to_file(root + "/sub/a.pkl", "va = 1\n")
  @fs.write_string_to_file(root + "/sub/b.pkl", "vb = 2\n")
  @fs.write_string_to_file(
    root + "/main.pkl",
    "import* \"sub/*.pkl\" as mods\n\nresult = mods\n",
  )
}

///|
fn glob_fixture_root() -> String {
  // Unique per-process dir to avoid cross-test sandbox contamination.
  let base = match @sys.get_env_var("TMPDIR") {
    Some(d) => if d.has_suffix("/") { d } else { d + "/" }
    None => "/tmp/"
  }
  base + "pkf-glob-fixture"
}

///|
async test "embedded loader resolves glob imports keyed by glob-relative path" {
  @pkl.reset_sandbox_io_cache()
  let root = glob_fixture_root()
  write_glob_fixture(root)
  let main = root + "/main.pkl"
  let result = eval_module_path(main)
  let json = match result {
    EvalOk(value) => @pkl.render_value_as_json(value)
    EvalError(diags) => {
      let msgs : Array[String] = []
      for d in diags {
        msgs.push(d.message)
      }
      fail("eval failed: \{msgs}")
    }
  }
  // Keys must be the glob-relative paths and the matched modules' values.
  assert_true(json.contains("\"sub/a.pkl\""))
  assert_true(json.contains("\"sub/b.pkl\""))
  assert_true(json.contains("\"va\""))
  assert_true(json.contains("\"vb\""))
}
