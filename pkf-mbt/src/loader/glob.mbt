// Minimal filesystem glob matcher for the embedded loader's `import*`
// expansion. Ported from `cmd/pkf/main.mbt` (different package, not importable
// here). Supports `*` (any chars within a path segment), `?`, `[...]`
// character classes, `**` (zero-or-more path segments), and `{a,b}` brace
// alternation — the same surface the rest of pkf already accepts.

///|
/// Lexicographic string comparison (char-by-char, shorter prefix wins).
/// MoonBit's built-in `String::compare` / `Array::sort` sort by LENGTH first,
/// but Apple Pkl keys an `import*` Mapping LEXICOGRAPHICALLY and that key order
/// is final (the evaluator does not re-sort). Ported from `lex_cmp` in
/// `cmd/pkf/main.mbt` (different package, not importable here).
fn lex_cmp(a : String, b : String) -> Int {
  let la = a.length()
  let lb = b.length()
  let min_len = if la < lb { la } else { lb }
  for i in 0..<min_len {
    let ca = a[i].to_int()
    let cb = b[i].to_int()
    if ca != cb {
      return ca - cb
    }
  }
  la - lb
}

///|
/// True if any `/`-separated segment of `pattern` contains a `**` token. Apple
/// Pkl treats `**` as crossing `/` (including the in-segment `**.pkl` form),
/// with a files-first-then-recurse per-directory ordering that this embedded
/// matcher does not reproduce byte-exactly. Rather than ship the current
/// silently-incomplete single-level `**` match, the loader rejects such
/// patterns cleanly (see `expand_import_glob` in loader.mbt). No real Taskfile
/// in scope uses `**` import globs.
fn pattern_has_doublestar(pattern : String) -> Bool {
  pattern.contains("**")
}

///|
/// Match a slash-separated relative `path` against a glob `pattern`.
fn glob_match(pattern : String, path : String) -> Bool {
  for expanded in brace_expand(pattern) {
    let p_segs = expanded.split("/").collect()
    let s_segs = path.split("/").collect()
    if glob_segs(p_segs, 0, s_segs, 0) {
      return true
    }
  }
  false
}

///|
/// Recursively expand `{a,b,c}` brace alternations into a flat pattern list.
/// Nested braces are handled; commas inside nested braces are not split
/// points. An unmatched `{` is treated as a literal.
fn brace_expand(pattern : String) -> Array[String] {
  let mut open = -1
  let mut close = -1
  let mut depth = 0
  for i in 0..<pattern.length() {
    let c = pattern[i]
    if c == '{' {
      if open < 0 {
        open = i
      }
      depth = depth + 1
    } else if c == '}' {
      depth = depth - 1
      if depth == 0 {
        close = i
        break
      }
    }
  }
  if open < 0 || close < 0 {
    return [pattern]
  }
  let before = pattern[:open].to_owned()
  let body = pattern[open + 1:close].to_owned()
  let after = pattern[close + 1:].to_owned()
  let parts : Array[String] = []
  let mut start = 0
  let mut d = 0
  for i in 0..<body.length() {
    let c = body[i]
    if c == '{' {
      d = d + 1
    } else if c == '}' {
      d = d - 1
    } else if c == ',' && d == 0 {
      parts.push(body[start:i].to_owned())
      start = i + 1
    }
  }
  parts.push(body[start:].to_owned())
  let result : Array[String] = []
  for part in parts {
    for sub in brace_expand(before + part + after) {
      result.push(sub)
    }
  }
  result
}

///|
fn glob_segs(
  p : Array[StringView],
  pi : Int,
  s : Array[StringView],
  si : Int,
) -> Bool {
  let mut pi = pi
  let mut si = si
  for ;; {
    if pi >= p.length() {
      return si >= s.length()
    }
    let seg = p[pi].to_string()
    if seg == "**" {
      if pi == p.length() - 1 {
        return true
      }
      for skip = si; skip <= s.length(); skip = skip + 1 {
        if glob_segs(p, pi + 1, s, skip) {
          return true
        }
      }
      return false
    }
    if si >= s.length() {
      return false
    }
    if !glob_segment_matches(seg, s[si].to_string()) {
      return false
    }
    pi = pi + 1
    si = si + 1
  }
}

///|
fn glob_segment_matches(pat : String, seg : String) -> Bool {
  glob_seg_step(pat, 0, seg, 0)
}

