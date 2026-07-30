// Ported from conformance/differ_test.go, fsenv_test.go, and the Compare-
// related cases in conformance_test.go. Validates the differ port directly,
// independent of any pkf binary.

///|
fn default_contract() -> Contract {
  Contract::{
    json: false,
    unordered_paths: [],
    json_ignore_paths: [],
    exit: false,
    must_contain: [],
    fs_delta: false,
    env: false,
    must_contain_stderr: [],
    stdout_empty: false,
    stdout_non_empty: false,
  }
}

///|
fn scen(c : Contract) -> Scenario {
  Scenario::{
    id: "t",
    fixture: "",
    argv: [],
    env: Map([]),
    setup: [],
    contract: c,
  }
}

///|
fn result(
  stdout? : String = "",
  stderr? : String = "",
  exit? : Int = 0,
) -> RunResult {
  RunResult::{ stdout, stderr, exit, fs_delta: [], fs_deleted: [] }
}

// --- DiffJSON cases (differ_test.go) ---

///|
test "json equal identical" {
  let a = "{\"tasks\":[{\"name\":\"a\"},{\"name\":\"b\"}]}"
  assert_eq(diff_json(a, a, []), "")
}

///|
test "json order sensitive by default" {
  let a = "{\"tasks\":[{\"name\":\"a\"},{\"name\":\"b\"}]}"
  let b = "{\"tasks\":[{\"name\":\"b\"},{\"name\":\"a\"}]}"
  assert_true(diff_json(a, b, []) != "")
}

///|
test "json unordered path" {
  let a = "{\"edges\":[{\"from\":\"a\"},{\"from\":\"b\"}]}"
  let b = "{\"edges\":[{\"from\":\"b\"},{\"from\":\"a\"}]}"
  assert_eq(diff_json(a, b, ["edges"]), "")
}

///|
test "json value mismatch" {
  let a = "{\"cache\":true}"
  let b = "{\"cache\":false}"
  assert_true(diff_json(a, b, []) != "")
}

///|
test "json scalar type mismatch" {
  // number-vs-string, bool-vs-string, null-vs-string, bool-vs-number.
  assert_true(diff_json("{\"x\":1}", "{\"x\":\"1\"}", []) != "")
  assert_true(diff_json("{\"x\":true}", "{\"x\":\"true\"}", []) != "")
  assert_true(diff_json("{\"x\":null}", "{\"x\":\"<nil>\"}", []) != "")
  assert_true(diff_json("{\"x\":true}", "{\"x\":1}", []) != "")
}

///|
test "json number int float equal" {
  // Go parses both to float64, so 1 == 1.0.
  assert_eq(diff_json("{\"x\":1}", "{\"x\":1.0}", []), "")
}

// --- fs delta cases (fsenv_test.go) ---

///|
test "fsdelta detects write" {
  let before : Map[String, String] = Map([])
  before["a.txt"] = "h1"
  let after : Map[String, String] = Map([])
  after["a.txt"] = "h1"
  after["b.txt"] = "h2"
  let got = delta_paths(before, after)
  assert_eq(got.length(), 1)
  assert_eq(got[0], "b.txt")
}

///|
test "fsdelta detects modify" {
  let before : Map[String, String] = Map([])
  before["a.txt"] = "h1"
  let after : Map[String, String] = Map([])
  after["a.txt"] = "h2"
  let got = delta_paths(before, after)
  assert_eq(got.length(), 1)
  assert_eq(got[0], "a.txt")
}

///|
test "deleted paths" {
  let before : Map[String, String] = Map([])
  before["a.txt"] = "h1"
  before["b.txt"] = "h2"
  let after : Map[String, String] = Map([])
  after["a.txt"] = "h1"
  let got = deleted_paths(before, after)
  assert_eq(got.length(), 1)
  assert_eq(got[0], "b.txt")
}

///|
test "marshal delta nil and empty equal" {
  assert_eq(marshal_delta([]), "[]")
  assert_eq(diff_json(marshal_delta([]), marshal_delta([]), []), "")
}

// --- Compare cases (conformance_test.go) ---

