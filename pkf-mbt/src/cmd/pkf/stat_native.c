#include <moonbit.h>
#include <stdint.h>

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

#endif
