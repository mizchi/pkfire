# pkf-mbt TODO

Phase 1–10 + the follow-up items (`pkf watch`, `pkf up`, stat-FFI mode,
glob `{a,b}` / `[abc]`) landed. This file tracks what's left.

## Done (kept here as breadcrumbs for the commit-log mapping)

- ✅ `pkf watch [task...]` — via `mizchi/fswatch@0.1.0` (FSEvents / inotify /
  RDCW / polling fallback / Node `fs.watch` on JS target). Re-runs the
  affected plan; built-in excludes for `_build`, `.git`, `node_modules`,
  `target`, `.cache`, editor swap files.
- ✅ `pkf up [service...]` — sigaction + `pthread_sigmask(SIG_UNBLOCK)`
  via C FFI in `signal_native.c`. Avoids
  `set_global_cancellation_signals` so the user-side teardown branch
  actually runs. `moonbitlang/async` blocks SIGINT/SIGTERM on every
  thread at startup; we explicitly unblock the supervisor's main
  thread after installing the handler.
- ✅ File mode via `stat(2)` FFI — `stat_native.c`. Captures the full
  unix mode (`st_mode & 0o7777`) so `0o600` keys / `0o444` outputs
  round-trip through the cache; Windows stub falls back to the
  magic-byte heuristic (NTFS has no meaningful unix mode bits).
- ✅ Glob `{a,b}` brace expansion + `[abc]` / `[!abc]` / `[a-z]`
  character classes. Recursive brace pre-expansion + `glob_seg_step`
  class handling; `expand_glob` no longer fast-paths a pattern
  containing `[`.

## Blocked on the MoonBit ecosystem

### Single-archive entry format (tar + zstd)

Today each cache entry is a flat directory: `<key>/manifest` +
`<key>/outputs/<rel>` per output file. N+1 HTTP requests on remote
fetch / push, no compression, no atomicity for large entries.

Go pkfire uses a single `outputs.tar.zst` blob per entry. To match
that requires both:

- A tar writer/reader in MoonBit (mizchi/x ships nothing; ~200 lines of
  clean code).
- A zstd encoder/decoder. The MoonBit ecosystem ships `mizchi/zlib`
  (DEFLATE) but no zstd. Until zstd lands, an interop option is
  `outputs.tar.gz` (slower on the wire, but interoperable with
  `mizchi/zlib`).

Defer until the ecosystem has at least one of these primitives. The
current flat layout works fine for moderate output sizes (<100 files
per task).

### BLAKE3 action keys

Today the action key uses SHA-256 (`moonbitlang/x/crypto`). Go pkfire
uses BLAKE3. The hashing path produces wire-compatible action-key
strings (same canonical form), so swapping in BLAKE3 would let
pkf-mbt and go pkf share cache entries.

Requires a BLAKE3 implementation in MoonBit. None published yet.

### Reliable pgid leader for spawned services

`mizchi/x/process@0.3.3` ships a best-effort `new_process_group~ : Bool`
flag that calls `setpgid(child, child)` from the parent after
`posix_spawn` returns. There's a sub-millisecond race window where
the child can exec before the setpgid lands; on a busy system this
drops orphaned children that survive teardown.

The kernel-level fix is
`posix_spawnattr_setflags(POSIX_SPAWN_SETPGROUP) + posix_spawnattr_setpgroup(0)`
*before* `posix_spawn` runs. This needs an upstream change in
`moonbitlang/async/process.spawn` (the actual fork/exec helper).
Track upstream and update mizchi/x when it lands.

Workaround in the meantime: pkf-mbt walks the parent-pid tree via
`pkill -P` to catch any descendants that escaped the pgid set. Good
enough for most service shells (`bash -c "..."` re-fork patterns).

## CLI ergonomics

### `pkf affected --changed=<file>` reads changes from a file

Today the subcommand only takes positional args (`pkf affected
services/api/foo.ts`). Apple pkfire also accepts `--changed=<file>`
to read newline-separated paths from a file — handy when feeding
`git diff --name-only` results through CI.

Tiny addition: read the file into the same `changed : Array[String]`
array the positional path takes today.

### Better diagnostics

- `pkf run nonexistent`: today errors with "unknown task
  `nonexistent`" but doesn't suggest near matches. Ship a
  Levenshtein-distance suggestion.
- `pkf affected --check` failures: show a unified-diff between
  expected and computed plan, not just the two arrays.

## Long-term: drop the mpkl subprocess fallback

The embedded loader at `src/loader/loader.mbt` handles file + cached
`package://` URIs. For HTTP-fetched modules and glob imports it falls
back to spawning `mpkl eval -f json` on PATH. CI works around this by
building mpkl from `pkl-mbt` sources as a separate step, then putting
the binary on PATH.

Two ways to close that gap:

1. **Promote loader to `@pkl`**: pkl-mbt exposes a `host` sub-package
   with package download / HTTP fetch / glob import wired to
   `mizchi/x/http`. Then pkf-mbt drops the subprocess fallback entirely
   and the CI's "Build mpkl" step disappears.
2. **Per-feature ports**: pkf-mbt grows its own glob-import resolver
   and HTTP downloader. Works in isolation but duplicates code that
   should live in pkl-mbt.

(1) is the right answer; the surface is already prototyped in
`cmd/mpkl/main.mbt`'s `load_path`. Tracked in pkl-mbt's TODO under
"promote loader to library API".
