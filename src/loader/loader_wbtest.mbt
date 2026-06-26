// Whitebox tests for `read_module_source` remote resolution (phase 3, task 4):
// it now fetches `http(s)://` modules directly and downloads `package://`
// archives into the cache on a miss (then reads from cache on a hit, with no
// second network round-trip).
//
// IMPORTANT: the metadata JSON below MUST be a single-line escaped string
// literal. A multiline `#|`/`$|` literal injects a newline that breaks JSON
// parsing and deadlocks the loopback server, so keep it on one line.

///|
async test "read_module_source downloads package:// on cache miss then reads cache hit" {
  let zip = build_fixture_zip()
  let zip_sha = hex_of_bytes(zip)
  @async.with_task_group(group => {
    let server = @async_http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    // Key the cache dir on the ephemeral port so each run starts on a true
    // cache MISS (ports differ run-to-run; no stale-cache cleanup needed).
    set_temp_cache_root("read-module-\{port}")
    let metadata =
      "{\"packageZipUrl\":\"http://127.0.0.1:\{port}/p.zip\",\"packageZipChecksums\":{\"sha256\":\"\{zip_sha}\"}}"
    group.spawn_bg(() => {
      defer server.close()
      // Request 1: metadata JSON
      {
        let (conn, _) = server.accept()
        defer conn.close()
        ignore(conn.read_request())
        conn.skip_request_body()
        conn.send_response(200, "OK")
        conn.write_string(metadata)
        conn.end_response()
      }
      // Request 2: the zip bytes
      {
        let (conn, _) = server.accept()
        defer conn.close()
        ignore(conn.read_request())
        conn.skip_request_body()
        conn.send_response(200, "OK")
        conn.write(zip)
        conn.end_response()
      }
    })
    let uri = "package://127.0.0.1:\{port}/rm/readmod@1.0.0#/dir/a.txt"
    // Cache miss: downloads then reads; `dir/a.txt` in the fixture is "A".
    let first = read_module_source(uri)
    assert_eq(first, "A")
    // The server served exactly two requests and is now torn down (its loop
    // exits after request 2). A second read must be served from the cache with
    // NO network access, proving the hit short-circuits the download.
    let second = read_module_source(uri)
    assert_eq(second, "A")
  })
}

///|
async test "read_module_source fetches http:// module text" {
  @async.with_task_group(group => {
    let server = @async_http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    let module_text = "x = 1"
    group.spawn_bg(() => {
      defer server.close()
      let (conn, _) = server.accept()
      defer conn.close()
      ignore(conn.read_request())
      conn.skip_request_body()
      conn.send_response(200, "OK")
      conn.write_string(module_text)
      conn.end_response()
    })
    let got = read_module_source("http://127.0.0.1:\{port}/Mod.pkl")
    assert_eq(got, module_text)
  })
}
