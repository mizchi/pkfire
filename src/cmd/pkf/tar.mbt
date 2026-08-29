// Minimal POSIX ustar tar writer + reader. Used by the cache to pack
// every output into a single `entry.tar.gz` blob (gzip applied
// externally via `@zlib.gzip_compress`).
//
// Three member kinds are emitted: regular files, symlinks, and
// directories. Symlinks and directories are not decoration — storing
// only regular files meant the cache silently reshaped what it restored:
// a symlink came back as a copy of its target, an empty directory
// vanished, and a link pointing back up the tree (`out/loop -> ..`) was
// walked until the OS path limit stopped it, dragging files from
// outside the declared outputs into the entry.
//
// Two properties matter more here than in a general-purpose tar, because
// with a remote cache configured the reader is parsing bytes fetched
// over the network:
//
//   * Names longer than the 100-byte ustar `name` field are written as
//     a GNU `LongLink` ('L') member rather than truncated. Truncation
//     silently restores an output to the wrong path — a deep
//     `node_modules` path or a long Rust target triple hits this.
//   * Every header's checksum is verified on read, and a malformed
//     archive raises rather than returning the entries parsed so far.
//     A short read used to look like "that's all the outputs".

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
/// Append one regular-file member.
fn tar_write_entry(
  tb : TarBuilder,
  name : String,
  content : Bytes,
  mode : Int,
) -> Unit {
  let name_bytes = @utf8.encode(name)
  // Names past the 100-byte `name` field get a GNU LongLink member
  // carrying the full name, immediately followed by the real header.
  // The real header still holds a truncated copy for readers that do
  // not understand 'L'; ours reads the LongLink.
  if name_bytes.length() > 100 {
    tar_write_long_name(tb, name_bytes, b'L')
  }
  tar_write_raw_entry(tb, name, content, mode, b'0', link_target="")
}

///|
/// Append a directory member. Only emitted for directories that would
/// otherwise leave no trace — a non-empty directory is implied by its
/// members, but an empty one has none.
fn tar_write_dir_entry(tb : TarBuilder, name : String, mode : Int) -> Unit {
  // ustar spells directory names with a trailing slash.
  let name = if name.has_suffix("/") { name } else { name + "/" }
  let name_bytes = @utf8.encode(name)
  if name_bytes.length() > 100 {
    tar_write_long_name(tb, name_bytes, b'L')
  }
  tar_write_raw_entry(tb, name, Bytes::new(0), mode, b'5', link_target="")
}

///|
/// Append a symlink member. The target is stored verbatim (it may be
/// relative) — resolving it here would defeat the point of preserving
/// the link.
fn tar_write_symlink_entry(
  tb : TarBuilder,
  name : String,
  target : String,
) -> Unit {
  let name_bytes = @utf8.encode(name)
  if name_bytes.length() > 100 {
    tar_write_long_name(tb, name_bytes, b'L')
  }
  // GNU 'K' is to the linkname field what 'L' is to the name field.
  let target_bytes = @utf8.encode(target)
  if target_bytes.length() > 100 {
    tar_write_long_name(tb, target_bytes, b'K')
  }
  tar_write_raw_entry(
    tb, name, Bytes::new(0), 0o777, b'2', link_target=target,
  )
}

///|
/// Emit a GNU long-name member carrying `value`, which overrides the
/// next member's truncated name ('L') or link target ('K').
fn tar_write_long_name(
  tb : TarBuilder,
  value : Bytes,
  typeflag : Byte,
) -> Unit {
  let payload = @buffer.Buffer(size_hint=value.length() + 1)
  for b in value {
    payload.write_byte(b)
  }
  payload.write_byte(b'\x00')
  tar_write_raw_entry(
    tb, "././@LongLink", payload.to_bytes(), 0o644, typeflag, link_target="",
  )
}

