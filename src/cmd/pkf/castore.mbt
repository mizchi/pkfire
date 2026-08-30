// ---------------------------------------------------------------------------
// ActionCache + content-addressed store.
//
// An entry used to be one gzipped tar per action key. That is correct
// and it is what makes a cache hit a single file read — but it stores
// every output of every key in full, and outputs mostly do not change.
// Measured on a task with 300 declared outputs: editing one input file
// stored a second 8 MB archive of which 8 MB minus one file was a
// byte-identical copy of the first. Half the cache was redundant after
// a single edit, and the fraction grows with every edit after it.
//
// So the entry is split the way Bazel splits it:
//
//   ac/<key[0:2]>/<key[2:]>/result.json   what the action produced
//   blobs/<digest[0:2]>/<digest[2:]>      the bytes, named by content
//
// The manifest lists paths, modes and digests; the blobs are shared by
// every entry that produced the same bytes. Two keys whose outputs
// differ in one file now cost one file, not one tree.
//
// Blobs are immutable and named by the SHA-256 of their *uncompressed*
// content, stored gzipped. Naming on the raw digest is what makes the
// sharing work: the same bytes must land on the same name regardless of
// which run compressed them, and gzip output is not required to be
// deterministic across versions.
//
// The old single-archive layout is still read (see `legacy_entry_path`)
// so upgrading does not throw away a warm cache, and the wire format
// for the remote cache is unchanged — a remote is still one archive per
// key, built from the blobs on push and ingested into them on fetch.
// ---------------------------------------------------------------------------

///|
/// Manifest schema version. A reader that does not recognise the value
/// treats the entry as a miss rather than guessing at its shape.
const AC_VERSION : Int = 1

///|
/// Manifest filename under `ac/<key>/`.
const AC_RESULT_FILE : String = "result.json"

///|
/// One thing an action produced.
///
/// `digest` is empty for anything that has no content of its own — a
/// directory, a symlink — and those carry `target` instead. Keeping all
/// three kinds in one list preserves the ordering the archive had, which
/// matters: a directory must be created before the files inside it.
struct AcOutput {
  path : String
  kind : TarKind
  /// Hex SHA-256 of the uncompressed content. Empty for dir/symlink.
  digest : String
  /// Uncompressed size, for the expansion cap. Zero for dir/symlink.
  size : Int64
  mode : Int
}

///|
/// What an action produced, as recorded under its key.
struct ActionResult {
  outputs : Array[AcOutput]
  /// Digests of the captured streams, or "" when the action was silent.
  stdout_digest : String
  stderr_digest : String
}

///|
/// `<root>/ac/<key[0:2]>/<key[2:]>`.
fn ac_dir(key : String) -> String {
  let head = key[0:2].to_owned()
  let tail = key[2:key.length()].to_owned()
  join_path(join_path(join_path(cache_root(), "ac"), head), tail)
}

///|
/// `<root>/blobs/<digest[0:2]>/<digest[2:]>`.
fn blob_path(digest : String) -> String {
  let head = digest[0:2].to_owned()
  let tail = digest[2:digest.length()].to_owned()
  join_path(join_path(join_path(cache_root(), "blobs"), head), tail)
}

///|
/// The pre-split entry for `key`, still read on lookup.
///
/// A cache is worth most when it is warm, and an upgrade that silently
/// empties one costs every user a full rebuild. Entries in the old
/// layout keep working until they age out; nothing writes there again.
fn legacy_entry_path(key : String) -> String {
  join_path(entry_dir(key), CACHE_ENTRY_FILE)
}

// ---------------------------------------------------------------------------
// Blobs
// ---------------------------------------------------------------------------

