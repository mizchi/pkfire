// In-process `package://` downloader for the embedded loader (phase 3).
// Ported from `mizchi/pkl/cmd/mpkl/package_download.mbt`
// (`download_package_uri_to_cache` + the metadata-url / zip-url / sha256
// helpers it needs).
//
// Two deliberate divergences from the reference:
//
//   1. On failure this RAISES `LoaderError(msg)` instead of the reference's
//      `println(...) + return false`. The Task-4 caller wants a raise so the
//      download failure joins the loader's existing error path.
//
//   2. The WRITE path is derived from `loader.mbt`'s own
//      `resolve_package_uri_to_file`, the very function the loader READS
//      against. Reusing it (rather than re-deriving the cache layout) makes
//      the "download immediately satisfies the re-read" invariant hold by
//      construction: write target == read target, same `package_cache_root()`.
//
// The metadata URL is rederived here from the `package://` URI's authority +
// path (loader.mbt's parser drops the authority, which the metadata URL
// needs). Apple Pkl's convention is a direct scheme rewrite,
// `package://<authority><path>` -> `https://<authority><path>`, dropping the
// fragment. Loopback hosts (`127.0.0.1` / `localhost`) get `http://` so the
// offline conformance harness and the whitebox test can serve plain HTTP.

///|
/// Build the registry metadata URL from a `package://` URI:
///   package://<authority>/<path>@<ver>#frag  ->  https://<authority>/<path>@<ver>
/// Returns `None` when the URI is not a `package://<host>/<path>` shape.
fn package_metadata_url_from_uri(uri : String) -> String? {
  if !uri.has_prefix("package://") {
    return None
  }
  let after_scheme = uri["package://".length():uri.length()].to_owned()
  let without_fragment = match after_scheme.find("#") {
    Some(idx) => after_scheme[0:idx].to_owned()
    None => after_scheme
  }
  // The authority ends at the first `/` after the host.
  match without_fragment.find("/") {
    None => None
    Some(0) => None
    Some(slash) => {
      let authority = without_fragment[0:slash].to_owned()
      let path = without_fragment[slash:].to_owned()
      let scheme = if authority.has_prefix("127.0.0.1") ||
        authority.has_prefix("localhost") {
        "http://"
      } else {
        "https://"
      }
      Some("\{scheme}\{authority}\{path}")
    }
  }
}

///|
/// Pluck `packageZipUrl` from the metadata JSON body. URLs never contain JSON
/// string escapes, so a naive substring scan is sufficient. `None` when the
/// field is absent or malformed.
fn extract_package_zip_url(body : String) -> String? {
  let needle = "\"packageZipUrl\""
  match body.find(needle) {
    None => None
    Some(idx) => {
      let mut i = idx + needle.length()
      while i < body.length() {
        let c = body[i].to_int().unsafe_to_char()
        if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
          i = i + 1
        } else {
          break
        }
      }
      if i >= body.length() || body[i].to_int().unsafe_to_char() != ':' {
        return None
      }
      i = i + 1
      while i < body.length() {
        let c = body[i].to_int().unsafe_to_char()
        if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
          i = i + 1
        } else {
          break
        }
      }
      if i >= body.length() || body[i].to_int().unsafe_to_char() != '"' {
        return None
      }
      let value_start = i + 1
      let mut j = value_start
      while j < body.length() && body[j].to_int().unsafe_to_char() != '"' {
        j = j + 1
      }
      if j >= body.length() {
        return None
      }
      Some(body[value_start:j].to_owned())
    }
  }
}

///|
/// Pluck `packageZipChecksums.sha256` from the metadata JSON body via the JSON
/// parser (matches the reference). `None` when absent or malformed.
fn extract_package_zip_sha256(body : String) -> String? {
  let parsed = @json.parse(body[:]) catch { _ => return None }
  match parsed {
    Object(top) =>
      match top.get("packageZipChecksums") {
        Some(Object(checksums)) =>
          match checksums.get("sha256") {
            Some(String(value)) => Some(value)
            _ => None
          }
        _ => None
      }
    _ => None
  }
}

///|
/// Download the package zip for `uri`, verify its sha256 against the metadata,
/// and extract it into the cache at exactly the path the loader reads against.
/// Raises `LoaderError` on any failure (malformed URI, fetch failure, missing
/// metadata fields, sha256 mismatch, extraction failure).
///
/// The cache root honours `PKL_MBT_PACKAGE_CACHE` (then `XDG_CACHE_HOME`, then
/// `HOME`) via `loader.mbt`'s `package_cache_root()` / `resolve_package_uri_to_file`.
async fn download_package_uri_to_cache(uri : String) -> Unit raise LoaderError {
  // The extraction target must be the `.../package` DIR, so resolve against the
  // fragment-stripped URI: a `#/file` fragment would otherwise make
  // `resolve_package_uri_to_file` return a FILE path and we'd extract the whole
  // zip into `.../package/file/`. Callers (e.g. `read_module_source`) pass the
  // full `package://...#/file` URI.
  let uri_no_fragment = match uri.find("#") {
    Some(idx) => uri[0:idx].to_owned()
    None => uri
  }
  let package_dir = match resolve_package_uri_to_file(uri_no_fragment) {
    Some(p) => p
    None => raise LoaderError("malformed package URI: \{uri}")
  }
  let metadata_url = match package_metadata_url_from_uri(uri) {
    Some(url) => url
    None => raise LoaderError("malformed package URI: \{uri}")
  }
  let metadata_fetched = fetch_uri(metadata_url) catch {
    _ => raise LoaderError("metadata fetch failed: \{metadata_url}")
  }
  let metadata = match metadata_fetched {
    Some(body) => body
    None => raise LoaderError("metadata fetch failed: \{metadata_url}")
  }
  let zip_url = match extract_package_zip_url(metadata) {
    Some(url) => url
    None => raise LoaderError("metadata is missing packageZipUrl")
  }
  let expected_sha256 = match extract_package_zip_sha256(metadata) {
    Some(value) => value
    None => raise LoaderError("metadata is missing packageZipChecksums.sha256")
  }
  let fetched = fetch_uri_bytes(zip_url) catch {
    _ => raise LoaderError("zip fetch failed: \{zip_url}")
  }
  let zip_bytes = match fetched {
    Some(bytes) => bytes
    None => raise LoaderError("zip fetch failed: \{zip_url}")
  }
  let actual_sha256 = @crypto.bytes_to_hex_string(@crypto.sha256(zip_bytes))
  if actual_sha256 != expected_sha256 {
    raise LoaderError(
      "package zip sha256 mismatch: expected \{expected_sha256}, got \{actual_sha256}",
    )
  }
  // `resolve_package_uri_to_file` with no `#/file` fragment yields the
  // `.../package` dir; the zip's top-level entries land directly under it.
  extract_zip_to_dir(zip_bytes, package_dir)
}
