// Making a glob walk only the tree it can possibly match.
//
// `expand_glob` walked the whole repository for every wildcard pattern
// and then filtered the result. `src/**/*.mbt` listed `.mooncakes/`,
// `_build/`, `.git/` and everything else on the way to finding files
// under `src/`, and it did so once per pattern — so a plan with seven
// tasks and a few patterns each walked a 58 MB dependency tree dozens
// of times. On this repository that was the difference between
// `pkf run --dry-run ci` taking 1.5 seconds and taking a tenth of that,
// and none of the work was ever going to match.
//
// Two bounds, both derived from the pattern itself and neither of them
// a cache — so nothing can go stale, and a file another task just wrote
// is still found:
//
//   - the **root**: the literal directory components before the first
//     wildcard. `src/**/*.mbt` cannot match anything outside `src/`.
//   - the **depth**: a pattern without `**` matches a fixed number of
//     path components, so descending past that many is wasted.

///|
/// The parts of a pattern that bound the walk it needs.
struct GlobBounds {
  /// Literal directory prefix, without a trailing slash. Empty when the
  /// pattern starts with a wildcard and the whole root is in play.
  root : String
  /// The pattern with `root` stripped, which is what a path relative to
  /// the walked directory should be matched against.
  rest : String
  /// Maximum path depth below `root` worth descending to, or -1 for
  /// unbounded — which is what `**` means.
  max_depth : Int
}

///|
fn segment_has_wildcard(segment : String) -> Bool {
  segment.contains("*") || segment.contains("?") || segment.contains("[")
}

///|
/// Split a pattern into the directory it must live under and what is
/// left to match inside it.
fn glob_bounds(pattern : String) -> GlobBounds {
  let segments : Array[String] = []
  for segment in pattern.split("/") {
    segments.push(segment.to_owned())
  }
  let mut literal = 0
  while literal < segments.length() && !segment_has_wildcard(segments[literal]) {
    literal = literal + 1
  }
  // The last literal segment is only a directory prefix if something
  // follows it; `src/main.mbt` has no wildcard at all and is handled by
  // the caller's literal fast path.
  if literal >= segments.length() {
    literal = segments.length() - 1
  }
  let root_buf = StringBuilder()
  for i in 0..<literal {
    if i > 0 {
      root_buf.write_char('/')
    }
    root_buf.write_string(segments[i])
  }
  let rest_buf = StringBuilder()
  for i in literal..<segments.length() {
    if i > literal {
      rest_buf.write_char('/')
    }
    rest_buf.write_string(segments[i])
  }
  // `**` matches any number of segments, so nothing below it is out of
  // reach. Anything else matches exactly as many segments as it has.
  let mut depth = 0
  let mut unbounded = false
  for i in literal..<segments.length() {
    if segments[i] == "**" {
      unbounded = true
      break
    }
    depth = depth + 1
  }
  GlobBounds::{
    root: root_buf.to_string(),
    rest: rest_buf.to_string(),
    max_depth: if unbounded { -1 } else { depth },
  }
}

///|
/// Files under `dir`, relative to it, no deeper than `max_depth`
/// components (-1 for unbounded).
///
/// A missing directory yields nothing rather than failing: a pattern
/// naming a tree that does not exist matches zero files, which is what
/// `expand_glob` has always done with a pattern that matched nothing.
///
/// Checked with `path_kind` rather than left to `read_dir` to fail,
/// because that failure is not silent — the FFI writes `opendir: No
/// such file or directory` to stderr. Before pruning, the walk always
/// started at a directory that existed; now it starts at the pattern's
/// prefix, and `outputs { "dist/**" }` before anything has built `dist`
/// is the ordinary case, not an error worth a line of output.
fn walk_files_bounded(
  dir : String,
  max_depth : Int,
  out : Array[String],
) -> Unit {
  if path_kind(dir) is Some(TarDir) {
    walk_files_depth(dir, "", max_depth, 1, out)
  }
}

///|
fn walk_files_depth(
  dir : String,
  rel_prefix : String,
  max_depth : Int,
  depth : Int,
  out : Array[String],
) -> Unit {
  if max_depth >= 0 && depth > max_depth {
    return
  }
  let names = @fs.read_dir(dir) catch { _ => return }
  for name in names {
    if name == "." || name == ".." {
      continue
    }
    let child = join_path(dir, name)
    let rel = if rel_prefix.length() == 0 {
      name
    } else {
      rel_prefix + "/" + name
    }
    // `lstat`, not `stat`: a symlink to a directory is recorded as the
    // link, matching what `walk_tree` does for the cache, and following
    // one would let a loop walk forever.
    match path_kind(child) {
      // The child came from a listing, so it exists; recursing without
      // a second existence check is safe and saves a stat per entry.
      Some(TarDir) => walk_files_depth(child, rel, max_depth, depth + 1, out)
      Some(_) => out.push(rel)
      None => ()
    }
  }
}