///|
/// Write `content` into the blob store, returning its digest.
///
/// A blob already present is left alone: it is named by its own hash,
/// so what is there is what we would write. Publishing goes through a
/// temp file and a rename for the same reason entries always did — a
/// reader must never see a half-written blob.
async fn blob_put(content : Bytes) -> String? {
  let digest = hex_encode(@crypto.sha256(content))
  let path = blob_path(digest)
  if @fs.path_exists(path) {
    return Some(digest)
  }
  mkdir_p(dirname(path))
  let gz = @zlib.gzip_compress(content)
  let tmp = path +
    ".tmp." +
    current_pid().to_string() +
    "." +
    next_store_seq().to_string()
  @fs.write_bytes_to_file(tmp, gz) catch {
    _ => return None
  }
  @xfs.rename(tmp.view(), path.view(), replace=true) catch {
    _ => {
      @fs.remove_file(tmp) catch { _ => () }
      return None
    }
  }
  Some(digest)
}

///|
/// Read a blob back, or `None` when it is missing or unreadable.
fn blob_get(digest : String) -> Bytes? {
  let gz = @fs.read_file_to_bytes(blob_path(digest)) catch { _ => return None }
  let bytes = @zlib.gzip_decompress(gz) catch { _ => return None }
  Some(bytes)
}

///|
fn blob_exists(digest : String) -> Bool {
  @fs.path_exists(blob_path(digest))
}

// ---------------------------------------------------------------------------
// Manifest encoding
// ---------------------------------------------------------------------------

///|
fn ac_kind_name(kind : TarKind) -> String {
  match kind {
    TarFile => "file"
    TarDir => "dir"
    TarSymlink(_) => "symlink"
  }
}

///|
fn ac_result_to_json(result : ActionResult) -> Json {
  let arr : Array[Json] = []
  for out in result.outputs {
    let o : Map[String, Json] = Map([], capacity=6)
    o["path"] = Json::string(out.path)
    o["kind"] = Json::string(ac_kind_name(out.kind))
    o["mode"] = Json::number(out.mode.to_double())
    match out.kind {
      TarSymlink(target) => o["target"] = Json::string(target)
      TarFile => {
        o["digest"] = Json::string(out.digest)
        o["size"] = Json::number(out.size.to_double())
      }
      TarDir => ()
    }
    arr.push(Json::object(o))
  }
  let root : Map[String, Json] = Map([], capacity=4)
  root["version"] = Json::number(AC_VERSION.to_double())
  root["outputs"] = Json::array(arr)
  if result.stdout_digest.length() > 0 {
    root["stdout"] = Json::string(result.stdout_digest)
  }
  if result.stderr_digest.length() > 0 {
    root["stderr"] = Json::string(result.stderr_digest)
  }
  Json::object(root)
}

///|
/// Parse a manifest, or `None` when it is not one this reader
/// understands. Every failure here is a cache miss, never a partial
/// restore: an entry we cannot read in full is an entry we do not have.
fn ac_result_of_json(value : Json) -> ActionResult? {
  guard value is Object(root) else { return None }
  guard root.get("version") is Some(Number(v, ..)) else { return None }
  if v.to_int() != AC_VERSION {
    return None
  }
  guard root.get("outputs") is Some(Array(items)) else { return None }
  let outputs : Array[AcOutput] = []
  for item in items {
    guard item is Object(o) else { return None }
    guard o.get("path") is Some(String(path)) else { return None }
    guard o.get("kind") is Some(String(kind_name)) else { return None }
    let mode = match o.get("mode") {
      Some(Number(m, ..)) => m.to_int()
      _ => 0o644
    }
    match kind_name {
      "file" => {
        guard o.get("digest") is Some(String(digest)) else { return None }
        let size = match o.get("size") {
          Some(Number(s, ..)) => s.to_int64()
          _ => 0L
        }
        outputs.push(AcOutput::{ path, kind: TarFile, digest, size, mode })
      }
      "dir" =>
        outputs.push(AcOutput::{
          path,
          kind: TarDir,
          digest: "",
          size: 0L,
          mode,
        })
      "symlink" => {
        guard o.get("target") is Some(String(target)) else { return None }
        outputs.push(AcOutput::{
          path,
          kind: TarSymlink(target),
          digest: "",
          size: 0L,
          mode,
        })
      }
      _ => return None
    }
  }
  let stdout_digest = match root.get("stdout") {
    Some(String(d)) => d
    _ => ""
  }
  let stderr_digest = match root.get("stderr") {
    Some(String(d)) => d
    _ => ""
  }
  Some(ActionResult::{ outputs, stdout_digest, stderr_digest })
}

