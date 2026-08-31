// Tests for the remote cache's request shape.
//
// The bug these guard was invisible from pkfire's side: the upload
// returned 2xx, and every later fetch got a well-formed but empty
// archive. Nothing in the output said the remote cache had stopped
// working. So what is pinned here is the URL split that puts the path
// on the request rather than on the connection — the piece that lets
// `Content-Length` reach the request at all.

///|
test "an absolute URL splits into origin and path" {
  match split_url_origin("http://cache.example/cas/ab/cdef/entry.tar.gz") {
    Some((origin, path)) => {
      assert_eq(origin, "http://cache.example")
      assert_eq(path, "/cas/ab/cdef/entry.tar.gz")
    }
    None => fail("a plain URL did not split")
  }
}

///|
test "a port stays with the origin" {
  match split_url_origin("http://127.0.0.1:8740/cas/ab/cd") {
    Some((origin, path)) => {
      assert_eq(origin, "http://127.0.0.1:8740")
      assert_eq(path, "/cas/ab/cd")
    }
    None => fail("a URL with a port did not split")
  }
}

///|
test "a base carrying its own prefix keeps it on the path" {
  // `PKFIRE_MBT_REMOTE_CACHE=https://host/v1` is a documented shape, so
  // splitting at the configured base rather than after the authority
  // would drop the prefix and PUT to the wrong place.
  match split_url_origin("https://cache.example/v1/cas/ab/cd/entry.tar.gz") {
    Some((origin, path)) => {
      assert_eq(origin, "https://cache.example")
      assert_eq(path, "/v1/cas/ab/cd/entry.tar.gz")
    }
    None => fail("a prefixed URL did not split")
  }
}

///|
test "a URL with no path at all still yields one" {
  // A request line needs a path; an empty one is not a valid HTTP/1.1
  // request.
  match split_url_origin("https://cache.example") {
    Some((origin, path)) => {
      assert_eq(origin, "https://cache.example")
      assert_eq(path, "/")
    }
    None => fail("a bare origin did not split")
  }
}

///|
test "something that is not an absolute URL is refused" {
  // Refused rather than guessed at: a relative path here would become a
  // request to whatever host the client happened to resolve.
  assert_true(split_url_origin("cache.example/cas/ab") is None)
  assert_true(split_url_origin("/cas/ab/cd") is None)
  assert_true(split_url_origin("") is None)
}
