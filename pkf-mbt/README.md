# pkf-mbt

MoonBit re-implementation of the `pkf` CLI. Phase 1 MVP: `pkf run <task>` only.

## Status

This is an experimental rewrite that lives alongside the Go pkfire (the binary at `../pkf`). It evaluates the Taskfile through [`mizchi/pkl`](https://github.com/mizchi/pkl-mbt) (mpkl) instead of the JVM-backed Apple Pkl CLI, and otherwise reproduces enough of pkfire's wire protocol to walk the task DAG and run shell commands.

| Feature | mbt pkf | go pkf |
| --- | --- | --- |
| `pkf run <task>` (simple) | yes | yes |
| Task dependency resolution (topo sort) | yes | yes |
| `$NAME` env from task `env { }` | yes | yes |
| `cwd` per task | yes | yes |
| Typed CLI flags (`params`) | yes (string / enum / int / bool) | yes |
| `acceptsArgs` positional args | yes | yes |
| Long-running `services` (start + readiness + teardown) | yes | yes |
| `pkf list` / `pkf graph` (introspection) | yes | yes |
| `pkf affected [path...]` / `--check` | yes | yes |
| Content-addressed cache (local) | yes (SHA-256, flat dir) | yes (BLAKE3, tar.zst) |
| Cache interop with go pkfire | no (separate namespace) | n/a |
| Remote cache (HTTP) | yes (env-driven) | yes |
| Watch mode | no | yes |
| `pkf list` / `pkf graph` / `pkf affected` | no | yes |
| Pkl evaluation | in-process via `mizchi/pkl` library | in-process via pkl-go binding |
| Binary size | 5.0 MB | 11 MB |
| `pkf run hello` (cache hit) | **7.1 ms** | 16.5 ms |
| `pkf run build` (cache hit) | **8.5 ms** | 19.1 ms |
| `pkf run build` (cold) | **92.7 ms** | 111.7 ms |

## Build

Requires the MoonBit toolchain (`moon`) and `mpkl` on `PATH` (built from <https://github.com/mizchi/pkl-mbt>).

```sh
moon build --target native --release
# Binary lands at _build/native/release/build/src/cmd/pkf/pkf.exe
```

## Architecture

```
+----------+    eval_module_path()    +-----------+
| pkf-mbt  | -----------------------> |  loader   |
| cmd/pkf  |    in-process call       |  (this)   |
+----------+                          +-----------+
     |                                      |
     |                                      | walks amends/imports recursively,
     |                                      | reads files + cached package://
     |                                      v
     |                                +-----------+
     |                                | mizchi/pkl|
     |                                | (library) |
     |                                +-----------+
     |
     | spawn(<shell> <flags> <cmd>) per task via mizchi/x/process
     v
+----------+
| user task|
+----------+
```

The loader lives at `src/loader/loader.mbt` and reuses `mizchi/pkl`'s public `AnalysisSession`, `parse_source`, and `render_value_as_json` APIs. No subprocess hop. The loader handles file paths and cached `package://` resolution (reads from `$XDG_CACHE_HOME/pkl-mbt/package-2/...`); HTTP modules and import globs fall back to the `mpkl` CLI subprocess if found on PATH (intentional graceful degradation rather than hard failure).

## Cache

Content-addressed local cache lands per-task outputs at
`$XDG_CACHE_HOME/pkfire-mbt/cas/<key[0:2]>/<key[2:]>/outputs/...` (override via
`PKFIRE_MBT_CACHE_DIR`). The action key hashes `cmd`, `shell`, `shellFlags`,
sorted `env`, sorted `tools`, and the sorted SHA-256 digests of every input
file expanded from the task's `inputs` glob (supports `*`, `?`, `**`).

A `cache: Boolean` of `false` opts a task out — `pkf run` skips the lookup
and never stores its outputs.

Wire incompatibility with go pkfire is intentional for the MVP:

- `pkf-mbt` uses SHA-256 (`moonbitlang/x/crypto.sha256`), `pkf` uses BLAKE3.
- `pkf-mbt` stores a flat directory + `manifest` text file; `pkf` stores a
  single `outputs.tar.zst` archive.

Future phases can swap in BLAKE3 + tar.zst once those land in the MoonBit
ecosystem; the action-key text format already mirrors go pkfire's so the
key hex stays bit-stable across the swap.

### Remote cache

Set `PKFIRE_MBT_REMOTE_CACHE` to an HTTP base URL and (optionally)
`PKFIRE_MBT_REMOTE_TOKEN` for a `Authorization: Bearer <token>` header.
On cache miss, `pkf` first checks the local CAS, then the remote backend
via `GET <base>/cas/<key[0:2]>/<key[2:]>/{manifest, outputs/<rel>}`. A
remote hit warms the local CAS as it restores. After a successful build,
the local store is followed by a best-effort PUT of the same files —
upload failures log once and never abort the run.

Layout matches the local CAS (manifest text file + flat output tree),
so any HTTP server that supports `GET`/`PUT` works as a backend. Each
file is one request; archive support (single tarball per entry) is a
future improvement once tar+zstd land in the MoonBit ecosystem.

File mode preservation: each manifest entry records `<rel>\t<mode>`. At
store time the mode is detected from the file's magic bytes (ELF,
Mach-O 32/64 LE/BE, Mach-O fat, Windows PE, shebang → 0o755; everything
else → 0o644). At restore time the recorded mode is reapplied via
`mizchi/x/fs.chmod`. Older single-column manifests fall back to 0o644
for backwards compatibility.

## Subcommands

```
pkf run <task> [--name=value]... [-- positional...]
pkf list [-v] [--all]                   # tasks in authored order; -v adds params/deps/inputs/outputs
pkf graph [--all]                       # ASCII deps tree per public task
pkf affected <path>...                  # print the run plan for the given changed files
pkf affected --check                    # run declared workflowTests and assert plans
pkf watch [task...]                     # re-run affected tasks on file change (Ctrl-C to stop)
pkf up [service...]                     # bring up service = true tasks until Ctrl-C
```

`pkf up` brings each `service = true` task up in declared order, waits
for its `readyPort` / `readyCmd` probe to pass, then blocks until SIGINT
or SIGTERM. On signal it runs the same `SIGTERM → grace → SIGKILL`
teardown that `pkf run` uses for transient services. The signal handler
is installed via a small C FFI (`signal_native.c`) so we avoid
`moonbitlang/async`'s `set_global_cancellation_signals` (which
terminates the whole event loop on receipt and never lets the user-side
teardown branch run).

