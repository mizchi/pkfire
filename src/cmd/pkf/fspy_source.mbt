// `pkf trace` — discover a task's real inputs by watching what it reads.
//
// pkfire's cache is only as sound as a task's declared `inputs`. Every
// glob is a hand-maintained claim about what the command reads, and the
// two ways it goes wrong are both silent: under-declare and the cache
// returns a stale entry after an edit it never hashed; over-declare and
// every unrelated touch busts a key that did not have to change.
//
// vite-task (https://zenn.dev/herp_inc/articles/strange-task-runner)
// answers this by not asking: it observes the files the process
// actually opens and uses that as the cache key. This is the same
// mechanism — an `LD_PRELOAD` shim over libc's open family — wired as
// an auditing command rather than as the keying path. `pkf trace` runs
// a task under the shim and reports the read set against what the
// Taskfile declares; `--emit` prints the `inputs { ... }` block that
// would match reality.
//
// Interposition over ptrace/seccomp is the article's conclusion and it
// holds here: both of those stop the traced process on every syscall,
// and a build issues hundreds of thousands. Interposing libc keeps the
// cost to an appended line per open. What it buys in speed it gives up
// in coverage — a statically linked binary never calls into libc — so
// `trace` reports that gap rather than presenting the read set as
// complete. See `docs/auto-inputs.md`.

