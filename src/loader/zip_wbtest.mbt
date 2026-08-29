// Whitebox tests for the in-process ZIP reader/extractor ported into the
// loader package (phase 3). The fixture ZIP is built in-memory here rather
// than embedded as a byte literal so that the method-8 (deflate) entry is
// compressed with the very `@zlib.deflate_compress` that `read_zip_entries`
// round-trips via `@zlib.deflate_decompress` — i.e. the deflate path is
// genuinely exercised against the same zlib implementation.
//
//   "dir/a.txt" = "A"     stored  (method 0)
//   "b.txt"     = "BBBB"  deflate (method 8)

///|
fn push_u16_le(buf : Array[Byte], v : Int) -> Unit {
  buf.push((v & 0xff).to_byte())
  buf.push(((v >> 8) & 0xff).to_byte())
}

///|
fn push_u32_le(buf : Array[Byte], v : Int) -> Unit {
  buf.push((v & 0xff).to_byte())
  buf.push(((v >> 8) & 0xff).to_byte())
  buf.push(((v >> 16) & 0xff).to_byte())
  buf.push(((v >> 24) & 0xff).to_byte())
}

///|
fn push_bytes(buf : Array[Byte], b : Bytes) -> Unit {
  for i in 0..<b.length() {
    buf.push(b[i])
  }
}

///|
fn push_str(buf : Array[Byte], s : String) -> Unit {
  // ASCII-only names in the fixture.
  for i in 0..<s.length() {
    buf.push((s[i].to_int() & 0xff).to_byte())
  }
}

///|
struct FixtureEntry {
  name : String
  compression : Int
  uncompressed : Bytes
  compressed : Bytes
}

///|
fn build_fixture_zip() -> Bytes {
  let a_uncompressed = b"A"
  let b_uncompressed = b"BBBB"
  let entries = [
    {
      name: "dir/a.txt",
      compression: 0,
      uncompressed: a_uncompressed,
      compressed: a_uncompressed,
    },
    {
      name: "b.txt",
      compression: 8,
      uncompressed: b_uncompressed,
      compressed: @zlib.deflate_compress(b_uncompressed),
    },
  ]
  let body : Array[Byte] = []
  // local offsets per entry, captured as we lay out local headers
  let local_offsets : Array[Int] = []
  for e in entries {
    local_offsets.push(body.length())
    push_u32_le(body, 0x04034b50) // local file header signature
    push_u16_le(body, 20) // version needed
    push_u16_le(body, 0) // flags
    push_u16_le(body, e.compression) // compression method
    push_u16_le(body, 0) // mod time
    push_u16_le(body, 0) // mod date
    push_u32_le(body, 0) // crc-32 (not validated by reader)
    push_u32_le(body, e.compressed.length()) // compressed size
    push_u32_le(body, e.uncompressed.length()) // uncompressed size
    push_u16_le(body, e.name.length()) // name length
    push_u16_le(body, 0) // extra length
    push_str(body, e.name)
    push_bytes(body, e.compressed)
  }
  let central_offset = body.length()
  let mut idx = 0
  for e in entries {
    push_u32_le(body, 0x02014b50) // central directory header signature
    push_u16_le(body, 20) // version made by
    push_u16_le(body, 20) // version needed
    push_u16_le(body, 0) // flags
    push_u16_le(body, e.compression) // compression method
    push_u16_le(body, 0) // mod time
    push_u16_le(body, 0) // mod date
    push_u32_le(body, 0) // crc-32
    push_u32_le(body, e.compressed.length()) // compressed size
    push_u32_le(body, e.uncompressed.length()) // uncompressed size
    push_u16_le(body, e.name.length()) // name length
    push_u16_le(body, 0) // extra length
    push_u16_le(body, 0) // comment length
    push_u16_le(body, 0) // disk number start
    push_u16_le(body, 0) // internal attrs
    push_u32_le(body, 0) // external attrs
    push_u32_le(body, local_offsets[idx]) // local header offset
    push_str(body, e.name)
    idx += 1
  }
  let central_size = body.length() - central_offset
  // EOCD
  push_u32_le(body, 0x06054b50) // EOCD signature
  push_u16_le(body, 0) // disk number
  push_u16_le(body, 0) // disk with central dir
  push_u16_le(body, entries.length()) // entries on this disk
  push_u16_le(body, entries.length()) // total entries
  push_u32_le(body, central_size) // central dir size
  push_u32_le(body, central_offset) // central dir offset
  push_u16_le(body, 0) // comment length
  Bytes::from_array(FixedArray::from_array(body))
}

///|
fn bytes_to_ascii(b : Bytes) -> String {
  let chars : Array[Char] = []
  for i in 0..<b.length() {
    chars.push((b[i].to_int() & 0xff).unsafe_to_char())
  }
  String::from_array(chars)
}

///|
test "read_zip_entries decodes stored and deflate entries" {
  let data = build_fixture_zip()
  let entries = read_zip_entries(data)
  assert_eq(entries.length(), 2)
  // entry order follows the central directory order
  assert_eq(entries[0].path, "dir/a.txt")
  assert_eq(entries[0].is_dir, false)
  assert_eq(bytes_to_ascii(entries[0].content), "A")
  assert_eq(entries[1].path, "b.txt")
  assert_eq(entries[1].is_dir, false)
  assert_eq(bytes_to_ascii(entries[1].content), "BBBB")
}

///|
test "zip_entry_path_is_safe rejects traversal" {
  assert_eq(zip_entry_path_is_safe("../evil"), false)
  assert_eq(zip_entry_path_is_safe("dir/a.txt"), true)
}

///|
test "extract_zip_to_dir writes both files" {
  let data = build_fixture_zip()
  let base = match @env.get_env_var("TMPDIR") {
    Some(d) => d
    None => "/tmp"
  }
  // ensure_dir is idempotent and write_bytes_to_file overwrites, so a stale
  // dir from a previous run does not affect correctness.
  let dir = path_join(base, "pkf-zip-wbtest")
  extract_zip_to_dir(data, dir)
  let a = @fs.read_file_to_bytes(path_join(dir, "dir/a.txt"))
  let b = @fs.read_file_to_bytes(path_join(dir, "b.txt"))
  assert_eq(bytes_to_ascii(a), "A")
  assert_eq(bytes_to_ascii(b), "BBBB")
}
