// Runner: port of conformance/runner.go. Runs `bin <argv>` in an isolated
// temp dir with the fixture copied in, captures stdout/stderr/exit, and
// computes the fs delta (created/modified) and deleted paths by snapshotting
// the work tree before and after.

///|
pub struct RunResult {
  stdout : String
  stderr : String
  exit : Int
  fs_delta : Array[String]
  fs_deleted : Array[String]
}

///|
/// Execute `bin` against scenario `s` in an isolated temp dir. `repo_root`
/// is the directory the fixture path is resolved against. Mirrors Go's
/// `Run`: copy fixture -> set PKFIRE_CACHE_DIR + scenario env -> run setup
/// snippets -> snapshot -> run binary (honouring PKF_CONFORMANCE_SUBDIR) ->
/// snapshot -> diff.
pub async fn run(bin : String, s : Scenario, repo_root : String) -> RunResult {
  let tmp = @xfs.tmpdir(prefix="pkfconf-\{s.id}-")
  let work = tmp + "/work"
  let cache = tmp + "/cache"
  copy_tree(repo_root + "/" + s.fixture, work)
  @xfs.mkdir(cache, recursive=true)

  // Environment: process env + PKFIRE_CACHE_DIR + scenario env (extra_env on
  // top of the inherited environment, matching Go's os.Environ()+overrides).
  let extra : Map[String, String] = Map::new()
  extra["PKFIRE_CACHE_DIR"] = cache
  for k, v in s.env {
    extra[k] = v
  }

  // setup snippets run via bash -c in the work dir.
  for snippet in s.setup {
    let (code, _, err_data) = @process.collect_output(
      "bash",
      ["-c", snippet],
      extra_env=extra,
      cwd=work,
    )
    if code != 0 {
      let msg = bytes_to_string(err_data.binary())
      raise ScenarioError("setup \{snippet}: exit \{code}\n\{msg}")
    }
  }

  let before = snapshot_tree(work)

  // PKF_CONFORMANCE_SUBDIR runs pkf from a subdirectory of the fixture root.
  let run_dir = match s.env.get("PKF_CONFORMANCE_SUBDIR") {
    Some(sub) => work + "/" + sub
    None => work
  }
  let (exit, out_data, err_data) = @process.collect_output(
    bin,
    s.argv[:],
    extra_env=extra,
    cwd=run_dir,
  )
  let stdout = bytes_to_string(out_data.binary())
  let stderr = bytes_to_string(err_data.binary())
  let after = snapshot_tree(work)
  let result = RunResult::{
    stdout,
    stderr,
    exit,
    fs_delta: delta_paths(before, after),
    fs_deleted: deleted_paths(before, after),
  }
  ignore(try? @xfs.rmdir(tmp, recursive=true))
  result
}

///|
/// Recursively copy src dir to dst, preserving content. Modes are not
/// strictly preserved (the conformance contract does not compare modes);
/// directories are created and regular files copied byte-for-byte.
async fn copy_tree(src : String, dst : String) -> Unit {
  @xfs.mkdir(dst, recursive=true)
  let entries = @xfs.readdir(src, include_hidden=true)
  for name in entries {
    let s_path = src + "/" + name
    let d_path = dst + "/" + name
    match @xfs.kind(s_path) {
      Directory => copy_tree(s_path, d_path)
      Regular => {
        let data = @xfs.read_file(s_path)
        @xfs.write_file(d_path, data.binary())
      }
      SymLink =>
        // Resolve & copy the target's bytes (fixtures here have no symlinks;
        // mirror Go's copyTree which reads file bytes).
        match (try? @xfs.read_file(s_path)) {
          Ok(data) => @xfs.write_file(d_path, data.binary())
          Err(_) => ()
        }
      _ => ()
    }
  }
}

///|
/// Map of relative path -> sha256 hex for every regular file under root.
/// Mirrors Go's SnapshotTree.
async fn snapshot_tree(root : String) -> Map[String, String] {
  let out : Map[String, String] = Map::new()
  snapshot_into(root, "", out)
  out
}

///|
async fn snapshot_into(
  dir : String,
  rel_prefix : String,
  out : Map[String, String],
) -> Unit {
  if not(@xfs.exists(dir)) {
    return
  }
  let entries = @xfs.readdir(dir, include_hidden=true)
  for name in entries {
    let full = dir + "/" + name
    let rel = if rel_prefix == "" { name } else { rel_prefix + "/" + name }
    match @xfs.kind(full) {
      Directory => snapshot_into(full, rel, out)
      Regular => {
        let data = @xfs.read_file(full)
        out[rel] = sha256_hex(data.binary())
      }
      _ => ()
    }
  }
}

///|
/// Sorted set of paths created or modified between before and after.
/// Mirrors Go's DeltaPaths.
fn delta_paths(
  before : Map[String, String],
  after : Map[String, String],
) -> Array[String] {
  let changed : Array[String] = []
  for p, h in after {
    if before.get(p) != Some(h) {
      changed.push(p)
    }
  }
  changed.sort_by((x, y) => lex_compare(x, y))
  changed
}

///|
/// Sorted set of paths present before but absent after (deleted).
/// Mirrors Go's DeletedPaths.
fn deleted_paths(
  before : Map[String, String],
  after : Map[String, String],
) -> Array[String] {
  let deleted : Array[String] = []
  for p, _ in before {
    if after.get(p) is None {
      deleted.push(p)
    }
  }
  deleted.sort_by((x, y) => lex_compare(x, y))
  deleted
}

///|
fn sha256_hex(b : Bytes) -> String {
  let digest = @crypto.sha256(b)
  let hex = StringBuilder::new()
  for i in 0..<digest.length() {
    let byte = digest[i].to_int() & 0xff
    hex.write_char(hex_nibble(byte / 16))
    hex.write_char(hex_nibble(byte % 16))
  }
  hex.to_string()
}

///|
fn hex_nibble(n : Int) -> Char {
  if n < 10 {
    Char::from_int('0'.to_int() + n)
  } else {
    Char::from_int('a'.to_int() + (n - 10))
  }
}

///|
/// Decode UTF-8 bytes to a String, lossily (binary stdout/stderr should not
/// crash the harness; the contract compares normalized text / JSON).
fn bytes_to_string(b : Bytes) -> String {
  @utf8.decode_lossy(b[:])
}
