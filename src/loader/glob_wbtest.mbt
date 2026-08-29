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
  // Names chosen so that LEXICOGRAPHIC order ("aaa" < "b") differs from
  // MoonBit's LENGTH-FIRST builtin sort ("b" (1 char) < "aaa" (3 chars)).
  // Apple Pkl keys the `import*` Mapping lexicographically, so a length-first
  // sort would ship the wrong key order here (C1 regression guard).
  @fs.write_string_to_file(root + "/sub/aaa.pkl", "vaaa = 1\n")
  @fs.write_string_to_file(root + "/sub/b.pkl", "vb = 2\n")
  // x9 vs x10: lexicographic puts "x10.pkl" before "x9.pkl" ('1' < '9'),
  // but length-first puts "x9.pkl" (6) before "x10.pkl" (7).
  @fs.write_string_to_file(root + "/x9.pkl", "v9 = 9\n")
  @fs.write_string_to_file(root + "/x10.pkl", "v10 = 10\n")
  @fs.write_string_to_file(
    root + "/main.pkl",
    "import* \"sub/*.pkl\" as mods\nimport* \"x*.pkl\" as xs\n\nresult = mods\nxs_result = xs\n",
  )
}

///|
fn glob_fixture_root() -> String {
  // Unique per-process dir to avoid cross-test sandbox contamination.
  let base = match @env.get_env_var("TMPDIR") {
    Some(d) => if d.has_suffix("/") { d } else { d + "/" }
    None => "/tmp/"
  }
  base + "pkf-glob-fixture"
}

///|
async test "embedded loader resolves glob imports keyed by glob-relative path" {
  // No manual sandbox reset needed: `eval_module_path` resets the global
  // sandbox IO cache at the start of every eval (I2).
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
      fail("eval failed: \{repr(msgs)}")
    }
  }
  // Keys must be the glob-relative paths and the matched modules' values.
  assert_true(json.contains("\"sub/aaa.pkl\""))
  assert_true(json.contains("\"sub/b.pkl\""))
  assert_true(json.contains("\"vaaa\""))
  assert_true(json.contains("\"vb\""))
  // Ordering must be LEXICOGRAPHIC, matching Apple Pkl's Mapping key order.
  // "sub/aaa.pkl" must precede "sub/b.pkl" (fails under length-first sort).
  let idx_aaa = substr_index(json, "\"sub/aaa.pkl\"")
  let idx_b = substr_index(json, "\"sub/b.pkl\"")
  assert_true(idx_aaa >= 0)
  assert_true(idx_b >= 0)
  assert_true(idx_aaa < idx_b)
  // "x10.pkl" must precede "x9.pkl" ('1' < '9'); fails under length-first sort.
  let idx_x10 = substr_index(json, "\"x10.pkl\"")
  let idx_x9 = substr_index(json, "\"x9.pkl\"")
  assert_true(idx_x10 >= 0)
  assert_true(idx_x9 >= 0)
  assert_true(idx_x10 < idx_x9)
}

///|
/// Index of the first occurrence of `needle` in `hay`, or -1 if absent.
fn substr_index(hay : String, needle : String) -> Int {
  let hl = hay.length()
  let nl = needle.length()
  if nl == 0 {
    return 0
  }
  for i in 0..<=(hl - nl) {
    let mut matched = true
    for j in 0..<nl {
      if hay[i + j] != needle[j] {
        matched = false
        break
      }
    }
    if matched {
      return i
    }
  }
  -1
}

///|
async test "embedded loader rejects ** recursive glob imports cleanly" {
  let root = glob_fixture_root() + "-deep"
  @fs.create_dir(root) catch {
    _ => ()
  }
  @fs.create_dir(root + "/deep") catch {
    _ => ()
  }
  @fs.write_string_to_file(root + "/deep/top.pkl", "vtop = 0\n")
  @fs.write_string_to_file(
    root + "/main.pkl",
    "import* \"deep/**.pkl\" as d\n\nr = d\n",
  )
  let main = root + "/main.pkl"
  let threw = try {
    let _ = eval_module_path(main)
    false
  } catch {
    LoaderError(_) => true
  }
  // `**` must NOT silently partial-match: it raises a clean LoaderError.
  assert_true(threw)
}
