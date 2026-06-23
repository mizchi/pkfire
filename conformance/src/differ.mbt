// Port of conformance/differ.go. The semantics here must match the Go
// harness byte-for-verdict: this is the permanent contract gate after the
// Go harness is deleted.

///|
/// Type-aware deep JSON comparison. Returns "" if want and got are
/// deep-equal, or a human-readable description of the first difference.
/// Arrays at a dotted path in `unordered` are compared as multisets; every
/// other array is compared positionally.
///
/// Mirrors Go's `DiffJSON` + `jsonDiff`. Go's encoding/json yields scalars
/// of type {nil, bool, float64, string}; the type check below distinguishes
/// Null / Bool / Number / String / Array / Object exactly as Go's
/// `reflect.TypeOf` does, so a stringified number/bool ("1" vs 1) is a type
/// mismatch, not equality.
pub fn diff_json(want : String, got : String, unordered : Array[String]) -> String {
  let wv = try? @json.parse(want)
  let wv = match wv {
    Ok(v) => v
    Err(e) => return "golden is not valid JSON: \{e}"
  }
  let gv = try? @json.parse(got)
  let gv = match gv {
    Ok(v) => v
    Err(e) => return "candidate stdout is not valid JSON: \{e}"
  }
  let set : Map[String, Bool] = Map::new()
  for p in unordered {
    set[p] = true
  }
  json_diff("", wv, gv, set)
}

///|
fn json_diff(
  path : String,
  want : Json,
  got : Json,
  unordered : Map[String, Bool],
) -> String {
  match want {
    Object(w) =>
      match got {
        Object(g) => {
          // every key in want must be present and equal in got
          for k, wval in w {
            match g.get(k) {
              None => return "\{path_or_root(path)}: missing key \"\{k}\""
              Some(gval) => {
                let d = json_diff(join_path(path, k), wval, gval, unordered)
                if d != "" {
                  return d
                }
              }
            }
          }
          // no extra keys in got
          for k, _ in g {
            if w.get(k) is None {
              return "\{path_or_root(path)}: unexpected key \"\{k}\""
            }
          }
          ""
        }
        _ => "\{path_or_root(path)}: type object != \{type_name(got)}"
      }
    Array(w) =>
      match got {
        Array(g) => {
          if w.length() != g.length() {
            return "\{path_or_root(path)}: array len \{w.length()} != \{g.length()}"
          }
          if unordered.get(path) is Some(true) {
            let ws = canon_sorted(w)
            let gs = canon_sorted(g)
            for i in 0..<ws.length() {
              if ws[i] != gs[i] {
                return "\{path_or_root(path)}: multiset mismatch: want has \{ws[i]}, got has \{gs[i]}"
              }
            }
            return ""
          }
          for i in 0..<w.length() {
            let d = json_diff("\{path}[\{i}]", w[i], g[i], unordered)
            if d != "" {
              return d
            }
          }
          ""
        }
        _ => "\{path_or_root(path)}: type array != \{type_name(got)}"
      }
    _ => {
      // scalar: compare type first (Go does reflect.TypeOf), then value.
      if scalar_type(want) != scalar_type(got) {
        return "\{path_or_root(path)}: type \{type_name(want)} != \{type_name(got)}"
      }
      if not(scalar_eq(want, got)) {
        return "\{path_or_root(path)}: \{scalar_show(want)} != \{scalar_show(got)}"
      }
      ""
    }
  }
}

///|
/// Coarse scalar type tag, matching Go's {nil, bool, float64, string}.
/// True and False share the "bool" tag (so true != false is a value
/// mismatch, not a type mismatch), exactly like Go.
fn scalar_type(j : Json) -> Int {
  match j {
    Null => 0
    True => 1
    False => 1
    Number(_) => 2
    String(_) => 3
    Array(_) => 4
    Object(_) => 5
  }
}

///|
fn scalar_eq(a : Json, b : Json) -> Bool {
  match (a, b) {
    (Null, Null) => true
    (True, True) => true
    (False, False) => true
    (True, False) => false
    (False, True) => false
    // Compare numbers by value, not repr: Go parses to float64 so 1 == 1.0.
    (Number(x), Number(y)) => x == y
    (String(x), String(y)) => x == y
    _ => false
  }
}

