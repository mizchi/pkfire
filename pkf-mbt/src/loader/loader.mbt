// Embedded loader for evaluating a Pkl module path in-process via
// mizchi/pkl. Skips the mpkl subprocess hop by walking imports / amends
// directly and populating an AnalysisSession.
//
// Scope (deliberately narrower than cmd/mpkl/main.mbt):
//
//   - Local file paths (relative or absolute).
//   - Cached `package://host/path/name@version[#/file]` URIs, resolved
//     from `~/.cache/pkl-mbt/package-2/<host>/<path>/<name>@<version>/package/<file>`.
//     `XDG_CACHE_HOME` / `PKL_MBT_PACKAGE_CACHE` overrides honoured.
//   - `pkl:` stdlib modules (deferred to the eval-side stub).
//
// `package://` archives are downloaded in-process on a cache miss (see
// download.mbt / fetch.mbt) — no subprocess. `https://` / `http://` module
// sources are fetched directly too.
//
// Not supported (yet):
//
//   - `--module-path` overlays, project-file `amends`, dependency alias
//     rewriting.
//
// Supported as of phase 3 task 5:
//
//   - Local glob import *declarations* (`import* "sub/*.pkl" as foo`). The
//     match set is registered with the evaluator's sandbox so its native
//     `import*` handling resolves in-process. Keys use the glob-relative
//     path form Apple Pkl produces (`sub/a.pkl`). Globs over `package://` /
//     remote dirs, and inline `import*(...)` *expressions*, are not.
//
// Anything outside that scope falls back to a diagnostic.

///|
pub suberror LoaderError String derive(Show)

///|
pub fn LoaderError::message(self : LoaderError) -> String {
  let LoaderError(m) = self
  m
}

///|
pub fn package_cache_root() -> String {
  match @sys.get_env_var("PKL_MBT_PACKAGE_CACHE") {
    Some(d) => d
    None =>
      match @sys.get_env_var("XDG_CACHE_HOME") {
        Some(base) => path_join(base, "pkl-mbt/package-2")
        None =>
          match @sys.get_env_var("HOME") {
            Some(home) => path_join(home, ".cache/pkl-mbt/package-2")
            None => ".cache/pkl-mbt/package-2"
          }
      }
  }
}

///|
fn path_join(a : String, b : String) -> String {
  if a.length() == 0 {
    b
  } else if a.has_suffix("/") {
    a + b
  } else {
    a + "/" + b
  }
}

///|
fn dir_of(path : String) -> String {
  match path.rev_find("/") {
    Some(idx) =>
      if idx == 0 {
        "/"
      } else {
        path[0:idx].to_owned()
      }
    None => ""
  }
}

///|
fn is_absolute(path : String) -> Bool {
  path.has_prefix("/") || (path.length() >= 2 && path[1] == ':')
}

///|
fn normalize_path(path : String) -> String {
  // Resolve `.` / `..` segments. Preserves a leading `/`.
  let mut leading_slash = false
  let mut rest = path
  if path.has_prefix("/") {
    leading_slash = true
    rest = path[1:path.length()].to_owned()
  }
  let segs : Array[String] = []
  for seg in rest.split("/") {
    let s = seg.to_string()
    if s == "" || s == "." {
      continue
    }
    if s == ".." {
      if segs.length() > 0 && segs[segs.length() - 1] != ".." {
        let _ = segs.pop()
      } else if !leading_slash {
        segs.push(s)
      }
    } else {
      segs.push(s)
    }
  }
  let mut out = if leading_slash { "/" } else { "" }
  for i in 0..<segs.length() {
    if i > 0 {
      out = out + "/"
    }
    out = out + segs[i]
  }
  if out.length() == 0 {
    "."
  } else {
    out
  }
}

///|
fn join_relative(from : String, uri : String) -> String {
  if uri.length() == 0 {
    return uri
  }
  if is_absolute(uri) {
    return uri
  }
  if uri.has_prefix("pkl:") ||
    uri.has_prefix("package://") ||
    uri.has_prefix("https://") ||
    uri.has_prefix("http://") ||
    uri.has_prefix("file://") {
    return uri
  }
  let base = dir_of(from)
  if base.length() == 0 {
    return normalize_path(uri)
  }
  normalize_path(path_join(base, uri))
}

// ---------------------------------------------------------------------------
// package URI resolution
// ---------------------------------------------------------------------------

