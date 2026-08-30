// Tests for the ActionCache + CAS split.
//
// The failure this store can have is silent and expensive: a hit that
// restores the wrong tree, or an incomplete one, is a build that
// succeeds with the wrong bytes. So these pin the round trip and the
// refusals — every way an entry can stop being whole has to read as a
// miss rather than as a partial restore. The end-to-end paths (a real
// task hitting, a legacy entry still hitting, blob sharing across two
// keys) are exercised by the `cas-*` conformance scenarios.

///|
/// Run `body` with the cache root pointed at a scratch directory.
///
/// The body is async because publishing a blob or a manifest ends in a
/// rename, and the only rename available is the event loop's. Driving
/// it from a synchronous test is what `run_async_main` is for.
fn with_cache_root(dir : String, body : async () -> Unit) -> Unit {
  let previous = @env.get_env_var("PKFIRE_MBT_CACHE_DIR")
  @env.set_env_var("PKFIRE_MBT_CACHE_DIR", dir)
  @async.run_async_main(body)
  match previous {
    Some(v) => @env.set_env_var("PKFIRE_MBT_CACHE_DIR", v)
    None => @env.set_env_var("PKFIRE_MBT_CACHE_DIR", dir)
  }
}

///|
fn scratch(name : String) -> String {
  let base = match @env.get_env_var("TMPDIR") {
    Some(d) => d
    None => "/tmp"
  }
  let dir = join_path(base, "pkf-castore-" + name)
  rm_rf(dir)
  mkdir_p(dir)
  dir
}

///|
fn file_out(path : String, digest : String, size : Int64) -> AcOutput {
  AcOutput::{ path, kind: TarFile, digest, size, mode: 0o644 }
}

///|
fn result_of(outputs : Array[AcOutput]) -> ActionResult {
  ActionResult::{ outputs, stdout_digest: "", stderr_digest: "" }
}

///|
test "a manifest survives the JSON round trip with every member kind" {
  // Mixed kinds in one list, because the order is load-bearing: a
  // directory has to come back before the file inside it.
  let original = ActionResult::{
    outputs: [
      AcOutput::{
        path: "out",
        kind: TarDir,
        digest: "",
        size: 0L,
        mode: 0o755,
      },
      AcOutput::{
        path: "out/app",
        kind: TarFile,
        digest: "a".repeat(64),
        size: 1234L,
        mode: 0o755,
      },
      AcOutput::{
        path: "out/link",
        kind: TarSymlink("app"),
        digest: "",
        size: 0L,
        mode: 0o777,
      },
    ],
    stdout_digest: "b".repeat(64),
    stderr_digest: "c".repeat(64),
  }
  let back = ac_result_of_json(ac_result_to_json(original))
  match back {
    Some(r) => {
      assert_eq(r.outputs.length(), 3)
      assert_eq(r.outputs[0].path, "out")
      assert_true(r.outputs[0].kind == TarDir)
      assert_eq(r.outputs[0].mode, 0o755)
      assert_eq(r.outputs[1].digest, "a".repeat(64))
      assert_eq(r.outputs[1].size, 1234L)
      assert_true(r.outputs[2].kind == TarSymlink("app"))
      assert_eq(r.stdout_digest, "b".repeat(64))
      assert_eq(r.stderr_digest, "c".repeat(64))
    }
    None => fail("the manifest did not round-trip")
  }
}

///|
test "a manifest from a future version is a miss, not a guess" {
  // A reader that guessed at an unfamiliar shape would restore whatever
  // it could parse and call it a hit.
  let json = ac_result_to_json(result_of([]))
  match json {
    Object(o) => {
      o["version"] = Json::number(999)
      assert_true(ac_result_of_json(Json::object(o)) is None)
    }
    _ => fail("expected an object")
  }
}

///|
test "a manifest missing a required field is a miss" {
  // A file entry with no digest names no bytes. Restoring the rest and
  // skipping it is exactly the partial hit this store must not produce.
  let broken : Map[String, Json] = Map([], capacity=3)
  broken["version"] = Json::number(1)
  let item : Map[String, Json] = Map([], capacity=2)
  item["path"] = Json::string("out/app")
  item["kind"] = Json::string("file")
  broken["outputs"] = Json::array([Json::object(item)])
  assert_true(ac_result_of_json(Json::object(broken)) is None)
}