///|
/// Read the manifest stored under `key`.
fn ac_load(key : String) -> ActionResult? {
  let path = join_path(ac_dir(key), AC_RESULT_FILE)
  let bytes = @fs.read_file_to_bytes(path) catch { _ => return None }
  let text = @utf8.decode(bytes) catch { _ => return None }
  let value = @json.parse(text) catch { _ => return None }
  ac_result_of_json(value)
}

///|
/// Publish a manifest under `key`, last, by atomic rename.
///
/// Written after every blob it names, so a manifest that exists is one
/// whose contents are all already on disk. The reverse order would let
/// a crash leave an entry that looks like a hit and restores nothing.
async fn ac_store(key : String, result : ActionResult) -> Bool {
  let dir = ac_dir(key)
  mkdir_p(dir)
  let final_path = join_path(dir, AC_RESULT_FILE)
  let tmp = final_path +
    ".tmp." +
    current_pid().to_string() +
    "." +
    next_store_seq().to_string()
  let text = ac_result_to_json(result).stringify()
  @fs.write_bytes_to_file(tmp, @utf8.encode(text)) catch {
    _ => return false
  }
  @xfs.rename(tmp.view(), final_path.view(), replace=true) catch {
    _ => {
      @fs.remove_file(tmp) catch { _ => () }
      return false
    }
  }
  true
}

// ---------------------------------------------------------------------------
// Store / restore
// ---------------------------------------------------------------------------

///|
/// Reject a manifest before a single byte reaches the filesystem.
///
/// Validation is separate from materialization, and complete, because a
/// bad member found halfway through would leave a half-restored tree
/// that the next run reads as real output. A remote entry is untrusted
/// input; a local one can still be corrupt.
///
/// Returns the reason to report, or `None` when the manifest is safe.
fn ac_reject_reason(result : ActionResult) -> String? {
  let mut total = 0L
  for out in result.outputs {
    if !is_safe_archive_path(out.path) {
      return Some("unsafe path `\{out.path}`")
    }
    if out.kind is TarSymlink(target) &&
      !is_safe_symlink_target(out.path, target) {
      return Some("symlink `\{out.path}` escapes the workspace (-> `\{target}`)")
    }
    if out.kind is TarFile {
      // A manifest naming a blob nobody stored is an entry that would
      // restore an incomplete tree. There is no partial hit.
      if !blob_exists(out.digest) {
        return Some("missing blob for `\{out.path}`")
      }
      total = total + out.size
      if total > CACHE_MAX_EXPANDED_BYTES {
        return Some(
          "expands past the \{CACHE_MAX_EXPANDED_BYTES} byte cap",
        )
      }
    }
  }
  None
}

///|
/// Materialize `result` under `root`.
///
/// Assumes `ac_reject_reason` already passed. Returns false on an I/O
/// failure, which the caller must treat as a miss and execute the
/// action — a restore that gave up halfway has left the workspace in a
/// state no key describes.
async fn ac_materialize(result : ActionResult, root : String) -> Bool {
  for out in result.outputs {
    let dst = if root.length() == 0 || root == "." {
      out.path
    } else {
      join_path(root, out.path)
    }
    let parent = dirname(dst)
    if parent.length() > 0 {
      mkdir_p(parent)
    }
    match out.kind {
      TarDir => mkdir_p(dst)
      TarSymlink(target) => {
        // Whatever a previous run left cannot be linked over, so clear
        // it first. No chmod after: a symlink's own mode means nothing
        // and chmod would follow the link and change its target.
        @fs.remove_file(dst) catch { _ => () }
        @xfs.symlink(target=target.view(), dst.view()) catch {
          _ => return false
        }
        continue
      }
      TarFile => {
        let content = match blob_get(out.digest) {
          Some(b) => b
          None => return false
        }
        @fs.write_bytes_to_file(dst, content) catch {
          _ => return false
        }
      }
    }
    // Best-effort: a read-only target FS must not abort a restore that
    // otherwise succeeded.
    @xfs.chmod(dst.view(), out.mode) catch { _ => () }
  }
  true
}