///|
fn parse_package_uri(uri : String) -> (String, String, String, String)? {
  // Returns (path_after_registry, name, version, file_inside_package).
  // The pkl-mbt cache layout drops the registry host segment, so for
  //   `package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.10.0#/Taskfile.pkl`
  // the on-disk path is
  //   <cache_root>/github.com/mizchi/pkfire/pkfire@0.10.0/package/Taskfile.pkl
  if !uri.has_prefix("package://") {
    return None
  }
  // NOTE: `::sha256-...` checksum suffixes are NOT stripped here. Our real
  // `pkg.pkl-lang.org` URIs carry no `::` suffix; if one ever reaches this
  // parser it must also be stripped in `package_metadata_url_from_uri` to keep
  // the read/write paths consistent.
  let after_scheme = uri["package://".length():uri.length()].to_owned()
  let (locator, file) = match after_scheme.find("#") {
    Some(idx) => {
      let l = after_scheme[0:idx].to_owned()
      let mut f = after_scheme[idx + 1:].to_owned()
      if f.has_prefix("/") {
        f = f[1:f.length()].to_owned()
      }
      (l, f)
    }
    None => (after_scheme, "")
  }
  // Drop the leading registry host segment (e.g. `pkg.pkl-lang.org/`).
  let stripped_locator = match locator.find("/") {
    Some(idx) => locator[idx + 1:locator.length()].to_owned()
    None => locator
  }
  // stripped_locator: path/.../name@version
  let at_idx = match stripped_locator.rev_find("@") {
    Some(idx) => idx
    None => return None
  }
  let pre_at = stripped_locator[0:at_idx].to_owned()
  let version = stripped_locator[at_idx + 1:].to_owned()
  let last_slash = match pre_at.rev_find("/") {
    Some(idx) => idx
    None => return None
  }
  let host_path = pre_at[0:last_slash].to_owned()
  let name = pre_at[last_slash + 1:pre_at.length()].to_owned()
  Some((host_path, name, version, file))
}

///|
fn resolve_package_uri_to_file(uri : String) -> String? {
  match parse_package_uri(uri) {
    Some((host_path, name, version, file)) => {
      let root = package_cache_root()
      let pkg_dir = path_join(
        path_join(path_join(root, host_path), name + "@" + version),
        "package",
      )
      if file.length() == 0 {
        Some(pkg_dir)
      } else {
        Some(path_join(pkg_dir, file))
      }
    }
    None => None
  }
}

// ---------------------------------------------------------------------------
// Recursive walk
// ---------------------------------------------------------------------------

///|
async fn read_module_source(path : String) -> String raise LoaderError {
  if path.has_prefix("pkl:") {
    return ""
  }
  if path.has_prefix("https://") || path.has_prefix("http://") {
    // HTTP module: fetch the source text directly (redirect-following).
    let fetched = try fetch_uri(path) catch {
      _ => raise LoaderError("failed to fetch module \{path}")
    }
    return match fetched {
      Some(s) => s
      None => raise LoaderError("failed to fetch module \{path}")
    }
  }
  if path.has_prefix("package://") {
    let fs_path = match resolve_package_uri_to_file(path) {
      Some(p) => p
      None => raise LoaderError("could not parse package URI: \{path}")
    }
    // Cache hit: read straight from cache, no network. On a miss the read
    // fails, so download the archive into the cache ONCE and retry the read.
    return @fs.read_file_to_string(fs_path) catch {
      _ => {
        download_package_uri_to_cache(path)
        @fs.read_file_to_string(fs_path) catch {
          _ =>
            raise LoaderError(
              "could not read module `\{path}` (resolved to `\{fs_path}`)",
            )
        }
      }
    }
  }
  let fs_path = if path.has_prefix("file://") {
    path["file://".length():path.length()].to_owned()
  } else {
    path
  }
  @fs.read_file_to_string(fs_path) catch {
    _ => raise LoaderError("could not read module `\{path}` (resolved to `\{fs_path}`)")
  }
}

///|
async fn load_recursive(
  session : @pkl.AnalysisSession,
  path : String,
  stack : Array[String],
  loaded : Map[String, Unit],
) -> Unit raise LoaderError {
  if path.has_prefix("pkl:") {
    return
  }
  if loaded.contains(path) {
    return
  }
  if stack_contains(stack, path) {
    return
  }
  loaded[path] = ()
  let source = read_module_source(path)
  session.set_source(path, source)
  let parsed = @pkl.parse_source(source)
  let next_stack = push_stack(stack, path)
  // amends / extends
  match parsed.program.module_relation {
    Some(relation) => {
      let resolved = join_relative(path, relation.uri)
      load_recursive(session, resolved, next_stack, loaded)
    }
    None => ()
  }
  // import declarations. Glob *declarations* (`import* "sub/*.pkl" as foo`)
  // are expanded + registered here so the evaluator's native
  // `eval_import_glob_value` resolves them in-process.
  //
  // NOTE: inline glob *expressions* (`x = import*("sub/*.pkl")` —
  // `ImportGlobExpr` in the AST body, not in `program.imports`) are not
  // pre-registered here. They evaluate through the same sandbox lookup, so
  // they'd hit `Cannot find module` unless a matching declaration already
  // registered the same `(from, pattern)`. Taskfiles use the declaration
  // form; add an AST-body walk for `ImportGlobExpr` if the expression form
  // is needed.
  for decl in parsed.program.imports {
    if decl.is_glob {
      expand_import_glob(session, path, decl.uri, next_stack, loaded)
      continue
    }
    let resolved = join_relative(path, decl.uri)
    load_recursive(session, resolved, next_stack, loaded)
  }
}

