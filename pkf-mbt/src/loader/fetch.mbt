// In-process HTTP fetch for the embedded loader (phase 3). Ported from
// `cmd/mpkl/fetch_native.mbt` so the loader no longer needs to shell out
// to the mpkl subprocess for `package://` metadata / archive downloads.
//
// Follows up to 5 redirects (301 / 302 / 303 / 307 / 308) via the
// `Location` header — `pkg.pkl-lang.org` 301-redirects to a CDN host
// before serving registry metadata, so without redirect-following the
// registry probe always fails. The 5-hop cap matches `curl`'s default
// and prevents loops. A relative `Location` is resolved against the URL
// that produced the redirect. Every failure path returns `None`, mirroring
// the reference exactly (no new error type).

///|
/// Resolve a (possibly relative) `Location` header value against the URL
/// that produced the redirect.
///
///   - An absolute URL (`scheme://...`) is returned unchanged.
///   - An absolute path (`/b`) replaces the path of `base`, keeping the
///     `scheme://authority`.
///   - A relative reference (`d`) replaces the last path segment of `base`.
fn resolve_location(base : String, location : String) -> String {
  // Absolute URL: has a scheme (`://`) — return as-is.
  if location.contains("://") {
    return location
  }
  // Split `base` into `scheme://authority` and the remaining path.
  let scheme_end = match base.find("://") {
    Some(i) => i + 3
    None => return location // base is not a normal URL; best effort
  }
  let rest_start = match base.substring(start=scheme_end).find("/") {
    Some(i) => scheme_end + i
    None => base.length() // no path component at all
  }
  let origin = base.substring(start=0, end=rest_start)
  if location.has_prefix("/") {
    // Absolute path: replace the whole path.
    return origin + location
  }
  // Relative reference: replace the last segment of the base path.
  let base_path = base.substring(start=rest_start)
  let dir_end = match base_path.rev_find("/") {
    Some(i) => rest_start + i + 1
    None => rest_start
  }
  base.substring(start=0, end=dir_end) + location
}

///|
/// Fetch the body of `url` over HTTP / HTTPS. Returns the decoded body on
/// success, `None` on failure (with the message printed so the caller's
/// `fail` path surfaces an unambiguous diagnostic).
async fn fetch_uri(url : String) -> String? {
  let mut current = url
  let mut remaining = 5
  while remaining > 0 {
    try {
      let (resp, body) = @http.get(current)
      if resp.code >= 300 && resp.code < 400 {
        match resp.headers.get("location") {
          Some(next) => {
            current = resolve_location(current, next)
            remaining = remaining - 1
            continue
          }
          None =>
            match resp.headers.get("Location") {
              Some(next) => {
                current = resolve_location(current, next)
                remaining = remaining - 1
                continue
              }
              None => {
                println(
                  "http \{resp.code} \{resp.reason} fetching \{current} (no Location header)",
                )
                return None
              }
            }
        }
      }
      if resp.code < 200 || resp.code >= 300 {
        println("http \{resp.code} \{resp.reason} fetching \{current}")
        return None
      }
      return Some(body.text())
    } catch {
      e => {
        println("http fetch failed: \{e}")
        return None
      }
    }
  }
  println("http fetch failed: too many redirects (last url: \{current})")
  None
}

///|
/// Like `fetch_uri`, but returns the raw response bytes (for archive /
/// tarball downloads).
async fn fetch_uri_bytes(url : String) -> Bytes? {
  let mut current = url
  let mut remaining = 5
  while remaining > 0 {
    try {
      let (resp, body) = @http.get(current)
      if resp.code >= 300 && resp.code < 400 {
        match resp.headers.get("location") {
          Some(next) => {
            current = resolve_location(current, next)
            remaining = remaining - 1
            continue
          }
          None =>
            match resp.headers.get("Location") {
              Some(next) => {
                current = resolve_location(current, next)
                remaining = remaining - 1
                continue
              }
              None => {
                println(
                  "http \{resp.code} \{resp.reason} fetching \{current} (no Location header)",
                )
                return None
              }
            }
        }
      }
      if resp.code < 200 || resp.code >= 300 {
        println("http \{resp.code} \{resp.reason} fetching \{current}")
        return None
      }
      return Some(body.binary())
    } catch {
      e => {
        println("http fetch failed: \{e}")
        return None
      }
    }
  }
  println("http fetch failed: too many redirects (last url: \{current})")
  None
}
