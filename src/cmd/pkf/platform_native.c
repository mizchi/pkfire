#include <moonbit.h>
#include <stdint.h>

/*
 * Execution-platform identity for the action key.
 *
 * The action key has to distinguish "the same command on linux/amd64"
 * from "the same command on darwin/arm64": a cached `entry.tar.gz` full
 * of Mach-O objects must never be restored on a Linux runner. Bazel
 * models this as the execution platform; we fold a compile-time
 * `<os>/<arch>` string into the descriptor.
 *
 * Resolved from the C preprocessor rather than `uname(3)` so it is a
 * constant: the value must not depend on the runtime environment of the
 * process computing the key.
 */

#if defined(_WIN32)
#define PKF_OS "windows"
#elif defined(__APPLE__)
#define PKF_OS "darwin"
#elif defined(__linux__)
#define PKF_OS "linux"
#elif defined(__FreeBSD__)
#define PKF_OS "freebsd"
#elif defined(__OpenBSD__)
#define PKF_OS "openbsd"
#elif defined(__NetBSD__)
#define PKF_OS "netbsd"
#else
#define PKF_OS "unknown"
#endif

#if defined(__x86_64__) || defined(_M_X64)
#define PKF_ARCH "amd64"
#elif defined(__aarch64__) || defined(_M_ARM64)
#define PKF_ARCH "arm64"
#elif defined(__i386__) || defined(_M_IX86)
#define PKF_ARCH "386"
#elif defined(__riscv) && (__riscv_xlen == 64)
#define PKF_ARCH "riscv64"
#else
#define PKF_ARCH "unknown"
#endif

/*
 * Returns "<os>/<arch>" as a NUL-terminated MoonBit byte string. The
 * caller decodes it as UTF-8; the value is pure ASCII.
 */
MOONBIT_FFI_EXPORT moonbit_bytes_t mizchi_pkf_exec_platform(void) {
  const char *s = PKF_OS "/" PKF_ARCH;
  int32_t n = 0;
  while (s[n] != '\0') {
    n++;
  }
  moonbit_bytes_t out = moonbit_make_bytes(n, 0);
  for (int32_t i = 0; i < n; i++) {
    out[i] = (uint8_t)s[i];
  }
  return out;
}

#ifdef _WIN32
#include <process.h>
MOONBIT_FFI_EXPORT int32_t mizchi_pkf_getpid(void) { return (int32_t)_getpid(); }
#else
#include <unistd.h>
/*
 * Used to name the temp file a cache entry is built in before it is
 * renamed into place, so two processes storing the same action key do
 * not write to the same partial file.
 */
MOONBIT_FFI_EXPORT int32_t mizchi_pkf_getpid(void) { return (int32_t)getpid(); }
#endif