///|
/// Store `members` (relative path + kind, rooted at `root`) under `key`.
///
/// Every file becomes a blob; the manifest is written last, so a crash
/// mid-store leaves orphan blobs — which `pkf cache prune` sweeps — and
/// never an entry that claims content nobody wrote.
async fn ac_store_outputs(
  key : String,
  root : String,
  members : Array[(String, TarKind)],
  logs~ : CapturedLogs? = None,
) -> Bool {
  let outputs : Array[AcOutput] = []
  for entry in members {
    let rel = entry.0
    let src = if root.length() == 0 || root == "." {
      rel
    } else {
      join_path(root, rel)
    }
    match entry.1 {
      TarDir =>
        outputs.push(AcOutput::{
          path: rel,
          kind: TarDir,
          digest: "",
          size: 0L,
          mode: detect_file_mode(src),
        })
      TarSymlink(target) =>
        outputs.push(AcOutput::{
          path: rel,
          kind: TarSymlink(target),
          digest: "",
          size: 0L,
          mode: 0o777,
        })
      TarFile => {
        let content = @fs.read_file_to_bytes(src) catch { _ => continue }
        let digest = match blob_put(content) {
          Some(d) => d
          None => return false
        }
        outputs.push(AcOutput::{
          path: rel,
          kind: TarFile,
          digest,
          size: content.length().to_int64(),
          mode: detect_file_mode(src),
        })
      }
    }
  }
  // The captured streams are blobs too, so a task whose output did not
  // change between two keys stores its transcript once.
  let mut stdout_digest = ""
  let mut stderr_digest = ""
  match logs {
    Some(captured) => {
      if captured.stdout.length() > 0 {
        stdout_digest = match blob_put(captured.stdout) {
          Some(d) => d
          None => return false
        }
      }
      if captured.stderr.length() > 0 {
        stderr_digest = match blob_put(captured.stderr) {
          Some(d) => d
          None => return false
        }
      }
    }
    None => ()
  }
  ac_store(key, ActionResult::{ outputs, stdout_digest, stderr_digest })
}

///|
/// Restore the entry for `key` from the split store.
///
/// `None` means there is no manifest — the caller falls back to the
/// pre-split archive before concluding a miss. `Some(false)` means
/// there is one and it is unusable, which is a miss with a reason
/// already reported.
async fn ac_restore(
  key : String,
  root : String,
  logs~ : CapturedLogs? = None,
) -> Bool? {
  let result = match ac_load(key) {
    Some(r) => r
    None => return None
  }
  match ac_reject_reason(result) {
    Some(why) => {
      eprintln("pkf: cache entry \{key[0:8].to_owned()} rejected: \{why}")
      return Some(false)
    }
    None => ()
  }
  match logs {
    Some(sink) => {
      if result.stdout_digest.length() > 0 {
        match blob_get(result.stdout_digest) {
          Some(b) => sink.stdout = b
          None => return Some(false)
        }
      }
      if result.stderr_digest.length() > 0 {
        match blob_get(result.stderr_digest) {
          Some(b) => sink.stderr = b
          None => return Some(false)
        }
      }
    }
    None => ()
  }
  Some(ac_materialize(result, root))
}

// ---------------------------------------------------------------------------
// Archive bridge
//
// The remote cache stays one gzipped tar per key. Splitting the wire
// format too would turn one round-trip per entry into one per file, and
// a shared remote may still be serving clients that predate this
// change. So the archive is built from the blobs on push and taken
// apart into them on fetch; the split is local.
// ---------------------------------------------------------------------------

