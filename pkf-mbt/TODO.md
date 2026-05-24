# pkf-mbt TODO

Phase 1–10 landed. This file tracks what's left.

## Subcommands not yet implemented

### `pkf up [service...]` — long-running supervisor

Brings up `service = true` tasks in the foreground until Ctrl+C, then tears them down with the same `SIGTERM → grace → SIGKILL` flow `pkf run` uses for `services { ... }`.

The supervisor body was prototyped in phase 7 but reverted. Blocker: `mizchi/x/signal.set_global_cancellation_signals` masks SIGINT into a sigwait thread that terminates the whole event loop, so the user-level `protect_from_cancel` teardown branch never executes. The right fix is a custom SIGINT handler installed via C FFI **before** the runtime's signal handler attaches, with a `volatile sig_atomic_t pkf_stop` flag the main loop polls.

Sketch:

```c
/* src/cmd/pkf/process_native.c (new) */
static volatile sig_atomic_t pkf_stop = 0;
static void pkf_handler(int sig) { (void)sig; pkf_stop = 1; }

MOONBIT_FFI_EXPORT void pkf_install_signal_handler(void) {
  struct sigaction sa;
  sa.sa_handler = pkf_handler;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_RESTART;
  sigaction(SIGINT, &sa, NULL);
  sigaction(SIGTERM, &sa, NULL);
}

MOONBIT_FFI_EXPORT int pkf_signal_flag(void) { return pkf_stop; }
```

Then in `up_cmd`: install handler, start services, loop `@async.sleep(250)` while `pkf_signal_flag() == 0`, tear down. The flag check is sync so the cancellation runtime doesn't intercept.

### `pkf watch [task...]` — filesystem watcher

Re-runs the affected plan when any `inputs` glob match changes. Two backends to consider:

1. **Polling fallback**: walk `inputs` globs every 500ms, hash each file's mtime+size into a fingerprint, recompute on change. Works everywhere, costs CPU on large repos.
2. **OS native**: fsevents (macOS), inotify (Linux), ReadDirectoryChangesW (Windows). MoonBit ecosystem doesn't ship bindings for any yet — would need C FFI in `mizchi/x/fs` or a new `mizchi/x/watch` sub-package.

The polling backend is enough for the MVP; the native backend lands as ecosystem matures.

## Cache improvements

### File mode: capture true source mode via stat FFI

Today `detect_file_mode` is a magic-bytes heuristic (`0o755` for ELF / Mach-O / shebang, `0o644` otherwise). Non-executable files with non-default permissions (e.g. `0o600` for a private key, `0o444` for a generated read-only file) lose their mode through the cache.

Real fix: add a tiny C FFI to call `stat(2)` and read `st_mode & 0o7777`. Probably belongs in `mizchi/x/fs` next to the existing `chmod` (and would replace the heuristic here once it lands).

### Single-archive entry format (tar + zstd)

Today each cache entry is a flat directory: `<key>/manifest` + `<key>/outputs/<rel>` per output file. N+1 HTTP requests on remote fetch / push, no compression, no atomicity for large entries.

Go pkfire uses a single `outputs.tar.zst` blob per entry. To match that requires both:

- A tar writer/reader in MoonBit (mizchi/x ships nothing; ~200 lines of clean code).
- A zstd encoder/decoder. The MoonBit ecosystem ships `mizchi/zlib` (DEFLATE) but no zstd. Until zstd lands, an interop option is `outputs.tar.gz` (slower on the wire, but interoperable with `mizchi/zlib`).

Defer until the ecosystem has at least one of these primitives. The current flat layout works fine for moderate output sizes (<100 files per task).

### BLAKE3 action keys

Today the action key uses SHA-256 (`moonbitlang/x/crypto`). Go pkfire uses BLAKE3. The hashing path produces wire-compatible action-key strings (same canonical form), so swapping in BLAKE3 would let pkf-mbt and go pkf share cache entries.

Requires a BLAKE3 implementation in MoonBit. Out of session scope.

## Service / spawn improvements

### Reliable pgid leader for spawned services

`mizchi/x/process@0.3.3` ships a best-effort `new_process_group~ : Bool` flag that calls `setpgid(child, child)` from the parent after posix_spawn returns. There's a sub-millisecond race window where the child can exec before the setpgid lands; on a busy system this drops orphaned children that survive teardown.

The kernel-level fix is `posix_spawnattr_setflags(POSIX_SPAWN_SETPGROUP) + posix_spawnattr_setpgroup(0)` *before* `posix_spawn` runs. This needs an upstream change in `moonbitlang/async/process.spawn` (the actual fork/exec helper). Track upstream and update mizchi/x when it lands.

Workaround in the meantime: pkf-mbt walks the parent-pid tree via `pkill -P` to catch any descendants that escaped the pgid set. Good enough for most service shells (`bash -c "..."` re-fork patterns).

## Glob expander

### `{a,b}` alternation + character classes

Today the glob matcher supports `*` (no slash), `?` (single char), and `**` (zero-or-more slash-separated segments). doublestar's full grammar also includes `{a,b,c}` alternation and `[abc]` / `[!abc]` character classes.

Apple pkfire's inputs declarations occasionally use `[A-Z]*` or `{src,test}/**/*.go`. The current matcher fails over those; the workaround is to spell out alternatives one pattern per line, which works but is ugly.

Implementation: extend `glob_seg_step` (the per-segment char matcher) with `[...]` and pre-expand `{a,b}` into multiple patterns before matching. ~80 lines.

## CLI ergonomics

### `pkf affected --changed=<file>` reads changes from a file

Today the subcommand only takes positional args (`pkf affected services/api/foo.ts`). Apple pkfire also accepts `--changed=<file>` to read newline-separated paths from a file — handy when feeding `git diff --name-only` results through CI.

Tiny addition: read the file into the same `changed : Array[String]` array the positional path takes today.

### Better diagnostics

- `pkf run nonexistent`: today errors with "unknown task `nonexistent`" but doesn't suggest near matches. Ship a Levenshtein-distance suggestion.
- `pkf affected --check` failures: show a unified-diff between expected and computed plan, not just the two arrays.

## Long-term: drop the mpkl subprocess fallback

The embedded loader at `src/loader/loader.mbt` handles file + cached `package://` URIs. For HTTP-fetched modules and glob imports it falls back to spawning `mpkl eval -f json` on PATH. Two ways to close that gap:

1. **Promote loader to `@pkl`**: pkl-mbt exposes a `host` sub-package with package download / HTTP fetch / glob import wired to `mizchi/x/http`. Then pkf-mbt drops the subprocess fallback entirely.
2. **Per-feature ports**: pkf-mbt grows its own glob-import resolver and HTTP downloader. Works in isolation but duplicates code that should live in pkl-mbt.

(1) is the right answer; the surface is already prototyped in `cmd/mpkl/main.mbt`'s `load_path`. Tracked in pkl-mbt's TODO under "promote loader to library API".