///|
fn type_name(j : Json) -> String {
  match j {
    Null => "null"
    True | False => "bool"
    Number(_) => "number"
    String(_) => "string"
    Array(_) => "array"
    Object(_) => "object"
  }
}

///|
fn scalar_show(j : Json) -> String {
  match j {
    Null => "<nil>"
    True => "true"
    False => "false"
    Number(x) => {
      // Go prints float64 with %v; integers come out without a decimal point.
      let n = x.to_int()
      if n.to_double() == x {
        "\{n}"
      } else {
        "\{x}"
      }
    }
    String(s) => s
    other => other.stringify()
  }
}

///|
/// Canonical JSON of each element, sorted, for multiset compare.
/// Mirrors Go's `canonSorted` (json.Marshal each element + sort.Strings).
fn canon_sorted(arr : Array[Json]) -> Array[String] {
  let out : Array[String] = []
  for e in arr {
    out.push(canon_json(e))
  }
  out.sort_by((x, y) => lex_compare(x, y))
  out
}

///|
/// Deterministic canonical encoding with object keys sorted, so two
/// structurally-equal objects produce the same string regardless of key
/// insertion order (Go's json.Marshal sorts map keys).
fn canon_json(j : Json) -> String {
  match j {
    Null => "null"
    True => "true"
    False => "false"
    Number(x) => {
      let n = x.to_int()
      if n.to_double() == x {
        "\{n}"
      } else {
        "\{x}"
      }
    }
    String(s) => Json::string(s).stringify()
    Array(a) => {
      let parts : Array[String] = []
      for e in a {
        parts.push(canon_json(e))
      }
      "[" + join_strings(parts, ",") + "]"
    }
    Object(o) => {
      let keys : Array[String] = []
      for k, _ in o {
        keys.push(k)
      }
      keys.sort()
      let parts : Array[String] = []
      for k in keys {
        let v = o.get(k).unwrap()
        parts.push(Json::string(k).stringify() + ":" + canon_json(v))
      }
      "{" + join_strings(parts, ",") + "}"
    }
  }
}

///|
fn join_strings(parts : Array[String], sep : String) -> String {
  let mut out = ""
  for i in 0..<parts.length() {
    if i > 0 {
      out = out + sep
    }
    out = out + parts[i]
  }
  out
}

///|
/// Pure lexicographic (codepoint-wise) string comparison, matching Go's
/// `sort.Strings` / byte-wise ordering for the ASCII paths and JSON keys this
/// harness handles. MoonBit's default `String::compare` is length-first, which
/// diverges from Go for equal-prefix strings of different length (e.g.
/// ".git/hooks/pre-commit" vs ".git/hooks/pre-push"), so the conformance fs
/// delta and canonical multiset sort MUST use this instead.
pub fn lex_compare(a : String, b : String) -> Int {
  let ca = a.to_array()
  let cb = b.to_array()
  let n = if ca.length() < cb.length() { ca.length() } else { cb.length() }
  for i in 0..<n {
    let x = ca[i].to_int()
    let y = cb[i].to_int()
    if x != y {
      return if x < y { -1 } else { 1 }
    }
  }
  if ca.length() == cb.length() {
    0
  } else if ca.length() < cb.length() {
    -1
  } else {
    1
  }
}

///|
fn join_path(path : String, key : String) -> String {
  if path == "" {
    key
  } else {
    path + "." + key
  }
}

///|
fn path_or_root(path : String) -> String {
  if path == "" {
    "(root)"
  } else {
    path
  }
}

///|
/// Recursively delete the given keys from a JSON value at any depth, then
/// re-encode. Mirrors Go's `stripJSONKeys`: volatile keys (absolute paths
/// etc.) are dropped from BOTH sides before deep-compare.
pub fn strip_json_keys(raw : String, keys : Array[String]) -> String {
  if keys.length() == 0 {
    return raw
  }
  let v = match (try? @json.parse(raw)) {
    Ok(v) => v
    Err(_) => return raw
  }
  let set : Map[String, Bool] = Map::new()
  for k in keys {
    set[k] = true
  }
  let stripped = strip_walk(v, set)
  stripped.stringify()
}