///|
test "a blob round-trips and is named by its uncompressed content" {
  let dir = scratch("blob")
  with_cache_root(dir, () => {
    let content = Bytes::from_array([1, 2, 3, 4, 5].map(b => b.to_byte()))
    let digest = blob_put(content).unwrap()
    // Named on the raw bytes, not the compressed ones: the same content
    // must land on the same name whatever version of gzip wrote it.
    assert_eq(digest, hex_encode(@crypto.sha256(content)))
    assert_true(blob_exists(digest))
    assert_eq(blob_get(digest), Some(content))
  })
  rm_rf(dir)
}

///|
test "identical content from two stores is one blob" {
  // The whole point of the split. Two entries producing the same bytes
  // must not cost two copies.
  let dir = scratch("share")
  with_cache_root(dir, () => {
    let content = @utf8.encode("the same output twice")
    let first = blob_put(content).unwrap()
    let second = blob_put(content).unwrap()
    assert_eq(first, second)
    let mut blobs = 0
    walk_blobs((_, _, _) => blobs = blobs + 1)
    assert_eq(blobs, 1)
  })
  rm_rf(dir)
}

///|
test "an entry naming a blob nobody stored is refused" {
  // The shape a crash between the blob writes and the manifest would
  // leave — except the manifest is written last, so it should not
  // happen. If it ever does, it is a miss and not an empty tree.
  let dir = scratch("missing-blob")
  with_cache_root(dir, () => {
    let result = result_of([file_out("out/app", "f".repeat(64), 10L)])
    assert_true(ac_reject_reason(result) is Some(_))
  })
  rm_rf(dir)
}

///|
test "an entry whose path escapes the workspace is refused" {
  // A remote entry is untrusted input and must not be able to drop a
  // file into ~/.ssh. Checked on the manifest, before any write.
  let dir = scratch("escape")
  with_cache_root(dir, () => {
    let content = @utf8.encode("pwned")
    let digest = blob_put(content).unwrap()
    let size = content.length().to_int64()
    assert_true(
      ac_reject_reason(result_of([file_out("../outside", digest, size)]))
      is Some(_),
    )
    assert_true(
      ac_reject_reason(result_of([file_out("/etc/passwd", digest, size)]))
      is Some(_),
    )
    // The same content at a path inside the tree is fine.
    assert_true(
      ac_reject_reason(result_of([file_out("out/app", digest, size)])) is None,
    )
  })
  rm_rf(dir)
}

///|
test "an entry claiming more than the expansion cap is refused" {
  // A manifest is cheap to forge; the cap has to be enforced on what it
  // claims, before anything is written.
  let dir = scratch("cap")
  with_cache_root(dir, () => {
    let content = @utf8.encode("small")
    let digest = blob_put(content).unwrap()
    let huge = result_of([
      file_out("a", digest, CACHE_MAX_EXPANDED_BYTES),
      file_out("b", digest, CACHE_MAX_EXPANDED_BYTES),
    ])
    assert_true(ac_reject_reason(huge) is Some(_))
  })
  rm_rf(dir)
}

///|
test "the sweep keeps what an entry still names and drops the rest" {
  // Removing an entry frees nothing on its own now — several entries
  // name the same blob. Getting this wrong in either direction is bad:
  // sweeping a live blob breaks a hit, keeping a dead one leaks.
  let dir = scratch("sweep")
  with_cache_root(dir, () => {
    let shared = @utf8.encode("shared between both entries")
    let only_a = @utf8.encode("only the first entry has this")
    let orphan = @utf8.encode("nothing names this")
    let shared_d = blob_put(shared).unwrap()
    let only_a_d = blob_put(only_a).unwrap()
    let orphan_d = blob_put(orphan).unwrap()
    let key_a = "aa" + "0".repeat(62)
    let key_b = "bb" + "1".repeat(62)
    assert_true(
      ac_store(
        key_a,
        result_of([
          file_out("shared", shared_d, shared.length().to_int64()),
          file_out("mine", only_a_d, only_a.length().to_int64()),
        ]),
      ),
    )
    assert_true(
      ac_store(
        key_b,
        result_of([file_out("shared", shared_d, shared.length().to_int64())]),
      ),
    )
    // Only the orphan goes.
    let (swept, _) = sweep_blobs()
    assert_eq(swept, 1)
    assert_true(blob_exists(shared_d))
    assert_true(blob_exists(only_a_d))
    assert_true(!blob_exists(orphan_d))
    // Dropping the first entry frees only what it alone named.
    rm_rf(ac_dir(key_a))
    let (swept2, _) = sweep_blobs()
    assert_eq(swept2, 1)
    assert_true(blob_exists(shared_d))
    assert_true(!blob_exists(only_a_d))
  })
  rm_rf(dir)
}