///|
/// Resolve a glob import (`import* "<pattern>"`) declared in the module at
/// `from`. Expands the pattern against the importing module's directory and
/// registers the matched module URIs with the evaluator's sandbox so
/// `eval_import_glob_value` can build the Mapping.
///
/// The registered `from` is the importing module's path verbatim — the same
/// string the evaluator stashes as `@__module_path` and looks up via
/// `sandbox_lookup_import_glob(@__module_path, pattern)`. The registered
/// `visible_uri`s are the glob-relative match paths (e.g. `sub/a.pkl`), which
/// is exactly the key form Apple Pkl's `pkl` CLI uses for an `import*`
/// Mapping (verified against the oracle).
async fn expand_import_glob(
  session : @pkl.AnalysisSession,
  from : String,
  pattern : String,
  stack : Array[String],
  loaded : Map[String, Unit],
) -> Unit raise LoaderError {
  // NOTE: glob over `package://` / `http(s)://` module dirs is not supported.
  // The matcher walks a local filesystem subtree; remote/cached package
  // contents aren't enumerated here. Fail cleanly rather than silently
  // diverging from Apple Pkl.
  if pattern.has_prefix("package://") ||
    pattern.has_prefix("https://") ||
    pattern.has_prefix("http://") ||
    from.has_prefix("package://") ||
    from.has_prefix("https://") ||
    from.has_prefix("http://") {
    raise LoaderError(
      "glob import `\{pattern}` over a non-local module dir is not supported by the embedded loader (in `\{from}`)",
    )
  }
  // Apple Pkl's `**` crosses `/` (including the in-segment `**.pkl` form) with a
  // files-first-then-recurse per-directory key order that this matcher does not
  // reproduce byte-exactly. Reject cleanly rather than silently partial-match.
  if pattern_has_doublestar(pattern) {
    raise LoaderError(
      "embedded loader does not support `**` recursive glob imports: \{pattern}",
    )
  }
  let base_dir = dir_of(from)
  let walk_root = if base_dir.length() == 0 { "." } else { base_dir }
  let matches = glob_expand_relative(walk_root, pattern) catch {
    _ =>
      raise LoaderError(
        "failed to expand glob import `\{pattern}` in `\{from}`",
      )
  }
  // Register the glob result under the exact `(from, pattern)` key the
  // evaluator will look up. Empty per-URI error map (no deferred errors).
  @pkl.register_import_glob(from, pattern, matches)
  let no_errors : Map[String, String] = Map([], capacity=0)
  @pkl.register_import_glob_errors(from, pattern, no_errors)
  // Load each matched module's source so `resolve_import(visible_uri)` —
  // which resolves `visible_uri` relative to `from` — finds it in the session.
  for visible_uri in matches {
    let resolved = join_relative(from, visible_uri)
    load_recursive(session, resolved, stack, loaded)
  }
}

///|
fn stack_contains(stack : Array[String], path : String) -> Bool {
  for item in stack {
    if item == path {
      return true
    }
  }
  false
}

///|
fn push_stack(stack : Array[String], path : String) -> Array[String] {
  let out : Array[String] = []
  for item in stack {
    out.push(item)
  }
  out.push(path)
  out
}

// ---------------------------------------------------------------------------
// Public entrypoints
// ---------------------------------------------------------------------------

///|
/// Eval a Pkl module at `path` in-process, returning whatever the
/// AnalysisSession produces. Walks the module's amends / extends chain
/// and non-glob imports recursively, populating the session from local
/// files and the cached `package://` cache directory.
pub async fn eval_module_path(path : String) -> @pkl.EvalResult raise LoaderError {
  // Clear the process-global sandbox IO cache (import_globs / read_globs / etc.)
  // so stale glob registrations from a prior eval in the same process (the
  // conformance harness, `pkf watch`) can't leak into this one.
  @pkl.reset_sandbox_io_cache()
  let session = @pkl.AnalysisSession::new()
  let loaded : Map[String, Unit] = Map([], capacity=8)
  load_recursive(session, path, [], loaded)
  session.eval_path(path)
}
