// Whitebox tests for the in-process HTTP fetch ported into the loader
// package (phase 3). A loopback `@async_http.Server` serves
//   /a -> 302 Location: /b
//   /b -> 200 "hello"
// so we exercise the redirect-follow path end to end, including the
// relative-Location join that `fetch_uri` must perform.

///|
async test "fetch_uri follows a relative 302 redirect" {
  @async.with_task_group(group => {
    let server = @async_http.Server(@socket.Addr::parse("127.0.0.1:0"))
    let port = server.addr.port()
    group.spawn_bg(() => {
      defer server.close()
      // First request: /a -> 302 redirect to relative /b
      {
        let (conn, _) = server.accept()
        defer conn.close()
        ignore(conn.read_request())
        conn.skip_request_body()
        let extra : Map[String, String] = { "Location": "/b" }
        conn.send_response(302, "Found", extra_headers=extra)
        conn.end_response()
      }
      // Second request: /b -> 200 "hello"
      {
        let (conn, _) = server.accept()
        defer conn.close()
        ignore(conn.read_request())
        conn.skip_request_body()
        conn.send_response(200, "OK")
        conn.write_string("hello")
        conn.end_response()
      }
    })
    let got = fetch_uri("http://127.0.0.1:\{port}/a")
    assert_eq(got, Some("hello"))
  })
}

///|
test "resolve_location joins a relative path against the current url" {
  inspect(
    resolve_location("http://127.0.0.1:8080/a", "/b"),
    content="http://127.0.0.1:8080/b",
  )
  inspect(
    resolve_location("http://127.0.0.1:8080/a/c", "d"),
    content="http://127.0.0.1:8080/a/d",
  )
  // Absolute Location wins unchanged.
  inspect(
    resolve_location("http://127.0.0.1:8080/a", "https://cdn.example/x"),
    content="https://cdn.example/x",
  )
}
