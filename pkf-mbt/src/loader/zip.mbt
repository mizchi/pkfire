// In-process ZIP reader/extractor for Pkl-package archives, ported into the
// loader package (phase 3) from
//   mizchi/pkl/cmd/mpkl/package_download.mbt (ZIP region).
//
// Key adaptation: every failure raises `LoaderError(msg)` (declared in
// loader.mbt) instead of the original `package_download_error`, so ZIP
// failures join the loader's existing error path.
//
// Supports stored (method 0) and deflate (method 8) entries; zip64 archives
// are explicitly rejected.

///|
priv struct ZipEntry {
  path : String
  content : Bytes
  is_dir : Bool
}

///|
fn zip_bytes_slice(data : Bytes, start : Int, end : Int) -> Bytes raise LoaderError {
  if start < 0 || end < start || end > data.length() {
    raise LoaderError("byte slice out of range")
  }
  Bytes::from_array(FixedArray::makei(end - start, fn(i) { data[start + i] }))
}

///|
fn zip_empty_bytes() -> Bytes {
  Bytes::from_array([])
}

///|
fn read_u16_le(data : Bytes, offset : Int) -> Int raise LoaderError {
  if offset < 0 || offset + 2 > data.length() {
    raise LoaderError("unexpected end of zip data")
  }
  data[offset].to_int() | (data[offset + 1].to_int() << 8)
}

///|
fn read_u32_le(data : Bytes, offset : Int) -> Int raise LoaderError {
  if offset < 0 || offset + 4 > data.length() {
    raise LoaderError("unexpected end of zip data")
  }
  data[offset].to_int() |
  (data[offset + 1].to_int() << 8) |
  (data[offset + 2].to_int() << 16) |
  (data[offset + 3].to_int() << 24)
}

///|
fn find_zip_eocd(data : Bytes) -> Int raise LoaderError {
  if data.length() < 22 {
    raise LoaderError("zip data is too short")
  }
  let min = if data.length() > 66000 { data.length() - 66000 } else { 0 }
  let mut i = data.length() - 22
  while i >= min {
    if read_u32_le(data, i) == 0x06054b50 {
      return i
    }
    i -= 1
  }
  raise LoaderError("zip end-of-central-directory not found")
}

///|
fn read_zip_entries(data : Bytes) -> Array[ZipEntry] raise LoaderError {
  let eocd = find_zip_eocd(data)
  let total_entries = read_u16_le(data, eocd + 10)
  let central_offset = read_u32_le(data, eocd + 16)
  let entries : Array[ZipEntry] = []
  let mut offset = central_offset
  for _ in 0..<total_entries {
    if read_u32_le(data, offset) != 0x02014b50 {
      raise LoaderError("invalid zip central directory header")
    }
    let flags = read_u16_le(data, offset + 8)
    let compression_method = read_u16_le(data, offset + 10)
    let compressed_size = read_u32_le(data, offset + 20)
    let uncompressed_size = read_u32_le(data, offset + 24)
    let name_len = read_u16_le(data, offset + 28)
    let extra_len = read_u16_le(data, offset + 30)
    let comment_len = read_u16_le(data, offset + 32)
    let local_offset = read_u32_le(data, offset + 42)
    if compressed_size == 0xffffffff || uncompressed_size == 0xffffffff {
      raise LoaderError("zip64 package archives are not supported yet")
    }
    let name_start = offset + 46
    let name_end = name_start + name_len
    let name_bytes = zip_bytes_slice(data, name_start, name_end)
    let name = try @utf8.decode(name_bytes[:]) catch {
      _ => raise LoaderError("invalid utf-8 in zip entry name")
    }
    let is_dir = name.has_suffix("/")
    if read_u32_le(data, local_offset) != 0x04034b50 {
      raise LoaderError("invalid zip local file header")
    }
    let local_name_len = read_u16_le(data, local_offset + 26)
    let local_extra_len = read_u16_le(data, local_offset + 28)
    let body_start = local_offset + 30 + local_name_len + local_extra_len
    let body_end = body_start + compressed_size
    let compressed = zip_bytes_slice(data, body_start, body_end)
    let content = if is_dir {
      zip_empty_bytes()
    } else {
      match compression_method {
        0 => compressed
        8 =>
          try @zlib.deflate_decompress(compressed, max_size=uncompressed_size) catch {
            _ => raise LoaderError("zip deflate decompression failed: \{name}")
          }
        _ =>
          raise LoaderError(
            "unsupported zip compression method: \{compression_method}",
          )
      }
    }
    if !is_dir && content.length() != uncompressed_size {
      raise LoaderError("zip entry size mismatch: \{name}")
    }
    ignore(flags)
    entries.push({ path: name, content, is_dir })
    offset = name_end + extra_len + comment_len
  }
  entries
}

///|
fn zip_entry_path_is_safe(path : String) -> Bool {
  if path == "" || path.has_prefix("/") || path.find("\\") is Some(_) {
    return false
  }
  let mut start = 0
  let mut i = 0
  while i <= path.length() {
    if i == path.length() || path[i].to_int().unsafe_to_char() == '/' {
      let segment = String::unsafe_substring(path, start~, end=i)
      if segment == ".." {
        return false
      }
      start = i + 1
    }
    i += 1
  }
  true
}

///|
fn zip_ensure_dir(path : String) -> Unit raise LoaderError {
  if path == "" || path == "/" {
    return
  }
  if @fs.path_exists(path) {
    let dir_ok = (try? @fs.is_dir(path)).unwrap_or(false)
    if dir_ok {
      return
    }
    raise LoaderError("path exists but is not a directory: \{path}")
  }
  let mut i = if path.has_prefix("/") { 1 } else { 0 }
  while i <= path.length() {
    if i == path.length() || path[i].to_int().unsafe_to_char() == '/' {
      let part = String::unsafe_substring(path, start=0, end=i)
      if part != "" && part != "/" && !(@fs.path_exists(part)) {
        try @fs.create_dir(part) catch {
          _ => raise LoaderError("failed to create directory: \{part}")
        }
      }
    }
    i += 1
  }
}

///|
fn extract_zip_to_dir(data : Bytes, package_dir : String) -> Unit raise LoaderError {
  zip_ensure_dir(package_dir)
  for entry in read_zip_entries(data) {
    if !(zip_entry_path_is_safe(entry.path)) {
      raise LoaderError("unsafe zip entry path: \{entry.path}")
    }
    let target = path_join(package_dir, entry.path)
    if entry.is_dir {
      zip_ensure_dir(target)
    } else {
      zip_ensure_dir(dir_of(target))
      try @fs.write_bytes_to_file(target, entry.content) catch {
        _ => raise LoaderError("failed to write zip entry: \{target}")
      }
    }
  }
}
