// Tests for glob-walk pruning.
//
// The bounds are an optimisation, and an optimisation that changes
// which files a pattern matches is a cache bug rather than a slow
// build: the action key would move, or worse, quietly stop covering a
// file. So the central test is differential — the pruned walk must
// find exactly what walking everything and filtering found, on the
// real repository tree, for the patterns this repo actually uses.

///|
/// What `expand_glob` did before pruning: walk the whole tree from the
/// root and match each path against the full pattern.
fn expand_glob_exhaustive(root : String, pattern : String) -> Array[String] {
  let all : Array[String] = []
  walk_files_bounded(if root.length() == 0 { "." } else { root }, -1, all)
  let out : Array[String] = []
  for rel in all {
    if glob_match(pattern, rel) {
      out.push(rel)
    }
  }
  out.sort()
  out
}

///|
fn expand_one(root : String, pattern : String) -> Array[String] {
  let seen : Map[String, Bool] = Map([], capacity=32)
  expand_glob(root, pattern, seen)
  let out : Array[String] = []
  for k, _ in seen {
    out.push(k)
  }
  out.sort()
  out
}

///|
test "pruning finds exactly what walking everything found" {
  // Run against the repository itself, so the tree has the shapes that
  // motivated the change: a deep `src/`, a wide `.mooncakes/`, and
  // patterns that reach into both.
  let patterns = [
    "src/**/*.mbt", "src/**/*.c", "src/**/moon.pkg", "src/cmd/pkf/*.mbt",
    "pkl/**/*.pkl", "examples/**/*.pkl", ".mooncakes/*/*/moon.mod",
    "conformance/src/**/*.mbt", "**/*.md", "*.pkl", "scripts/*",
    // A pattern matching nothing, and one whose directory does not
    // exist: both must be empty rather than an error.
    "src/**/*.rs", "no-such-dir/**/*.txt",
  ]
  for pattern in patterns {
    let pruned = expand_one(".", pattern)
    let exhaustive = expand_glob_exhaustive(".", pattern)
    assert_eq(pruned, exhaustive)
  }
}

///|
test "the walk root is the literal prefix before the first wildcard" {
  assert_eq(glob_bounds("src/**/*.mbt").root, "src")
  assert_eq(glob_bounds("src/**/*.mbt").rest, "**/*.mbt")
  assert_eq(glob_bounds("conformance/src/**/*.mbt").root, "conformance/src")
  // A pattern that starts with a wildcard puts the whole root in play.
  assert_eq(glob_bounds("**/*.mbt").root, "")
  assert_eq(glob_bounds("*.pkl").root, "")
  assert_eq(glob_bounds("*.pkl").rest, "*.pkl")
}

///|
test "the last literal segment is a file name, not a directory to walk" {
  // `a/b/c` has no wildcard anywhere; walking `a/b/c` as a directory
  // would find nothing. The prefix stops one short.
  assert_eq(glob_bounds("a/b/c").root, "a/b")
  assert_eq(glob_bounds("a/b/c").rest, "c")
  assert_eq(glob_bounds("dist").root, "")
  assert_eq(glob_bounds("dist").rest, "dist")
}

///|
test "depth is bounded unless the pattern says otherwise" {
  // `**` matches any number of segments, so nothing below is out of
  // reach; anything else matches exactly as many segments as it has.
  assert_eq(glob_bounds("src/**/*.mbt").max_depth, -1)
  assert_eq(glob_bounds("**/*.mbt").max_depth, -1)
  assert_eq(glob_bounds(".mooncakes/*/*/moon.mod").max_depth, 3)
  assert_eq(glob_bounds("src/*.mbt").max_depth, 1)
  assert_eq(glob_bounds("a/*/b/*/c").max_depth, 4)
}

///|
test "a wildcard inside a segment still bounds the root at its parent" {
  // `src/cmd-*/main.mbt`: the wildcard is in the second segment, so
  // `src` is still a safe walk root.
  let bounds = glob_bounds("src/cmd-*/main.mbt")
  assert_eq(bounds.root, "src")
  assert_eq(bounds.rest, "cmd-*/main.mbt")
  assert_eq(bounds.max_depth, 2)
  // A character class counts as a wildcard too.
  assert_eq(glob_bounds("src/[abc]/x.mbt").root, "src")
  assert_eq(glob_bounds("src/a?c/x.mbt").root, "src")
}

///|
test "a bounded walk stops descending, and a missing directory is empty" {
  let shallow : Array[String] = []
  walk_files_bounded("src", 1, shallow)
  for rel in shallow {
    assert_false(rel.contains("/"))
  }
  let deep : Array[String] = []
  walk_files_bounded("src", -1, deep)
  assert_true(deep.length() > shallow.length())
  // A pattern naming a tree that is not there matches nothing, which is
  // what a glob matching zero files has always done — and it does so
  // without the `opendir:` line the FFI writes when `read_dir` fails.
  // `outputs { "dist/**" }` before anything has built `dist` is the
  // ordinary case.
  let missing : Array[String] = []
  walk_files_bounded("no-such-dir-xyz", -1, missing)
  assert_eq(missing.length(), 0)
  // A file where a directory was expected is also not a walk.
  let not_a_dir : Array[String] = []
  walk_files_bounded("moon.mod", -1, not_a_dir)
  assert_eq(not_a_dir.length(), 0)
}