`pkf watch` monitors the working directory through `mizchi/fswatch` —
FSEvents on macOS, inotify on Linux, polling fallback elsewhere. Events
go through `compute_affected` to pick the same plan `pkf affected` would
emit, then each task runs in topological order. Optional positional
args scope the re-runs to that subset of tasks. Common build / VCS /
cache directories (`_build`, `.git`, `node_modules`, `target`, `.cache`,
editor swap files) are excluded so a build artifact doesn't trigger a
re-run.


`--all` includes `visibility = "internal"` tasks; otherwise they are hidden. Service tasks show in `list` with a `[service]` tag and are otherwise treated like regular tasks (apart from being rejected as direct `pkf run` targets).

## Known limitations

- No remote cache (`PKFIRE_REMOTE_CACHE`).
- ~~`params` (typed CLI flags) are not consumed yet~~ — now supported in
  phase 4: `pkf run greet --who=alice --lang_=ja`. Resolution is
  CLI &gt; declared default &gt; error. Type validation covers `string` /
  `enum` (membership against `choices`) / `int` (parsable) / `bool`
  (`true`/`false` literal or bare `--flag` = `true`). Resolved values
  fold into the action key, so `pkf run greet --who=alice` and
  `pkf run greet --who=bob` produce distinct cache entries.
- ~~`acceptsArgs` is likewise ignored~~ — now supported in phase 4:
  positional args after `--` (`pkf run count -- a b c`) are forwarded
  to `cmd` as `$1` ... `$@` when the task declares
  `acceptsArgs = true`. Tasks without it reject extra positional args.
- Services (long-running side processes) are supported as of phase 5: each
  task in `services { ... }` spawns in declared order before `cmd` runs,
  with TCP-connect readiness probing against `readyPort` (timeout per
  `readyTimeoutSeconds`). Reuse semantics match Apple pkfire: if the
  port already accepts a connection, the service is treated as
  already-up and no teardown happens. After `cmd` finishes, each
  spawned service receives `SIGTERM`, then `SIGKILL` after
  `shutdownTimeoutSeconds`. As of `mizchi/x@0.3.3`, the leaf signal
  goes through native `kill(2)` (one fewer subprocess per teardown);
  the subtree walk still uses `pkill -P` because the spawn's pgid
  leader-set is sub-millisecond-racy (the kernel-level
  `POSIX_SPAWN_SETPGROUP` flag would need to land upstream in
  `moonbitlang/async/process.spawn` to close the race). If a service's
  shell wraps a long-running child that re-forks beyond what `pkill
  -P` can reach, `pkf` may leave it orphaned — workaround: write
  `cmd = "exec <binary> ..."` so the shell replaces itself with the
  real process. Readiness probing supports both `readyPort` (TCP
  connect) and `readyCmd` (shell exit-0); when both are set, BOTH
  must pass before the service is considered up.
- Glob support: `*` (no slash) / `?` (single char) / `**` (zero-or-more
  segments) only. No character classes, no `{a,b}` alternation.
- Exit-on-first-failure semantics: a non-zero task aborts the plan; matches
  Go's `pkf run` for the simple case.
