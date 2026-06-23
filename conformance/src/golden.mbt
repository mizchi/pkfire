// Golden loader/capturer. Mirrors conformance/golden.go: reads/writes
// golden/<id>/{stdout,stderr,exit,fsdelta,fsdeleted}.

///|
pub struct Golden {
  stdout : String
  stderr : String
  exit : Int
  fs_delta : Array[String]
  fs_deleted : Array[String]
}

///|
fn golden_dir(root : String, s : Scenario) -> String {
  root + "/" + s.id
}

///|
/// Read a previously captured golden for scenario `s` under `root`.
pub async fn load_golden(root : String, s : Scenario) -> Golden raise {
  let dir = golden_dir(root, s)
  let stdout = read_text(dir + "/stdout")
  let exit_raw = read_text(dir + "/exit")
  let exit = match (try? @strconv.parse_int(exit_raw.trim_space())) {
    Ok(n) => n
    Err(_) => raise ScenarioError("golden \{s.id}: bad exit file")
  }
  let stderr = if @xfs.exists(dir + "/stderr") {
    read_text(dir + "/stderr")
  } else {
    ""
  }
  let fs_delta = read_delta(dir + "/fsdelta")
  let fs_deleted = read_delta(dir + "/fsdeleted")
  Golden::{ stdout, stderr, exit, fs_delta, fs_deleted }
}

///|
async fn read_text(path : String) -> String raise {
  let data = @xfs.read_file(path)
  bytes_to_string(data.binary())
}

///|
/// Read a fsdelta/fsdeleted file. A missing file yields an empty list (Go
/// leaves the slice nil, which MarshalDelta normalizes to []).
async fn read_delta(path : String) -> Array[String] {
  if not(@xfs.exists(path)) {
    return []
  }
  let raw = try? read_text(path)
  match raw {
    Err(_) => []
    Ok(text) =>
      match (try? @json.parse(text)) {
        Ok(Array(a)) => {
          let out : Array[String] = []
          for e in a {
            match e {
              String(s) => out.push(s)
              _ => ()
            }
          }
          out
        }
        _ => []
      }
  }
}

///|
/// Re-capture golden/<id>/* from a run result. Mirrors Go's CaptureGolden:
/// always writes stdout/stderr/exit; writes fsdelta/fsdeleted only when the
/// scenario produced a (possibly empty) delta is present in the result.
/// Here the runner always supplies arrays, so we write them when fsDelta is
/// contracted (matching what the Go -update produced for those scenarios).
pub async fn capture_golden(
  root : String,
  s : Scenario,
  res : RunResult,
) -> Unit raise {
  let dir = golden_dir(root, s)
  if not(@xfs.exists(dir)) {
    @xfs.mkdir(dir, recursive=true)
  }
  @xfs.write_file(dir + "/stdout", res.stdout)
  @xfs.write_file(dir + "/stderr", res.stderr)
  @xfs.write_file(dir + "/exit", "\{res.exit}\n")
  // Mirror Go's CaptureGolden EXACTLY: write fsdelta only when the run
  // created/modified at least one path (Go: `res.FSDelta != nil`), and
  // fsdeleted only when it removed at least one path. Go's DeltaPaths /
  // DeletedPaths leave the slice nil when empty, so an empty list writes NO
  // file. This keeps the committed golden set identical (e.g. hooks-install
  // carries fsdelta but no fsdeleted; clean-removes-outputs the reverse).
  if res.fs_delta.length() > 0 {
    @xfs.write_file(dir + "/fsdelta", marshal_delta(res.fs_delta))
  }
  if res.fs_deleted.length() > 0 {
    @xfs.write_file(dir + "/fsdeleted", marshal_delta(res.fs_deleted))
  }
}