///|
/// Rebuild the archive for a locally stored entry, for upload.
///
/// Falls back to the pre-split file when that is all this key has, so a
/// warm old cache still populates a remote.
fn entry_archive_bytes(key : String) -> Bytes? {
  let result = match ac_load(key) {
    Some(r) => r
    None => {
      let legacy = @fs.read_file_to_bytes(legacy_entry_path(key)) catch {
        _ => return None
      }
      return Some(legacy)
    }
  }
  let tb = tar_new()
  for out in result.outputs {
    match out.kind {
      TarDir => tar_write_dir_entry(tb, out.path, out.mode)
      TarSymlink(target) => tar_write_symlink_entry(tb, out.path, target)
      TarFile => {
        let content = match blob_get(out.digest) {
          Some(b) => b
          None => return None
        }
        tar_write_entry(tb, out.path, content, out.mode)
      }
    }
  }
  if result.stdout_digest.length() > 0 {
    match blob_get(result.stdout_digest) {
      Some(b) => tar_write_entry(tb, LOG_STDOUT_MEMBER, b, 0o644)
      None => return None
    }
  }
  if result.stderr_digest.length() > 0 {
    match blob_get(result.stderr_digest) {
      Some(b) => tar_write_entry(tb, LOG_STDERR_MEMBER, b, 0o644)
      None => return None
    }
  }
  Some(@zlib.gzip_compress(tar_finish(tb)))
}

///|
/// Take a fetched archive apart into blobs and a manifest under `key`.
///
/// Validation happens here rather than at restore time so a remote
/// entry that fails it never reaches the blob store at all. Returns
/// false on anything malformed or unsafe, which the caller reports as a
/// miss.
async fn ac_ingest_archive(key : String, gz : Bytes) -> Bool {
  let tar = @zlib.gzip_decompress(gz) catch { _ => return false }
  let entries = match tar_iter(tar) {
    TarOk(es) => es
    TarMalformed(why) => {
      eprintln("pkf: cache entry \{key[0:8].to_owned()} rejected: \{why}")
      return false
    }
  }
  let outputs : Array[AcOutput] = []
  let mut stdout_bytes : Bytes? = None
  let mut stderr_bytes : Bytes? = None
  let mut total = 0L
  for entry in entries {
    // Reserved members are this runner's own bookkeeping, never part of
    // the output tree, so they bypass the path checks and are never
    // written into the workspace.
    if is_log_member(entry.name) {
      if entry.name == LOG_STDOUT_MEMBER {
        stdout_bytes = Some(entry.content)
      } else if entry.name == LOG_STDERR_MEMBER {
        stderr_bytes = Some(entry.content)
      }
      continue
    }
    if !is_safe_archive_path(entry.name) {
      eprintln(
        "pkf: cache entry \{key[0:8].to_owned()} rejected: unsafe path `\{entry.name}`",
      )
      return false
    }
    if entry.kind is TarSymlink(target) &&
      !is_safe_symlink_target(entry.name, target) {
      eprintln(
        "pkf: cache entry \{key[0:8].to_owned()} rejected: symlink `\{entry.name}` escapes the workspace (-> `\{target}`)",
      )
      return false
    }
    total = total + entry.content.length().to_int64()
    if total > CACHE_MAX_EXPANDED_BYTES {
      eprintln(
        "pkf: cache entry \{key[0:8].to_owned()} rejected: expands past the \{CACHE_MAX_EXPANDED_BYTES} byte cap",
      )
      return false
    }
    match entry.kind {
      TarFile => {
        let digest = match blob_put(entry.content) {
          Some(d) => d
          None => return false
        }
        outputs.push(AcOutput::{
          path: entry.name,
          kind: TarFile,
          digest,
          size: entry.content.length().to_int64(),
          mode: entry.mode,
        })
      }
      TarDir =>
        outputs.push(AcOutput::{
          path: entry.name,
          kind: TarDir,
          digest: "",
          size: 0L,
          mode: entry.mode,
        })
      TarSymlink(target) =>
        outputs.push(AcOutput::{
          path: entry.name,
          kind: TarSymlink(target),
          digest: "",
          size: 0L,
          mode: entry.mode,
        })
    }
  }
  let mut stdout_digest = ""
  let mut stderr_digest = ""
  match stdout_bytes {
    Some(b) =>
      stdout_digest = match blob_put(b) {
        Some(d) => d
        None => return false
      }
    None => ()
  }
  match stderr_bytes {
    Some(b) =>
      stderr_digest = match blob_put(b) {
        Some(d) => d
        None => return false
      }
    None => ()
  }
  ac_store(key, ActionResult::{ outputs, stdout_digest, stderr_digest })
}

