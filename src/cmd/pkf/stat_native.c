#include <moonbit.h>
#include <stdint.h>
#include <time.h>

#ifdef _WIN32

#include <sys/stat.h>
#include <sys/utime.h>

/*
 * Windows' _stat doesn't preserve unix mode bits in any meaningful way
 * (the file system has no unix ownership/perm bits). Return -1 so the
 * MoonBit caller falls back to the magic-byte heuristic, which still
 * gives 0o755 for ELF / PE / shebang.
 */
MOONBIT_FFI_EXPORT int32_t mizchi_pkf_stat_mode(char *path) {
  (void)path;
  return -1;
}

/*
 * mtime as seconds since epoch, 0 on failure.
 *
 * This used to return 0 unconditionally, which made every cache entry
 * look like it was written at the epoch — `pkf cache prune` then swept
 * the whole cache on every invocation. `_stat` carries st_mtime the same
 * way the POSIX one does, and it is already used by lstat_kind below.
 */
MOONBIT_FFI_EXPORT int64_t mizchi_pkf_mtime_sec(char *path) {
  struct _stat st;
  if (_stat(path, &st) != 0) {
    return 0;
  }
  return (int64_t)st.st_mtime;
}

/* file size in bytes, -1 on failure. */
MOONBIT_FFI_EXPORT int64_t mizchi_pkf_file_size(char *path) {
  struct _stat st;
  if (_stat(path, &st) != 0) {
    return -1;
  }
  return (int64_t)st.st_size;
}

/*
 * Set a file's mtime, or stamp it with the current time when `secs` is
 * negative: 0 on success, -1 on failure.
 */
MOONBIT_FFI_EXPORT int32_t mizchi_pkf_set_mtime_sec(char *path,
                                                    int64_t secs) {
  if (secs < 0) {
    return _utime(path, NULL) == 0 ? 0 : -1;
  }
  struct _utimbuf tb;
  tb.actime = (time_t)secs;
  tb.modtime = (time_t)secs;
  return _utime(path, &tb) == 0 ? 0 : -1;
}

/* current time in seconds since epoch. */
MOONBIT_FFI_EXPORT int64_t mizchi_pkf_now_sec(void) {
  return (int64_t)time(NULL);
}

/*
 * Windows has no lstat/readlink in the POSIX sense. Report every path
 * as a regular file or directory; the cache then stores what it always
 * stored there, which is what NTFS round-trips anyway.
 */
MOONBIT_FFI_EXPORT int32_t mizchi_pkf_lstat_kind(char *path) {
  struct _stat st;
  if (_stat(path, &st) != 0) {
    return 0;
  }
  return (st.st_mode & _S_IFDIR) ? 2 : 1;
}

MOONBIT_FFI_EXPORT moonbit_bytes_t mizchi_pkf_readlink(char *path) {
  (void)path;
  return moonbit_make_bytes(0, 0);
}

#else

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

/*
 * Return the file's unix mode bits (S_IRWXU | S_IRWXG | S_IRWXO | sticky)
 * — the lower 12 bits of st_mode, i.e. the same range as the chmod
 * argument. Returns -1 on stat failure (caller falls back to magic-byte
 * detection).
 */
MOONBIT_FFI_EXPORT int32_t mizchi_pkf_stat_mode(char *path) {
  struct stat st;
  if (stat(path, &st) != 0) {
    return -1;
  }
  return (int32_t)(st.st_mode & 0xfff);
}

/*
 * Return the file's mtime as seconds since epoch (Unix timestamp).
 * Returns 0 on stat failure.
 */
MOONBIT_FFI_EXPORT int64_t mizchi_pkf_mtime_sec(char *path) {
  struct stat st;
  if (stat(path, &st) != 0) {
    return 0;
  }
  return (int64_t)st.st_mtime;
}

/*
 * Return the file's size in bytes.
 * Returns -1 on stat failure.
 */
MOONBIT_FFI_EXPORT int64_t mizchi_pkf_file_size(char *path) {
  struct stat st;
  if (stat(path, &st) != 0) {
    return -1;
  }
  return (int64_t)st.st_size;
}

/*
 * Return the current wall-clock time as seconds since epoch.
 */
MOONBIT_FFI_EXPORT int64_t mizchi_pkf_now_sec(void) {
  return (int64_t)time(NULL);
}

/*
 * Set a file's mtime, or stamp it with the current time when `secs` is
 * negative: 0 on success, -1 on failure.
 *
 * Stamping is how a cache hit records that the entry is still in use, so
 * eviction can order by last use rather than by when the entry happened
 * to be written. Setting an explicit time is how a test ages an entry
 * without waiting a day for one.
 */
MOONBIT_FFI_EXPORT int32_t mizchi_pkf_set_mtime_sec(char *path,
                                                    int64_t secs) {
  if (secs < 0) {
    return utimensat(AT_FDCWD, path, NULL, 0) == 0 ? 0 : -1;
  }
  struct timespec times[2];
  times[0].tv_sec = 0;
  times[0].tv_nsec = UTIME_OMIT;
  times[1].tv_sec = (time_t)secs;
  times[1].tv_nsec = 0;
  return utimensat(AT_FDCWD, path, times, 0) == 0 ? 0 : -1;
}

/*
 * Classify a path WITHOUT following symlinks: 1 regular, 2 directory,
 * 3 symlink, 0 anything else (including stat failure).
 *
 * `lstat`, not `stat`, is the whole point. Walking output trees with
 * `stat` makes a symlink indistinguishable from its target, which is
 * how the cache came to dereference links into copies and to follow a
 * `dir/loop -> ..` cycle back out of the declared output tree.
 */
MOONBIT_FFI_EXPORT int32_t mizchi_pkf_lstat_kind(char *path) {
  struct stat st;
  if (lstat(path, &st) != 0) {
    return 0;
  }
  if (S_ISLNK(st.st_mode)) {
    return 3;
  }
  if (S_ISDIR(st.st_mode)) {
    return 2;
  }
  if (S_ISREG(st.st_mode)) {
    return 1;
  }
  return 0;
}

/*
 * Return a symlink's target as raw bytes, or an empty byte string on
 * failure. The target is stored verbatim in the archive (it may be
 * relative), so it is not resolved here.
 */
MOONBIT_FFI_EXPORT moonbit_bytes_t mizchi_pkf_readlink(char *path) {
  char buf[4096];
  ssize_t n = readlink(path, buf, sizeof(buf));
  if (n <= 0) {
    return moonbit_make_bytes(0, 0);
  }
  moonbit_bytes_t out = moonbit_make_bytes((int32_t)n, 0);
  for (ssize_t i = 0; i < n; i++) {
    out[i] = (uint8_t)buf[i];
  }
  return out;
}

#endif