///|
/// Append one member with an explicit typeflag. Regular files use '0';
/// the GNU long-name extensions use 'L' / 'K'; directories use '5' and
/// symlinks '2'.
fn tar_write_raw_entry(
  tb : TarBuilder,
  name : String,
  content : Bytes,
  mode : Int,
  typeflag : Byte,
  link_target~ : String,
) -> Unit {
  let header : FixedArray[Byte] = FixedArray::make(512, b'\x00')
  let name_bytes = @utf8.encode(name)
  let nl = if name_bytes.length() < 100 { name_bytes.length() } else { 100 }
  for i in 0..<nl {
    header[i] = name_bytes[i]
  }
  // Linkname field: 100 bytes at offset 157, used by typeflag '2'.
  let link_bytes = @utf8.encode(link_target)
  let ll = if link_bytes.length() < 100 { link_bytes.length() } else { 100 }
  for i in 0..<ll {
    header[157 + i] = link_bytes[i]
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
  header[156] = typeflag
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
/// What an archive member is. Restoring a `TarSymlink` as a regular
/// file (which is what storing only file members amounted to) turns a
/// link into a copy — a different tree, silently.
priv enum TarKind {
  TarFile
  TarDir
  TarSymlink(String)
} derive(Eq)

///|
priv struct TarEntry {
  name : String
  content : Bytes
  mode : Int
  kind : TarKind
}

///|
/// Outcome of parsing an archive. Callers turn `TarMalformed` into a
/// cache miss, never into a silent partial restore — which is exactly
/// what returning a bare `Array[TarEntry]` used to allow.
priv enum TarResult {
  TarOk(Array[TarEntry])
  TarMalformed(String)
}

///|
/// Parse every regular-file member.
///
/// Returns `TarMalformed` for a header whose checksum does not match, a
/// member whose declared size runs past the end of the data, a member
/// kind we never write, and an archive that ends without its zero-block
/// EOF marker. Each of those used to `break` out of the loop and return
/// the members read so far — indistinguishable, to the caller, from a
/// complete archive that happened to contain fewer outputs.
fn tar_iter(data : Bytes) -> TarResult {
  let out : Array[TarEntry] = []
  let mut pos = 0
  // Set by a preceding GNU LongLink ('L') member; overrides the next
  // regular member's truncated 100-byte name.
  let mut pending_long_name : String? = None
  // Set by a preceding GNU 'K' member; overrides the next member's
  // truncated 100-byte link target.
  let mut pending_long_link : String? = None
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
      return TarOk(out)
    }
    if !tar_checksum_ok(data, pos) {
      return TarMalformed("bad header checksum at offset \{pos}")
    }
    let name = tar_read_cstring(data, pos, 100)
    let mode = tar_read_octal(data, pos + 100, 8)
    let size = tar_read_octal(data, pos + 124, 12)
    let typeflag = data[pos + 156].to_int()
    let link_name = tar_read_cstring(data, pos + 157, 100)
    if size < 0 {
      return TarMalformed("negative member size at offset \{pos}")
    }
    pos = pos + 512
    if pos + size > data.length() {
      return TarMalformed(
        "member `\{name}` runs past the end of the archive",
      )
    }
    // The two GNU long-name extensions carry the *next* member's name
    // ('L') or link target ('K') as their payload, NUL-terminated.
    if typeflag == 'L'.to_int() {
      pending_long_name = Some(tar_read_cstring(data, pos, size))
    } else if typeflag == 'K'.to_int() {
      pending_long_link = Some(tar_read_cstring(data, pos, size))
    } else {
      let effective_name = match pending_long_name {
        Some(n) => n
        None => name
      }
      let effective_link = match pending_long_link {
        Some(l) => l
        None => link_name
      }
      pending_long_name = None
      pending_long_link = None
      let kind = if typeflag == '5'.to_int() {
        Some(TarDir)
      } else if typeflag == '2'.to_int() {
        Some(TarSymlink(effective_link))
      } else if typeflag == 0 || typeflag == '0'.to_int() {
        Some(TarFile)
      } else {
        // A member kind we never write (hardlink, device, pax header).
        // Refuse rather than skip: a remote entry containing one is not
        // an archive this cache produced.
        None
      }
      match kind {
        None =>
          return TarMalformed(
            "unsupported tar member type \{typeflag} for `\{name}`",
          )
        Some(kind) =>
          if effective_name.length() > 0 {
            let cbuf : FixedArray[Byte] = FixedArray::make(size, b'\x00')
            for i in 0..<size {
              cbuf[i] = data[pos + i]
            }
            // ustar writes directory names with a trailing slash; the
            // restore path wants them without.
            let stored_name = if kind == TarDir &&
              effective_name.has_suffix("/") {
              effective_name[0:effective_name.length() - 1].to_owned()
            } else {
              effective_name
            }
            out.push(
              TarEntry::{
                name: stored_name,
                content: Bytes::from_array(cbuf),
                mode,
                kind,
              },
            )
          }
      }
    }
    let padded = (size + 511) / 512 * 512
    pos = pos + padded
  }
  // Fell off the end without hitting the zero-block EOF marker: the
  // archive is truncated.
  TarMalformed("archive is truncated (no EOF marker)")
}

///|
/// Verify the ustar header checksum at `off`.
///
/// The stored checksum is the unsigned sum of all 512 header bytes with
/// the checksum field itself read as 8 spaces. Historical tars also
/// wrote a signed sum, so accept either.
fn tar_checksum_ok(data : Bytes, off : Int) -> Bool {
  if off + 512 > data.length() {
    return false
  }
  let stored = tar_read_octal(data, off + 148, 8)
  let mut unsigned_sum = 0
  let mut signed_sum = 0
  for i in 0..<512 {
    let raw = if i >= 148 && i < 156 { b' ' } else { data[off + i] }
    unsigned_sum = unsigned_sum + raw.to_int()
    // Byte -> Int is already unsigned in MoonBit; re-derive the signed
    // reading the historical implementations produced.
    signed_sum = signed_sum +
      (if raw.to_int() >= 128 { raw.to_int() - 256 } else { raw.to_int() })
  }
  stored == unsigned_sum || stored == signed_sum
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