// ---------------------------------------------------------------------------
// Housekeeping
//
// Splitting the entry splits the bookkeeping with it. An action cache
// entry is now a manifest naming blobs it does not own — several
// entries name the same blob — so removing an entry frees nothing by
// itself. What frees space is the sweep afterwards, and the honest
// number to report is what the sweep actually deleted, not the sum of
// the removed entries' content (which double-counts everything shared).
// ---------------------------------------------------------------------------

///|
/// Visit every action cache entry as `(key, dir, mtime)`.
fn walk_ac_entries(cb : (String, String, Int64) -> Unit) -> Unit {
  let root = join_path(cache_root(), "ac")
  if !@fs.path_exists(root) {
    return
  }
  let prefixes = @fs.read_dir(root) catch { _ => return }
  for prefix in prefixes {
    if prefix.length() != 2 {
      continue
    }
    let prefix_dir = join_path(root, prefix)
    if !(@fs.is_dir(prefix_dir) catch { _ => false }) {
      continue
    }
    let rests = @fs.read_dir(prefix_dir) catch { _ => continue }
    for rest in rests {
      let dir = join_path(prefix_dir, rest)
      if !(@fs.is_dir(dir) catch { _ => false }) {
        continue
      }
      let manifest = join_path(dir, AC_RESULT_FILE)
      let path_z = @utf8.encode(manifest + "\u{00}")
      cb(prefix + rest, dir, file_mtime_sec(path_z))
    }
  }
}

///|
/// Visit every blob as `(digest, path, size)`.
fn walk_blobs(cb : (String, String, Int64) -> Unit) -> Unit {
  let root = join_path(cache_root(), "blobs")
  if !@fs.path_exists(root) {
    return
  }
  let prefixes = @fs.read_dir(root) catch { _ => return }
  for prefix in prefixes {
    if prefix.length() != 2 {
      continue
    }
    let prefix_dir = join_path(root, prefix)
    if !(@fs.is_dir(prefix_dir) catch { _ => false }) {
      continue
    }
    let names = @fs.read_dir(prefix_dir) catch { _ => continue }
    for name in names {
      // A temp file from a store that died before its rename is not a
      // blob; it is swept as unreferenced like anything else, since
      // nothing can name it.
      let path = join_path(prefix_dir, name)
      let path_z = @utf8.encode(path + "\u{00}")
      let size = file_size_bytes(path_z)
      cb(prefix + name, path, if size < 0L { 0L } else { size })
    }
  }
}

///|
/// Every digest named by an action cache entry, skipping `skip`.
///
/// `skip` is how a dry run asks "what would be unreferenced if these
/// entries went away" without removing anything first.
fn referenced_blobs(skip~ : Map[String, Bool] = Map([], capacity=0)) -> Map[
  String,
  Bool,
] {
  let seen : Map[String, Bool] = Map([], capacity=64)
  walk_ac_entries(fn(key, _, _) {
    if skip.contains(key) {
      return
    }
    match ac_load(key) {
      Some(result) => {
        for out in result.outputs {
          if out.digest.length() > 0 {
            seen[out.digest] = true
          }
        }
        if result.stdout_digest.length() > 0 {
          seen[result.stdout_digest] = true
        }
        if result.stderr_digest.length() > 0 {
          seen[result.stderr_digest] = true
        }
      }
      // An unreadable manifest names nothing this sweep can see. It is
      // already a miss at lookup, so treating it as holding no
      // references is the same answer from both directions.
      None => ()
    }
  })
  seen
}

///|
/// Delete every blob no entry names, returning `(count, bytes)`.
///
/// With `dry_run` the same numbers come back and nothing is removed.
fn sweep_blobs(
  skip~ : Map[String, Bool] = Map([], capacity=0),
  dry_run~ : Bool = false,
) -> (Int, Int64) {
  let live = referenced_blobs(skip~)
  let mut count = 0
  let mut bytes = 0L
  walk_blobs(fn(digest, path, size) {
    if live.contains(digest) {
      return
    }
    count = count + 1
    bytes = bytes + size
    if !dry_run {
      @fs.remove_file(path) catch { _ => () }
    }
  })
  (count, bytes)
}
