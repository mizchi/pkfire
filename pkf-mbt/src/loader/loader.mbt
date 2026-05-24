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
// Not supported (yet):
//
//   - `https://` / `http://` modules (no fetch — the caller should
//     pre-populate the package cache or use the mpkl CLI).
//   - `--module-path` overlays, project-file `amends`, dependency alias
//     rewriting, import globs.
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
        path.substring(start=0, end=idx)
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
    rest = path.substring(start=1, end=path.length())
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
  // The mpkl cache layout drops the registry host segment, so for
  //   `package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.10.0#/Taskfile.pkl`
  // the on-disk path is
  //   <cache_root>/github.com/mizchi/pkfire/pkfire@0.10.0/package/Taskfile.pkl
  if !uri.has_prefix("package://") {
    return None
  }
  let after_scheme = uri.substring(start="package://".length(), end=uri.length())
  let (locator, file) = match after_scheme.find("#") {
    Some(idx) => {
      let l = after_scheme.substring(start=0, end=idx)
      let mut f = after_scheme.substring(
        start=idx + 1,
        end=after_scheme.length(),
      )
      if f.has_prefix("/") {
        f = f.substring(start=1, end=f.length())
      }
      (l, f)
    }
    None => (after_scheme, "")
  }
  // Drop the leading registry host segment (e.g. `pkg.pkl-lang.org/`).
  let stripped_locator = match locator.find("/") {
    Some(idx) => locator.substring(start=idx + 1, end=locator.length())
    None => locator
  }
  // stripped_locator: path/.../name@version
  let at_idx = match stripped_locator.rev_find("@") {
    Some(idx) => idx
    None => return None
  }
  let pre_at = stripped_locator.substring(start=0, end=at_idx)
  let version = stripped_locator.substring(
    start=at_idx + 1,
    end=stripped_locator.length(),
  )
  let last_slash = match pre_at.rev_find("/") {
    Some(idx) => idx
    None => return None
  }
  let host_path = pre_at.substring(start=0, end=last_slash)
  let name = pre_at.substring(start=last_slash + 1, end=pre_at.length())
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
    raise LoaderError(
      "embedded loader does not fetch HTTP modules; pre-cache `\{path}` or use mpkl CLI",
    )
  }
  let fs_path = if path.has_prefix("package://") {
    match resolve_package_uri_to_file(path) {
      Some(p) => p
      None => raise LoaderError("could not parse package URI: \{path}")
    }
  } else if path.has_prefix("file://") {
    path.substring(start="file://".length(), end=path.length())
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
  // import declarations (skip glob — out of scope for embedded loader)
  for decl in parsed.program.imports {
    if decl.is_glob {
      continue
    }
    let resolved = join_relative(path, decl.uri)
    load_recursive(session, resolved, next_stack, loaded)
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
  let session = @pkl.AnalysisSession::new()
  let loaded : Map[String, Unit] = Map([], capacity=8)
  load_recursive(session, path, [], loaded)
  session.eval_path(path)
}
