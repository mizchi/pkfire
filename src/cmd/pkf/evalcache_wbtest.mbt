// Tests for the Pkl evaluation cache.
//
// A stale plan is the failure mode that matters: it would run
// yesterday's commands against yesterday's inputs and report success,
// with nothing in the output to suggest anything was reused. So these
// pin the *validation*, not the speed — every way an entry can stop
// being true has to read as a miss. The end-to-end invalidation paths
// (editing the Taskfile, editing an import, adding or removing a file
// matching a glob import) are exercised by the `eval-cache-*`
// conformance scenarios.

///|
fn deps_of(
  modules : Array[(String, String)],
  dirs : Array[(String, String)],
) -> EvalDeps {
  EvalDeps::{ modules, dirs }
}

///|
test "a round-trip returns the rendered JSON verbatim" {
  // The payload is JSON and is stored unescaped, so a `\n` or a quote
  // inside it must survive the header/payload split untouched.
  let rendered = "{\"tasks\":[{\"cmd\":\"echo \\\"hi\\\"\\nsecond\"}]}"
  let text = encode_eval_entry(deps_of([], []), rendered)
  assert_eq(decode_eval_entry(text), Some(rendered))
}

///|
test "a payload containing a blank line is not truncated at it" {
  // The header ends at the first blank line. A rendered plan holding
  // one of its own would be cut short — and a truncated plan parses as
  // fewer tasks rather than as an error.
  let rendered = "line one\n\nline three\n"
  let text = encode_eval_entry(deps_of([], []), rendered)
  assert_eq(decode_eval_entry(text), Some(rendered))
}

///|
test "a module whose bytes moved is a miss" {
  // `moon.mod` exists and has some digest; claiming a different one is
  // exactly the shape of "someone edited this since we cached".
  let stale = deps_of([("moon.mod", "0".repeat(64))], [])
  assert_true(decode_eval_entry(encode_eval_entry(stale, "{}")) is None)
  // The same entry with the real digest is a hit.
  let fresh = deps_of([("moon.mod", hex_encode(hash_file("moon.mod")))], [])
  assert_eq(decode_eval_entry(encode_eval_entry(fresh, "{}")), Some("{}"))
}

///|
test "a module that no longer exists is a miss" {
  let gone = deps_of([("no-such-module.pkl", "0".repeat(64))], [])
  assert_true(decode_eval_entry(encode_eval_entry(gone, "{}")) is None)
}

///|
test "a directory that gained or lost a file is a miss" {
  // This is the glob-import hole: `import* "rules/*.pkl"` expands at
  // load time, so a new matching file belongs in the graph even though
  // no recorded module's bytes changed. Nothing in `modules` notices;
  // the listing digest does.
  let real = deps_of([], [("src/cmd/pkf", dir_listing_digest("src/cmd/pkf"))])
  assert_eq(decode_eval_entry(encode_eval_entry(real, "{}")), Some("{}"))
  let stale = deps_of([], [("src/cmd/pkf", "0".repeat(64))])
  assert_true(decode_eval_entry(encode_eval_entry(stale, "{}")) is None)
}

///|
test "an entry from another format version is a miss" {
  // Not a parse error to be recovered from: the fields recorded then
  // may not be the fields checked now, so the only safe reading of an
  // old entry is that there isn't one.
  let text = encode_eval_entry(deps_of([], []), "{}")
  let wrong = "pkfire-eval-v0" +
    text[EVAL_CACHE_VERSION.length():text.length()].to_owned()
  assert_true(decode_eval_entry(wrong) is None)
}

///|
test "a malformed entry is a miss, not a crash or a guess" {
  assert_true(decode_eval_entry("") is None)
  // No blank line: no payload boundary.
  assert_true(decode_eval_entry(EVAL_CACHE_VERSION + "\nM abc x") is None)
  // A header line with an unknown kind, or no space between digest and
  // path, cannot be validated — so it is not trusted.
  assert_true(
    decode_eval_entry(EVAL_CACHE_VERSION + "\nX abc def\n\n{}") is None,
  )
  assert_true(decode_eval_entry(EVAL_CACHE_VERSION + "\nM abc\n\n{}") is None)
}

///|
test "a version-pinned URI is recorded without a digest" {
  // A `package://…@0.10.0` module cannot change meaning without its own
  // text changing, and the loader reports the URI rather than the file
  // it resolved to. Hashing nothing is correct here; failing to cache
  // would give up the whole win for every example that pins a package.
  let deps = eval_deps_of([
    "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.10.0#/Taskfile.pkl",
  ]).unwrap()
  assert_eq(deps.modules.length(), 1)
  assert_eq(deps.modules[0].1, "uri")
  // And no directory is recorded for it, since there is no local one.
  assert_eq(deps.dirs.length(), 0)
}

///|
test "a module that cannot be read stops the entry being written" {
  // An evaluation whose dependencies cannot all be pinned must not be
  // cached: the unpinned one is exactly the one that could change
  // without anyone noticing.
  assert_true(eval_deps_of(["no-such-module.pkl"]) is None)
  // A readable one records both its digest and its directory listing.
  let deps = eval_deps_of(["moon.mod"]).unwrap()
  assert_eq(deps.modules.length(), 1)
  assert_eq(deps.dirs.length(), 1)
}

///|
test "the slot depends on the Taskfile's identity and its bytes" {
  let a = eval_cache_slot("moon.mod").unwrap()
  let b = eval_cache_slot("moon.work").unwrap()
  assert_true(a != b)
  assert_eq(eval_cache_slot("moon.mod"), Some(a))
  // A Taskfile that is not there has no slot.
  assert_true(eval_cache_slot("no-such-taskfile.pkl") is None)
}

///|
test "records are sorted, so one evaluation yields one entry" {
  // The loader reports modules in whatever order it walked them.
  // Recording that order would make two identical evaluations produce
  // different bytes, and a reader comparing them would see a change
  // where there was none.
  let deps = eval_deps_of(["moon.work", "moon.mod"]).unwrap()
  assert_eq(deps.modules[0].0, "moon.mod")
  assert_eq(deps.modules[1].0, "moon.work")
}

///|
test "only module names reach the directory digest" {
  // The digest exists so a *new module* matching a glob import
  // invalidates the entry. Hashing everything else in the directory
  // made the entry depend on things no evaluation can read — and the
  // entry point's directory is the project root, so with the
  // documented `PKFIRE_MBT_CACHE_DIR=.pkf-cache` layout every build
  // wrote into it and invalidated the plan it had just cached.
  let dir = scratch("dir-digest")
  @fs.write_string_to_file(dir + "/a.pkl", "x = 1") catch { _ => () }
  let before = dir_listing_digest(dir)

  // Things a module glob can never match: the cache directory a build
  // writes, a build output, an editor's leftovers.
  mkdir_p(dir + "/.pkf-cache")
  @fs.write_string_to_file(dir + "/.pkf-cache/entry", "blob") catch { _ => () }
  @fs.write_string_to_file(dir + "/out.txt", "built") catch { _ => () }
  @fs.write_string_to_file(dir + "/a.pkl.swp", "vim") catch { _ => () }
  assert_eq(dir_listing_digest(dir), before)

  // A new module still moves it, which is the whole point.
  @fs.write_string_to_file(dir + "/b.pkl", "y = 2") catch { _ => () }
  assert_true(dir_listing_digest(dir) != before)
  rm_rf(dir)
}