///|
test "a dry sweep reports what it would drop and drops nothing" {
  let dir = scratch("dry-sweep")
  with_cache_root(dir, () => {
    let content = @utf8.encode("about to be orphaned")
    let digest = blob_put(content).unwrap()
    let key = "cc" + "2".repeat(62)
    assert_true(
      ac_store(
        key,
        result_of([file_out("out", digest, content.length().to_int64())]),
      ),
    )
    // Nothing is unreferenced yet.
    let (none_swept, _) = sweep_blobs(dry_run=true)
    assert_eq(none_swept, 0)
    // Asking what a prune of this key would free: one blob, still there.
    let skip : Map[String, Bool] = Map([], capacity=1)
    skip[key] = true
    let (would, bytes) = sweep_blobs(skip~, dry_run=true)
    assert_eq(would, 1)
    assert_true(bytes > 0L)
    assert_true(blob_exists(digest))
  })
  rm_rf(dir)
}

///|
test "an entry survives the archive round trip the remote cache uses" {
  // The wire format is unchanged, so an entry has to be rebuildable
  // into an archive and taken back apart into the same manifest. This
  // is the pair a remote push and fetch run, and a mistake in either
  // half is a remote cache that silently stops working.
  let dir = scratch("archive")
  with_cache_root(dir, () => {
    let app = @utf8.encode("#!/bin/sh\necho built\n")
    let app_d = blob_put(app).unwrap()
    let out_log = @utf8.encode("built the thing\n")
    let key = "dd" + "3".repeat(62)
    let stored = ActionResult::{
      outputs: [
        AcOutput::{
          path: "out",
          kind: TarDir,
          digest: "",
          size: 0L,
          mode: 0o755,
        },
        AcOutput::{
          path: "out/app",
          kind: TarFile,
          digest: app_d,
          size: app.length().to_int64(),
          mode: 0o755,
        },
        AcOutput::{
          path: "out/link",
          kind: TarSymlink("app"),
          digest: "",
          size: 0L,
          mode: 0o777,
        },
      ],
      stdout_digest: blob_put(out_log).unwrap(),
      stderr_digest: "",
    }
    assert_true(ac_store(key, stored))
    let archive = entry_archive_bytes(key)
    assert_true(archive is Some(_))
    // Ingest it back under a different key, as a fetch on another
    // machine would.
    let fetched_key = "ee" + "4".repeat(62)
    assert_true(ac_ingest_archive(fetched_key, archive.unwrap()))
    match ac_load(fetched_key) {
      Some(back) => {
        assert_eq(back.outputs.length(), 3)
        assert_eq(back.outputs[0].path, "out")
        assert_true(back.outputs[0].kind == TarDir)
        assert_eq(back.outputs[1].path, "out/app")
        assert_eq(back.outputs[1].digest, app_d)
        assert_eq(back.outputs[1].mode, 0o755)
        assert_true(back.outputs[2].kind == TarSymlink("app"))
        // The transcript rode along and is the same bytes.
        assert_eq(blob_get(back.stdout_digest), Some(out_log))
        assert_eq(back.stderr_digest, "")
      }
      None => fail("the ingested entry has no manifest")
    }
  })
  rm_rf(dir)
}

///|
test "an archive with an escaping member is never ingested" {
  // Validation happens on the way in, so a hostile remote entry does
  // not reach the blob store at all.
  let dir = scratch("ingest-escape")
  with_cache_root(dir, () => {
    let tb = tar_new()
    tar_write_entry(tb, "../escape", @utf8.encode("pwned"), 0o644)
    let archive = @zlib.gzip_compress(tar_finish(tb))
    let key = "ff" + "5".repeat(62)
    assert_true(!ac_ingest_archive(key, archive))
    assert_true(ac_load(key) is None)
  })
  rm_rf(dir)
}

///|
test "a truncated archive is a miss, not a partial ingest" {
  let dir = scratch("ingest-truncated")
  with_cache_root(dir, () => {
    let key = "0f" + "6".repeat(62)
    assert_true(!ac_ingest_archive(key, @utf8.encode("not gzip at all")))
    assert_true(ac_load(key) is None)
  })
  rm_rf(dir)
}