///|
fn glob_seg_step(pat : String, pi : Int, seg : String, si : Int) -> Bool {
  let mut pi = pi
  let mut si = si
  for ;; {
    if pi >= pat.length() {
      return si >= seg.length()
    }
    let pc = pat[pi]
    if pc == '*' {
      for skip = si; skip <= seg.length(); skip = skip + 1 {
        if glob_seg_step(pat, pi + 1, seg, skip) {
          return true
        }
      }
      return false
    }
    if pc == '[' {
      let class_start = if pi + 1 < pat.length() && pat[pi + 1] == '!' {
        pi + 2
      } else {
        pi + 1
      }
      let mut class_end = -1
      for j = class_start; j < pat.length(); j = j + 1 {
        if pat[j] == ']' {
          class_end = j
          break
        }
      }
      if class_end < 0 {
        if si >= seg.length() || pc != seg[si] {
          return false
        }
        pi = pi + 1
        si = si + 1
        continue
      }
      if si >= seg.length() {
        return false
      }
      let sc = seg[si]
      let negate = class_start == pi + 2
      let mut hit = false
      let mut k = class_start
      while k < class_end {
        if k + 2 < class_end && pat[k + 1] == '-' {
          let lo = pat[k]
          let hi = pat[k + 2]
          if sc >= lo && sc <= hi {
            hit = true
          }
          k = k + 3
        } else {
          if pat[k] == sc {
            hit = true
          }
          k = k + 1
        }
      }
      let matched = if negate { !hit } else { hit }
      if !matched {
        return false
      }
      pi = class_end + 1
      si = si + 1
      continue
    }
    if si >= seg.length() {
      return false
    }
    let sc = seg[si]
    if pc == '?' || pc == sc {
      pi = pi + 1
      si = si + 1
    } else {
      return false
    }
  }
}

///|
/// Expand a glob `pattern` against the importing module's base directory.
/// Returns the list of *glob-relative* match paths (the form Apple Pkl keys an
/// `import*` Mapping by, e.g. `["sub/a.pkl", "sub/b.pkl"]`), sorted
/// lexicographically. The pattern is split into a fixed literal prefix (walked
/// straight to disk) and a glob tail (matched against entries below the
/// prefix). Only local directories are supported — see
/// `expand_import_glob` in loader.mbt for the package:// caveat.
fn glob_expand_relative(
  base_dir : String,
  pattern : String,
) -> Array[String] raise {
  let matches : Array[String] = []
  for alt in brace_expand(pattern) {
    collect_glob_alt(base_dir, alt, matches)
  }
  // De-dup (brace alternations could overlap) and sort lexicographically to
  // match Apple Pkl's ordering.
  let seen : Map[String, Unit] = Map([], capacity=matches.length())
  let unique : Array[String] = []
  for m in matches {
    if !seen.contains(m) {
      seen[m] = ()
      unique.push(m)
    }
  }
  // Apple Pkl keys the Mapping LEXICOGRAPHICALLY (not length-first), and that
  // registration order is the final key order. Use the char-by-char comparator.
  unique.sort_by(fn(a, b) { lex_cmp(a, b) })
  unique
}

///|
fn collect_glob_alt(
  base_dir : String,
  pattern : String,
  out : Array[String],
) -> Unit raise {
  // Split off the longest fixed (glob-free) leading directory prefix so we
  // only walk the relevant subtree.
  let segs = pattern.split("/").map(v => v.to_string()).collect()
  let mut fixed_count = 0
  for i in 0..<segs.length() {
    if i == segs.length() - 1 || seg_has_glob(segs[i]) {
      break
    }
    fixed_count = fixed_count + 1
  }
  let prefix_parts : Array[String] = []
  for i in 0..<fixed_count {
    prefix_parts.push(segs[i])
  }
  let prefix_rel = join_segments(prefix_parts)
  let walk_root = if prefix_rel.length() == 0 {
    base_dir
  } else {
    path_join(base_dir, prefix_rel)
  }
  walk_glob(walk_root, prefix_rel, pattern, out, 0)
}

///|
/// Recursion depth cap for `walk_glob`. `@fs.is_dir` follows symlinks, so a
/// self-referential link (`a/link -> a`) would otherwise infinite-recurse.
let walk_glob_max_depth : Int = 64

///|
fn seg_has_glob(seg : String) -> Bool {
  seg.contains("*") || seg.contains("?") || seg.contains("[")
}

///|
fn join_segments(parts : Array[String]) -> String {
  let mut out = ""
  for i in 0..<parts.length() {
    if i > 0 {
      out = out + "/"
    }
    out = out + parts[i]
  }
  out
}

///|
fn walk_glob(
  dir : String,
  rel_prefix : String,
  pattern : String,
  out : Array[String],
  depth : Int,
) -> Unit raise {
  // Guard against symlink cycles (`is_dir` follows links): cap recursion depth.
  if depth > walk_glob_max_depth {
    return
  }
  let entries = @fs.read_dir(dir) catch {
    _ => return
  }
  for name in entries {
    if name == "." || name == ".." {
      continue
    }
    let rel = if rel_prefix.length() == 0 {
      name
    } else {
      rel_prefix + "/" + name
    }
    let full = path_join(dir, name)
    let is_dir = @fs.is_dir(full) catch {
      _ => false
    }
    if glob_match(pattern, rel) && !is_dir {
      out.push(rel)
    }
    if is_dir {
      walk_glob(full, rel, pattern, out, depth + 1)
    }
  }
}