///|
/// The shim's C source, and the only copy of it. `pkf trace` writes it
/// out and compiles it on demand rather than shipping a second release
/// artifact per platform; the built library is cached under the pkfire
/// cache root, keyed by the digest of this text, so the compile happens
/// once per pkf version per machine.
let fspy_preload_source : String =
  (
  #|/*
  #| * pkf fspy — an LD_PRELOAD shim that records the files a task's
  #| * process tree opens.
  #| *
  #| * Compiled on demand by `pkf trace`. Every record is one line appended
  #| * to the file named by $PKF_FSPY_LOG:
  #| *
  #| *     R<TAB><absolute path><LF>      a read-mode open
  #| *     W<TAB><absolute path><LF>      a write-mode open
  #| *
  #| * The log is opened O_APPEND by each process in the tree, so children
  #| * inherited through exec append to the same file without coordination.
  #| *
  #| * Why interposition rather than ptrace or seccomp: both stop the
  #| * traced process on every syscall so a tracer can run, and a build
  #| * opens tens of thousands of files. Interposing libc's own open()
  #| * keeps everything in user space, so the cost is an appended line
  #| * rather than two context switches.
  #| *
  #| * The cost is coverage: a statically linked binary (a Go toolchain,
  #| * say) issues syscalls without going through libc and is invisible
  #| * here. `pkf trace` reports that gap rather than pretending the read
  #| * set is complete.
  #| */
  #|
  #|#define _GNU_SOURCE
  #|#include <dlfcn.h>
  #|#include <fcntl.h>
  #|#include <limits.h>
  #|#include <stdarg.h>
  #|#include <stdio.h>
  #|#include <stdlib.h>
  #|#include <string.h>
  #|#include <unistd.h>
  #|
  #|typedef int (*open_fn)(const char *, int, ...);
  #|typedef int (*openat_fn)(int, const char *, int, ...);
  #|typedef FILE *(*fopen_fn)(const char *, const char *);
  #|
  #|static int pkf_log_fd = -1;
  #|
  #|/*
  #| * Reentrancy guard. dlsym() and the record path itself can allocate,
  #| * and an allocator that grows the heap may open /proc or a locale
  #| * file — which would come straight back through this hook. One
  #| * thread-local flag keeps a hook from observing itself.
  #| */
  #|static __thread int pkf_in_hook = 0;
  #|
  #|static void pkf_init_log(void) {
  #|  if (pkf_log_fd != -1) {
  #|    return;
  #|  }
  #|  const char *path = getenv("PKF_FSPY_LOG");
  #|  if (path == NULL || path[0] == '\0') {
  #|    pkf_log_fd = -2; /* disabled */
  #|    return;
  #|  }
  #|  /* This reenters the open() wrapper below, which is harmless: the
  #|   * caller already set pkf_in_hook, so that call records nothing. */
  #|  int fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600);
  #|  pkf_log_fd = (fd < 0) ? -2 : fd;
  #|}
  #|
  #|/*
  #| * Append one record. O_APPEND on a regular file makes a single write()
  #| * under PIPE_BUF atomic on Linux, so concurrent processes in the tree
  #| * interleave whole lines rather than fragments — which is why the
  #| * record is assembled into one buffer before the write.
  #| */
  #|static void pkf_record(char kind, const char *path) {
  #|  if (path == NULL || path[0] == '\0') {
  #|    return;
  #|  }
  #|  pkf_init_log();
  #|  if (pkf_log_fd < 0) {
  #|    return;
  #|  }
  #|  char line[PATH_MAX * 2 + 8];
  #|  size_t n = 0;
  #|  line[n++] = kind;
  #|  line[n++] = '\t';
  #|  if (path[0] != '/') {
  #|    /* Relative path: qualify it with the process's cwd, since the
  #|     * reader has no way to know what that was. */
  #|    char cwd[PATH_MAX];
  #|    if (getcwd(cwd, sizeof(cwd)) != NULL) {
  #|      size_t clen = strlen(cwd);
  #|      if (n + clen + 1 < sizeof(line)) {
  #|        memcpy(line + n, cwd, clen);
  #|        n += clen;
  #|        line[n++] = '/';
  #|      }
  #|    }
  #|  }
  #|  size_t plen = strlen(path);
  #|  if (n + plen + 1 >= sizeof(line)) {
  #|    return; /* absurdly long path: drop rather than truncate */
  #|  }
  #|  memcpy(line + n, path, plen);
  #|  n += plen;
  #|  line[n++] = '\n';
  #|  ssize_t ignored = write(pkf_log_fd, line, n);
  #|  (void)ignored;
  #|}
  #|
  #|static char pkf_kind_of_flags(int flags) {
  #|  int acc = flags & O_ACCMODE;
  #|  if (acc == O_WRONLY || acc == O_RDWR) {
  #|    return 'W';
  #|  }
  #|  if ((flags & O_CREAT) != 0 || (flags & O_TRUNC) != 0) {
  #|    return 'W';
  #|  }
  #|  return 'R';
  #|}
  #|
  #|static char pkf_kind_of_mode(const char *mode) {
  #|  if (mode == NULL) {
  #|    return 'R';
  #|  }
  #|  if (mode[0] == 'r' && strchr(mode, '+') == NULL) {
  #|    return 'R';
  #|  }
  #|  return 'W';
  #|}
  #|
  #|#define PKF_WRAP_OPEN(name, sym)                                              \
  #|  int name(const char *path, int flags, ...) {                                \
  #|    static open_fn real = NULL;                                               \
  #|    if (real == NULL) {                                                       \
  #|      real = (open_fn)dlsym(RTLD_NEXT, sym);                                  \
  #|      if (real == NULL) {                                                     \
  #|        return -1;                                                            \
  #|      }                                                                       \
  #|    }                                                                         \
  #|    mode_t mode = 0;                                                          \
  #|    if ((flags & O_CREAT) != 0) {                                             \
  #|      va_list ap;                                                             \
  #|      va_start(ap, flags);                                                    \
  #|      mode = (mode_t)va_arg(ap, int);                                         \
  #|      va_end(ap);                                                             \
  #|    }                                                                         \
  #|    if (!pkf_in_hook) {                                                       \
  #|      pkf_in_hook = 1;                                                        \
  #|      pkf_record(pkf_kind_of_flags(flags), path);                             \
  #|      pkf_in_hook = 0;                                                        \
  #|    }                                                                         \
  #|    return real(path, flags, mode);                                           \
  #|  }
  #|
  #|PKF_WRAP_OPEN(open, "open")
  #|PKF_WRAP_OPEN(open64, "open64")
  #|
  #|#define PKF_WRAP_OPENAT(name, sym)                                            \
  #|  int name(int dirfd, const char *path, int flags, ...) {                     \
  #|    static openat_fn real = NULL;                                             \
  #|    if (real == NULL) {                                                       \
  #|      real = (openat_fn)dlsym(RTLD_NEXT, sym);                                \
  #|      if (real == NULL) {                                                     \
  #|        return -1;                                                            \
  #|      }                                                                       \
  #|    }                                                                         \
  #|    mode_t mode = 0;                                                          \
  #|    if ((flags & O_CREAT) != 0) {                                             \
  #|      va_list ap;                                                             \
  #|      va_start(ap, flags);                                                    \
  #|      mode = (mode_t)va_arg(ap, int);                                         \
  #|      va_end(ap);                                                             \
  #|    }                                                                         \
  #|    /* Only absolute paths and AT_FDCWD-relative ones can be resolved         \
  #|     * without tracking every open directory fd; a path relative to           \
  #|     * some other dirfd is skipped rather than recorded wrong. */             \
  #|    if (!pkf_in_hook && (path != NULL) &&                                     \
  #|        (path[0] == '/' || dirfd == AT_FDCWD)) {                              \
  #|      pkf_in_hook = 1;                                                        \
  #|      pkf_record(pkf_kind_of_flags(flags), path);                             \
  #|      pkf_in_hook = 0;                                                        \
  #|    }                                                                         \
  #|    return real(dirfd, path, flags, mode);                                    \
  #|  }
  #|
  #|PKF_WRAP_OPENAT(openat, "openat")
  #|PKF_WRAP_OPENAT(openat64, "openat64")
  #|
  #|#define PKF_WRAP_FOPEN(name, sym)                                             \
  #|  FILE *name(const char *path, const char *mode) {                            \
  #|    static fopen_fn real = NULL;                                              \
  #|    if (real == NULL) {                                                       \
  #|      real = (fopen_fn)dlsym(RTLD_NEXT, sym);                                 \
  #|      if (real == NULL) {                                                     \
  #|        return NULL;                                                          \
  #|      }                                                                       \
  #|    }                                                                         \
  #|    if (!pkf_in_hook) {                                                       \
  #|      pkf_in_hook = 1;                                                        \
  #|      pkf_record(pkf_kind_of_mode(mode), path);                               \
  #|      pkf_in_hook = 0;                                                        \
  #|    }                                                                         \
  #|    return real(path, mode);                                                  \
  #|  }
  #|
  #|PKF_WRAP_FOPEN(fopen, "fopen")
  #|PKF_WRAP_FOPEN(fopen64, "fopen64")
  )