///|
test "compare json ignore paths" {
  let c = default_contract()
  let c = Contract::{ ..c, json: true, json_ignore_paths: ["taskfile"] }
  let s = scen(c)
  let want = Golden::{
    stdout: "{\"taskfile\":\"/tmp/a/Taskfile.pkl\",\"schemaVersion\":\"pkfire@0.10.0\"}",
    stderr: "",
    exit: 0,
    fs_delta: [],
    fs_deleted: [],
  }
  let got = result(
    stdout="{\"taskfile\":\"/tmp/DIFFERENT/Taskfile.pkl\",\"schemaVersion\":\"pkfire@0.10.0\"}",
  )
  assert_eq(compare(s, want, got), "")
  let got2 = result(
    stdout="{\"taskfile\":\"/x\",\"schemaVersion\":\"pkfire@0.11.0\"}",
  )
  assert_true(compare(s, want, got2) != "")
}

///|
test "strip json keys recursive" {
  let c = default_contract()
  let c = Contract::{ ..c, json: true, json_ignore_paths: ["path"] }
  let s = scen(c)
  let want = Golden::{
    stdout: "{\"findings\":[{\"path\":\"/tmp/a\",\"line\":3,\"kind\":\"x\"}]}",
    stderr: "",
    exit: 0,
    fs_delta: [],
    fs_deleted: [],
  }
  let got = result(
    stdout="{\"findings\":[{\"path\":\"/tmp/DIFF\",\"line\":3,\"kind\":\"x\"}]}",
  )
  assert_eq(compare(s, want, got), "")
  let got2 = result(
    stdout="{\"findings\":[{\"path\":\"/x\",\"line\":9,\"kind\":\"x\"}]}",
  )
  assert_true(compare(s, want, got2) != "")
}

///|
test "compare stderr contract" {
  let c = default_contract()
  let c = Contract::{
    ..c,
    exit: true,
    must_contain_stderr: ["usage"],
    stdout_empty: true,
  }
  let s = scen(c)
  let want = Golden::{
    stdout: "",
    stderr: "pkf: usage: ...\n",
    exit: 1,
    fs_delta: [],
    fs_deleted: [],
  }
  let got = result(stderr="pkf:   usage:  ...\n", exit=1)
  assert_eq(compare(s, want, got), "")
  let got2 = result(stdout="leaked", stderr="pkf:   usage:  ...\n", exit=1)
  assert_true(compare(s, want, got2) != "")
}

///|
test "compare stdout non empty" {
  let c = default_contract()
  let c = Contract::{ ..c, exit: true, stdout_non_empty: true }
  let s = scen(c)
  let want = Golden::{
    stdout: "",
    stderr: "",
    exit: 0,
    fs_delta: [],
    fs_deleted: [],
  }
  assert_eq(compare(s, want, result(stdout="v1.2.3\n", exit=0)), "")
  assert_true(compare(s, want, result(stdout="   \n", exit=0)) != "")
}

///|
test "normalize text collapses whitespace" {
  assert_eq(normalize_text("  a \t b\n c  "), "a b c")
  assert_true(contains_normalized("pkf:   usage:  ...\n", "usage"))
}

///|
// Regression: MoonBit's default `String::compare` / `Array::sort()` is
// length-first, which orders equal-prefix paths of different length
// (".git/hooks/pre-commit" len 21 vs ".git/hooks/pre-push" len 19) the
// opposite way from Go's byte-lexicographic `sort.Strings`. `lex_compare`
// restores Go ordering so the fsDelta golden compares equal.
test "lex compare matches go sort.Strings" {
  assert_true(lex_compare("a", "b") < 0)
  assert_true(lex_compare(".git/hooks/pre-commit", ".git/hooks/pre-push") < 0)
  assert_true(lex_compare("ab", "b") < 0)
  assert_eq(lex_compare("abc", "abc"), 0)
  assert_true(lex_compare("ab", "abc") < 0)
}

///|
test "delta paths lex-sorted like go" {
  let before : Map[String, String] = Map([])
  let after : Map[String, String] = Map([])
  after[".git/hooks/pre-push"] = "h1"
  after[".git/hooks/pre-commit"] = "h2"
  let got = delta_paths(before, after)
  assert_eq(got[0], ".git/hooks/pre-commit")
  assert_eq(got[1], ".git/hooks/pre-push")
}