///|
fn strip_walk(n : Json, set : Map[String, Bool]) -> Json {
  match n {
    Object(o) => {
      let out : Map[String, Json] = Map::new()
      for k, v in o {
        if set.get(k) is Some(true) {
          continue
        }
        out[k] = strip_walk(v, set)
      }
      Json::object(out)
    }
    Array(a) => {
      let out : Array[Json] = []
      for e in a {
        out.push(strip_walk(e, set))
      }
      Json::array(out)
    }
    other => other
  }
}

///|
/// Normalize text: collapse runs of whitespace to a single space and trim,
/// matching Go's `strings.Join(strings.Fields(s), " ")`.
pub fn normalize_text(s : String) -> String {
  let fields : Array[String] = []
  let buf = StringBuilder::new()
  fn flush() {
    let w = buf.to_string()
    if w.length() > 0 {
      fields.push(w)
      buf.reset()
    }
  }

  for c in s {
    // Go's strings.Fields splits on unicode.IsSpace: space, tab, newline,
    // CR, vertical tab, form feed.
    if c == ' ' ||
      c == '\t' ||
      c == '\n' ||
      c == '\r' ||
      c == '\u{0B}' ||
      c == '\u{0C}' {
      flush()
    } else {
      buf.write_char(c)
    }
  }
  flush()
  join_strings(fields, " ")
}

///|
/// Normalized-substring containment, matching Go's `containsNormalized`.
pub fn contains_normalized(haystack : String, sub : String) -> Bool {
  normalize_text(haystack).contains(normalize_text(sub))
}

///|
/// Render a sorted path list as stable JSON, normalizing an empty list to
/// "[]" so a nil (no-change) delta and an empty delta compare equal.
/// Mirrors Go's `MarshalDelta`.
pub fn marshal_delta(paths : Array[String]) -> String {
  let arr : Array[Json] = []
  for p in paths {
    arr.push(Json::string(p))
  }
  Json::array(arr).stringify()
}

///|
/// Apply a scenario's contract to a candidate result against a golden.
/// Returns "" on match or the first failure description. The check ORDER
/// (exit -> json -> mustContain -> fsDelta/fsDeleted -> mustContainStderr ->
/// stdoutEmpty -> stdoutNonEmpty) mirrors Go's `Compare` exactly.
pub fn compare(s : Scenario, want : Golden, got : RunResult) -> String {
  if s.contract.exit && want.exit != got.exit {
    return "exit: want \{want.exit}, got \{got.exit}"
  }
  if s.contract.json {
    let w = strip_json_keys(want.stdout, s.contract.json_ignore_paths)
    let g = strip_json_keys(got.stdout, s.contract.json_ignore_paths)
    let d = diff_json(w, g, s.contract.unordered_paths)
    if d != "" {
      return "json: " + d
    }
  }
  for sub in s.contract.must_contain {
    if not(contains_normalized(got.stdout, sub)) {
      return "mustContain: \"\{sub}\" not found in normalized stdout"
    }
  }
  if s.contract.fs_delta {
    let d = diff_json(
      marshal_delta(want.fs_delta),
      marshal_delta(got.fs_delta),
      [],
    )
    if d != "" {
      return "fsDelta: " + d
    }
    let d2 = diff_json(
      marshal_delta(want.fs_deleted),
      marshal_delta(got.fs_deleted),
      [],
    )
    if d2 != "" {
      return "fsDeleted: " + d2
    }
  }
  for sub in s.contract.must_contain_stderr {
    if not(contains_normalized(got.stderr, sub)) {
      return "mustContainStderr: \"\{sub}\" not found in normalized stderr"
    }
  }
  if s.contract.stdout_empty && normalize_text(got.stdout).length() != 0 {
    return "stdoutEmpty: expected empty stdout, got \"\{got.stdout}\""
  }
  if s.contract.stdout_non_empty && normalize_text(got.stdout).length() == 0 {
    return "stdoutNonEmpty: expected non-empty stdout"
  }
  ""
}
