// Reusing a Pkl evaluation.
//
// Every `pkf` invocation re-evaluates the Taskfile from source. On this
// repository that is ~164 ms of a ~186 ms fully-cached run — about 85%
// of the work of a command that, by construction, has nothing to do.
// The action cache makes the *tasks* free and then pays that toll
// anyway, on every `run`, `list`, `graph`, `explain` and `affected`.
//
// The evaluation is a pure function of the modules it read, so it can be
// memoized — and the loader already knows exactly which modules those
// were, because it walks `amends` / `extends` / `import` (glob imports
// included) to seed the evaluator. Keying on what the loader actually
// touched is the difference between a sound cache and a heuristic that
// scans for import lines and misses one.
//
// A stale plan is far worse than a slow one: it would run yesterday's
// commands with yesterday's inputs and report success. So the entry
// records what it depended on and every lookup re-validates all of it,
// and anything unexpected — an unreadable module, a malformed entry —
// is a miss rather than a guess.

///|
/// Bump when the entry format or what goes into it changes.
const EVAL_CACHE_VERSION : String = "pkfire-eval-v1"

///|
/// Where evaluations are memoized, under the same root as action
/// entries so `pkf cache clear` reclaims both.
fn eval_cache_dir() -> String {
  join_path(cache_root(), "eval")
}

///|
/// What one cached evaluation depended on.
struct EvalDeps {
  /// (module path, content digest) for every module the loader read.
  modules : Array[(String, String)]
  /// (directory, digest of its sorted `.pkl` entry names) for every
  /// directory containing one of those modules.
  ///
  /// A glob import — `import* "rules/*.pkl"` — expands at load time, so
  /// a *new* file matching it belongs in the graph even though no
  /// existing module's bytes changed. Nothing in `modules` would notice
  /// that. Hashing the listing does, and it does so without the entry
  /// having to know which imports were globs.
  ///
  /// Only module names are hashed. See `dir_listing_digest`.
  dirs : Array[(String, String)]
}

///|
/// Digest of a directory's sorted *module* entry names.
///
/// Only names that could be reached by a module glob are hashed —
/// `import* "rules/*.pkl"` can only ever match a `.pkl` file. Hashing
/// the whole listing instead makes the entry depend on everything that
/// shares a directory with a module, and the entry point's directory is
/// the project root: `.pkf-cache` appearing there, a `dist/` being
/// written, an editor's swap file, all invalidated an evaluation that
/// none of them could affect. With `PKFIRE_MBT_CACHE_DIR=.pkf-cache` —
/// the documented layout — that meant *every build* invalidated the
/// evaluation cache, so a warm plan cost the full evaluation again.
///
/// Narrowing to `.pkl` keeps what the digest is for: a new module
/// matching a glob still changes the listing, with nothing else able
/// to.
fn dir_listing_digest(dir : String) -> String {
  let names = @fs.read_dir(dir) catch { _ => [] }
  let sorted : Array[String] = []
  for name in names {
    if name.has_suffix(".pkl") {
      sorted.push(name)
    }
  }
  sorted.sort()
  let buf = StringBuilder()
  for name in sorted {
    buf.write_string(name)
    buf.write_char('\u{00}')
  }
  hex_encode(@crypto.sha256(@utf8.encode(buf.to_string())))
}

///|
/// Record what `modules` implies about the filesystem right now.
///
/// Returns `None` if any module cannot be read: an evaluation whose
/// dependencies cannot all be pinned must not be cached, because the
/// unpinned one is exactly the one that could change without anyone
/// noticing.
fn eval_deps_of(modules : Array[String]) -> EvalDeps? {
  let recorded : Array[(String, String)] = []
  let seen_dirs : Map[String, Bool] = Map([], capacity=8)
  let dirs : Array[(String, String)] = []
  for module_path in modules {
    // Only plain filesystem modules can be pinned by content. A
    // `package://` URI resolves to a file in the package cache and is
    // version-pinned by its own text, but the loader hands back the URI
    // rather than the path — so those are recorded by their URI, which
    // cannot change meaning without changing.
    if module_path.contains("://") {
      recorded.push((module_path, "uri"))
      continue
    }
    if !@fs.path_exists(module_path) {
      return None
    }
    recorded.push((module_path, hex_encode(hash_file(module_path))))
    let dir = dirname(module_path)
    let key = if dir.length() == 0 { "." } else { dir }
    if !seen_dirs.contains(key) {
      seen_dirs[key] = true
      dirs.push((key, dir_listing_digest(key)))
    }
  }
  recorded.sort_by(fn(a, b) { lex_cmp(a.0, b.0) })
  dirs.sort_by(fn(a, b) { lex_cmp(a.0, b.0) })
  Some(EvalDeps::{ modules: recorded, dirs })
}

