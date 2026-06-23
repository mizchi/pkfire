#include <moonbit.h>
#include <stdint.h>
#include <time.h>

#ifdef _WIN32

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

/* mtime: not available on Windows in a simple way — return 0. */
MOONBIT_FFI_EXPORT int64_t mizchi_pkf_mtime_sec(char *path) {
  (void)path;
  return 0;
}

/* file size: not available on Windows in a simple way — return -1. */
MOONBIT_FFI_EXPORT int64_t mizchi_pkf_file_size(char *path) {
  (void)path;
  return -1;
}

/* current time in seconds since epoch. */
MOONBIT_FFI_EXPORT int64_t mizchi_pkf_now_sec(void) {
  return (int64_t)time(NULL);
}

#else

#include <sys/stat.h>

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

#endif
