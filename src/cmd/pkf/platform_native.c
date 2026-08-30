/* sched_getaffinity / CPU_COUNT are GNU extensions; the define has to
 * precede every include or glibc hides them. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

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

/*
 * Number of CPUs available to this process, for `pkf run -j auto`.
 *
 * "Available" rather than "installed": on a container with a CPU quota
 * the online count is the host's, and sizing a build to it is how a
 * two-core CI runner ends up trying to run 64 compilers. Linux exposes
 * the affinity mask, which cgroup-aware runtimes set; everything else
 * falls back to the online count. Returns 0 when nothing can be
 * determined, and the caller decides what to do with that rather than
 * silently picking a number.
 */
#ifdef _WIN32
#include <windows.h>
MOONBIT_FFI_EXPORT int32_t mizchi_pkf_cpu_count(void) {
  SYSTEM_INFO info;
  GetSystemInfo(&info);
  return (int32_t)info.dwNumberOfProcessors;
}
#else
#include <unistd.h>
#ifdef __linux__
#include <sched.h>
#endif
MOONBIT_FFI_EXPORT int32_t mizchi_pkf_cpu_count(void) {
#ifdef __linux__
  cpu_set_t set;
  CPU_ZERO(&set);
  if (sched_getaffinity(0, sizeof(set), &set) == 0) {
    int n = CPU_COUNT(&set);
    if (n > 0) {
      return (int32_t)n;
    }
  }
#endif
  long n = sysconf(_SC_NPROCESSORS_ONLN);
  return n > 0 ? (int32_t)n : 0;
}
#endif

/*
 * Monotonic-ish wall clock in milliseconds.
 *
 * `mizchi_pkf_now_sec` is what the sequential runner reported timings
 * with, and at one-second resolution a parallel run's per-task times
 * are mostly zeros. This is only used for reporting, so a coarse
 * epoch-based value is fine; it never reaches the action key.
 */
#ifdef _WIN32
MOONBIT_FFI_EXPORT int64_t mizchi_pkf_now_ms(void) {
  return (int64_t)GetTickCount64();
}
#else
#include <sys/time.h>
MOONBIT_FFI_EXPORT int64_t mizchi_pkf_now_ms(void) {
  struct timeval tv;
  if (gettimeofday(&tv, NULL) != 0) {
    return 0;
  }
  return (int64_t)tv.tv_sec * 1000 + (int64_t)(tv.tv_usec / 1000);
}
#endif
