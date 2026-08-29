// Whitebox tests for the in-process `package://` downloader ported into the
// loader package (phase 3). A loopback `@async_http.Server` serves both a
// metadata JSON endpoint (`packageZipUrl` + `packageZipChecksums.sha256`) and
// the fixture ZIP bytes, so `download_package_uri_to_cache` is exercised end
// to end against the very ZIP `build_fixture_zip` (from `zip_wbtest.mbt`)
// produces.
//
// The critical invariant under test: the extracted files must land at exactly
// the filesystem path `loader.mbt`'s `resolve_package_uri_to_file` resolves the
// same URI against, so a download immediately satisfies the subsequent re-read.

///|
fn hex_of_bytes(b : Bytes) -> String {
  @crypto.bytes_to_hex_string(@crypto.sha256(b))
}

///|
/// Point the package cache root at a fresh temp dir (read by loader.mbt's
/// `package_cache_root()` and thus by the downloader's write path).
///
/// This does NOT isolate one test from another. `PKL_MBT_PACKAGE_CACHE` is
/// process-global and every test in the binary shares it, so the last
/// caller wins — after a full run only one of these directories exists and
/// every test's package landed inside it. What keeps the tests apart is
/// that each uses a distinct package PATH in its `package://` URI, which
/// is what maps to a directory under the root. Two tests sharing a path
/// would share a directory whichever root won, and that is what made
/// `download_package_uri_to_cache` intermittently fail.
fn set_temp_cache_root(suffix : String) -> Unit {
  let base = match @env.get_env_var("TMPDIR") {
    Some(d) => d
    None => "/tmp"
  }
  @env.set_env_var(
    "PKL_MBT_PACKAGE_CACHE",
    path_join(base, "pkf-download-wbtest-\{suffix}"),
  )
}

///|
async test "download_package_uri_to_cache extracts at the loader-resolved path" {
  let zip = build_fixture_zip()
  let zip_sha = hex_of_bytes(zip)
  set_temp_cache_root("ok")
  @async.with_task_group(group => {
    let server = @async_http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    // The downloader derives the metadata URL from the `package://` URI:
    //   package://127.0.0.1:<port>/dl-ok/n@1.0.0  ->  http://127.0.0.1:<port>/dl-ok/n@1.0.0
    // and the zip URL comes back inside the metadata body.
    let metadata = "{\"packageZipUrl\":\"http://127.0.0.1:\{port}/p.zip\",\"packageZipChecksums\":{\"sha256\":\"\{zip_sha}\"}}"
    group.spawn_bg(() => {
      defer server.close()
      // Request 1: metadata JSON at /dl-ok/n@1.0.0
      {
        let (conn, _) = server.accept()
        defer conn.close()
        ignore(conn.read_request())
        conn.skip_request_body()
        conn.send_response(200, "OK")
        conn.write_string(metadata)
        conn.end_response()
      }
      // Request 2: the zip bytes at /p.zip
      let (conn, _) = server.accept()
      defer conn.close()
      ignore(conn.read_request())
      conn.skip_request_body()
      conn.send_response(200, "OK")
      conn.write(zip)
      conn.end_response()
    })
    // Distinct package path per test: the cache root is shared (see
    // `set_temp_cache_root`), so the path is the only thing keeping this
    // test's extraction out of the sha-mismatch test's directory.
    let uri = "package://127.0.0.1:\{port}/dl-ok/n@1.0.0"
    download_package_uri_to_cache(uri)
    // Assert extraction landed at the EXACT path the loader resolves against.
    let a_uri = "package://127.0.0.1:\{port}/dl-ok/n@1.0.0#/dir/a.txt"
    let a_path = match resolve_package_uri_to_file(a_uri) {
      Some(p) => p
      None => fail("resolve_package_uri_to_file returned None for \{a_uri}")
    }
    let a = @fs.read_file_to_string(a_path)
    assert_eq(a, "A")
  })
}

///|
async test "download_package_uri_to_cache raises on sha256 mismatch" {
  let zip = build_fixture_zip()
  set_temp_cache_root("bad")
  @async.with_task_group(group => {
    let server = @async_http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    let metadata = "{\"packageZipUrl\":\"http://127.0.0.1:\{port}/p.zip\",\"packageZipChecksums\":{\"sha256\":\"deadbeef\"}}"
    group.spawn_bg(() => {
      defer server.close()
      {
        let (conn, _) = server.accept()
        defer conn.close()
        ignore(conn.read_request())
        conn.skip_request_body()
        conn.send_response(200, "OK")
        conn.write_string(metadata)
        conn.end_response()
      }
      let (conn, _) = server.accept()
      defer conn.close()
      ignore(conn.read_request())
      conn.skip_request_body()
      conn.send_response(200, "OK")
      conn.write(zip)
      conn.end_response()
    })
    // Distinct package path per test — see the success test above.
    let uri = "package://127.0.0.1:\{port}/dl-bad/n@1.0.0"
    let raised = try {
      download_package_uri_to_cache(uri)
      false
    } catch {
      LoaderError(_) => true
    }
    assert_eq(raised, true)
  })
}
