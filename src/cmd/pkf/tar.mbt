// Minimal POSIX ustar tar writer + reader. Used by the cache to pack
// the manifest + every output file into a single `entry.tar.gz` blob
// (gzip applied externally via `@zlib.gzip_compress`). We only emit and
// only parse regular-file entries — there's no need for symlinks,
// hardlinks, or directory entries: the cache stores a flat set of
// regular files with their unix mode bits.

///|
/// Build a tar archive incrementally. Call `tar_write_entry` for each
/// file, then `tar_finish` to get the bytes including the two trailing
/// zero blocks the spec requires for EOF.
priv struct TarBuilder {
  buf : @buffer.Buffer
}

///|
fn tar_new() -> TarBuilder {
  TarBuilder::{ buf: @buffer.Buffer(size_hint=4096) }
}

///|
fn tar_write_entry(
  tb : TarBuilder,
  name : String,
  content : Bytes,
  mode : Int,
) -> Unit {
  let header : FixedArray[Byte] = FixedArray::make(512, b'\x00')
  // Name: max 100 bytes, UTF-8. Anything longer would need the `prefix`
  // field; cache rels rarely exceed 100, and the rare violation can be
  // added with the L (LongLink) extension later.
  let name_bytes = @utf8.encode(name)
  let nl = if name_bytes.length() < 100 { name_bytes.length() } else { 100 }
  for i in 0..<nl {
    header[i] = name_bytes[i]
  }
  // Mode (8 bytes): "0000644\0" style. Trailing NUL + space matches GNU.
  tar_write_octal(header, 100, 7, mode)
  header[107] = b'\x00'
  // uid / gid: zero — runners may not have a meaningful user.
  tar_write_octal(header, 108, 7, 0)
  header[115] = b'\x00'
  tar_write_octal(header, 116, 7, 0)
  header[123] = b'\x00'
  // Size (12 bytes): 11-digit octal + NUL.
  tar_write_octal(header, 124, 11, content.length())
  header[135] = b'\x00'
  // mtime: 0 — content-addressed cache, the timestamp doesn't matter.
  tar_write_octal(header, 136, 11, 0)
  header[147] = b'\x00'
  // Checksum: filled in with 8 spaces first so the sum is well-defined.
  for i in 0..<8 {
    header[148 + i] = b' '
  }
  // Typeflag '0' = regular file.
  header[156] = b'0'
  // Magic: "ustar\0" + version "00".
  let magic : FixedArray[Byte] = [b'u', b's', b't', b'a', b'r', b'\x00']
  for i in 0..<6 {
    header[257 + i] = magic[i]
  }
  header[263] = b'0'
  header[264] = b'0'
  // Checksum: sum of all 512 bytes as unsigned, into the field as a
  // 6-digit octal + NUL + space (per POSIX).
  let mut csum = 0
  for i in 0..<512 {
    csum = csum + header[i].to_int()
  }
  tar_write_octal(header, 148, 6, csum)
  header[154] = b'\x00'
  header[155] = b' '
  for i in 0..<512 {
    tb.buf.write_byte(header[i])
  }
  // Content + padding to 512-byte boundary.
  for i in 0..<content.length() {
    tb.buf.write_byte(content[i])
  }
  let rem = content.length() % 512
  if rem != 0 {
    for _ in rem..<512 {
      tb.buf.write_byte(b'\x00')
    }
  }
}

///|
fn tar_finish(tb : TarBuilder) -> Bytes {
  for _ in 0..<1024 {
    tb.buf.write_byte(b'\x00')
  }
  tb.buf.to_bytes()
}

///|
/// Right-aligned octal into `dst[off..off+width)` (width = octal digit
/// count, not including the trailing NUL the caller writes after).
fn tar_write_octal(
  dst : FixedArray[Byte],
  off : Int,
  width : Int,
  value : Int,
) -> Unit {
  // Pad with '0'.
  for i in 0..<width {
    dst[off + i] = b'0'
  }
  let mut v = value
  let mut i = off + width - 1
  while v > 0 && i >= off {
    let digit = v % 8
    dst[i] = (b'0'.to_int() + digit).to_byte()
    v = v / 8
    i = i - 1
  }
}

///|
priv struct TarEntry {
  name : String
  content : Bytes
  mode : Int
}

///|
fn tar_iter(data : Bytes) -> Array[TarEntry] {
  let out : Array[TarEntry] = []
  let mut pos = 0
  while pos + 512 <= data.length() {
    // EOF marker: a block of all-zeros means we're done.
    let mut all_zero = true
    for i in 0..<512 {
      if data[pos + i] != 0 {
        all_zero = false
        break
      }
    }
    if all_zero {
      return out
    }
    let name = tar_read_cstring(data, pos, 100)
    let mode = tar_read_octal(data, pos + 100, 8)
    let size = tar_read_octal(data, pos + 124, 12)
    let typeflag = data[pos + 156].to_int()
    pos = pos + 512
    if pos + size > data.length() {
      break
    }
    // Only regular files. tar emits '\0' or '0' for that.
    if name.length() > 0 && (typeflag == 0 || typeflag == '0'.to_int()) {
      let cbuf : FixedArray[Byte] = FixedArray::make(size, b'\x00')
      for i in 0..<size {
        cbuf[i] = data[pos + i]
      }
      out.push(TarEntry::{ name, content: Bytes::from_array(cbuf), mode })
    }
    let padded = (size + 511) / 512 * 512
    pos = pos + padded
  }
  out
}

///|
fn tar_read_cstring(data : Bytes, off : Int, max_len : Int) -> String {
  let mut end = off
  let limit = off + max_len
  while end < limit && end < data.length() && data[end] != 0 {
    end = end + 1
  }
  if end == off {
    return ""
  }
  let bytes : FixedArray[Byte] = FixedArray::make(end - off, b'\x00')
  for i in 0..<(end - off) {
    bytes[i] = data[off + i]
  }
  @utf8.decode_lossy(Bytes::from_array(bytes))
}

///|
fn tar_read_octal(data : Bytes, off : Int, max_len : Int) -> Int {
  let mut v = 0
  let limit = off + max_len
  for i in off..<limit {
    if i >= data.length() {
      break
    }
    let b = data[i].to_int()
    if b >= '0'.to_int() && b <= '7'.to_int() {
      v = v * 8 + (b - '0'.to_int())
    } else {
      // Stop at NUL / space / anything non-octal.
      break
    }
  }
  v
}