///|
/// Cache slot for a Taskfile.
///
/// Keyed on the entry point's identity and bytes only. What it *reads*
/// cannot go into the key without evaluating first, so the entry
/// records its dependencies and the lookup re-validates them — which
/// also means one Taskfile occupies one slot rather than accumulating
/// one per historical dependency set.
fn eval_cache_slot(taskfile : String) -> String? {
  if !@fs.path_exists(taskfile) {
    return None
  }
  let buf = StringBuilder()
  buf.write_string(EVAL_CACHE_VERSION)
  buf.write_char('\u{00}')
  buf.write_string(taskfile)
  buf.write_char('\u{00}')
  buf.write_string(hex_encode(hash_file(taskfile)))
  Some(hex_encode(@crypto.sha256(@utf8.encode(buf.to_string()))))
}

///|
/// Serialize an entry: a header naming what it depended on, a blank
/// separator, then the rendered JSON verbatim.
///
/// Line-based rather than JSON so the payload — itself JSON, and large
/// — is stored as-is instead of being escaped into a string and
/// unescaped on every hit.
fn encode_eval_entry(deps : EvalDeps, rendered : String) -> String {
  let buf = StringBuilder()
  buf.write_string(EVAL_CACHE_VERSION)
  buf.write_char('\n')
  for pair in deps.modules {
    buf.write_string("M ")
    buf.write_string(pair.1)
    buf.write_char(' ')
    buf.write_string(pair.0)
    buf.write_char('\n')
  }
  for pair in deps.dirs {
    buf.write_string("D ")
    buf.write_string(pair.1)
    buf.write_char(' ')
    buf.write_string(pair.0)
    buf.write_char('\n')
  }
  buf.write_char('\n')
  buf.write_string(rendered)
  buf.to_string()
}

///|
/// The rendered JSON of a still-valid entry, or `None`.
///
/// Every recorded dependency is re-checked. A module whose bytes moved,
/// a directory that gained or lost a file, a header line that does not
/// parse, a version that does not match — all of them are a miss. The
/// only outcome this function may produce is "the evaluation you are
/// about to do would return exactly this".
fn decode_eval_entry(text : String) -> String? {
  let separator = text.find("\n\n")
  let split_at = match separator {
    Some(i) => i
    None => return None
  }
  let header = text[0:split_at].to_owned()
  let rendered = text[split_at + 2:text.length()].to_owned()
  let mut first = true
  for line in header.split("\n") {
    let entry = line.to_owned()
    if first {
      first = false
      if entry != EVAL_CACHE_VERSION {
        return None
      }
      continue
    }
    if entry.length() < 3 {
      return None
    }
    let kind = entry[0:1].to_owned()
    let rest = entry[2:entry.length()].to_owned()
    let space = match rest.find(" ") {
      Some(i) => i
      None => return None
    }
    let digest = rest[0:space].to_owned()
    let path = rest[space + 1:rest.length()].to_owned()
    let current = if kind == "M" {
      if digest == "uri" {
        // A version-pinned URI cannot change meaning without changing
        // its own text, which is part of the recorded path.
        "uri"
      } else if @fs.path_exists(path) {
        hex_encode(hash_file(path))
      } else {
        return None
      }
    } else if kind == "D" {
      dir_listing_digest(path)
    } else {
      return None
    }
    if current != digest {
      return None
    }
  }
  Some(rendered)
}

///|
/// Whether evaluations may be reused at all.
///
/// An escape hatch that costs nothing to have and is the first thing
/// anyone will reach for if this cache is ever wrong.
fn eval_cache_enabled() -> Bool {
  not_set(@env.get_env_var("PKFIRE_MBT_NO_EVAL_CACHE"))
}

///|
fn not_set(value : String?) -> Bool {
  match value {
    Some("") => true
    Some(_) => false
    None => true
  }
}

///|
/// Look up a memoized evaluation of `taskfile`.
fn eval_cache_load(taskfile : String) -> String? {
  if !eval_cache_enabled() {
    return None
  }
  let slot = match eval_cache_slot(taskfile) {
    Some(s) => s
    None => return None
  }
  let path = join_path(eval_cache_dir(), slot)
  let text = @fs.read_file_to_string(path) catch { _ => return None }
  decode_eval_entry(text)
}

///|
/// Memoize `rendered` as the evaluation of `taskfile`, which read
/// `modules`.
///
/// Best-effort: a store that fails costs a re-evaluation next time and
/// nothing else, so it is never worth failing a command over.
async fn eval_cache_store(
  taskfile : String,
  modules : Array[String],
  rendered : String,
) -> Unit {
  if !eval_cache_enabled() {
    return
  }
  let slot = match eval_cache_slot(taskfile) {
    Some(s) => s
    None => return
  }
  let deps = match eval_deps_of(modules) {
    Some(d) => d
    None => return
  }
  let dir = eval_cache_dir()
  mkdir_p(dir)
  let final_path = join_path(dir, slot)
  // Temp + rename, so a reader never sees half an entry — the same
  // publish an action entry uses, for the same reason.
  let tmp_path = final_path +
    ".tmp." +
    current_pid().to_string() +
    "." +
    next_store_seq().to_string()
  @fs.write_bytes_to_file(
    tmp_path,
    @utf8.encode(encode_eval_entry(deps, rendered)),
  ) catch {
    _ => return
  }
  @xfs.rename(tmp_path.view(), final_path.view(), replace=true) catch {
    _ => @fs.remove_file(tmp_path) catch { _ => () }
  }
}
