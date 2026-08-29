# Automatic input discovery (`pkf trace`)

pkfire's cache is keyed on the files a task declares as `inputs`. That
declaration is a hand-maintained claim about what the command reads, and
it fails in two directions, both silently:

- **Under-declared.** The command reads a file no glob covers. Editing
  that file does not change the action key, so `pkf run` returns a stale
  cache entry and the build is wrong. Nothing reports it.
- **Over-declared.** A glob covers files the command never opens. Every
  unrelated edit under that glob busts a key that did not have to
  change, and the cache stops paying for itself.

`pkf trace` closes the loop by *observing* the reads instead of asking
for them.

## The mechanism

The approach is taken from vite-task, described in
[herp_inc's article on their task runner][article]. That article works
through the three ways to observe a process's file access and lands on
the third:

| approach | how it works | why not |
| --- | --- | --- |
| `ptrace(2)` | stop the tracee on every syscall, inspect, resume | two context switches per syscall; a build issues hundreds of thousands |
| `seccomp` user notification | filter to the syscalls of interest, notify a supervisor | narrower than ptrace, but the tracee still blocks on every match |
| **`LD_PRELOAD` interposition** | load a shim before libc so calls to `open()` reach our function first | stays in user space — the cost is an appended line, no context switch |

pkfire ships the third. `pkf trace` writes a small C shim, compiles it
with `$CC` (default `cc`), and runs the task with

```
LD_PRELOAD=<shim>  PKF_FSPY_LOG=<log path>
```

The shim defines `open`, `open64`, `openat`, `openat64`, `fopen` and
`fopen64`, resolves the real implementations through
`dlsym(RTLD_NEXT, …)`, appends one record per call, and delegates.
Records are `R<TAB><path>` or `W<TAB><path>`; the log is opened
`O_APPEND`, which makes each write atomic on Linux, so every process in
the tree can append to it without coordination. Child processes inherit
`LD_PRELOAD` through the environment, so the whole tree is covered
without intercepting `exec`.

The shim is built once per machine and cached under the pkfire cache
root, keyed by the digest of its own source — so the compile happens on
the first `pkf trace` and never again.

## What it cannot see

Interposition works at the libc boundary, so **a statically linked
binary is invisible**: a Go toolchain, or a Rust binary linked against a
static libc, issues syscalls directly and never enters our shim.
`pkf trace` reports an empty trace as exactly that rather than as "this
task reads nothing".

The article's answer to this is a seccomp fallback for static binaries.
That is the natural next step here too, and it is not implemented.

Two more limits worth knowing:

- **Linux only.** macOS has `DYLD_INSERT_LIBRARIES`, but System
  Integrity Protection strips it from protected binaries (including
  `/bin/sh`), which is most of what a Taskfile spawns.
- **`openat` with a directory fd.** A path relative to a directory
  descriptor other than `AT_FDCWD` is skipped rather than recorded
  against a guessed base. Resolving those means tracking every open
  directory fd; skipping is the honest option until then.

## Using it

```sh
pkf trace build            # list the workspace files the task read
pkf trace --check build    # audit those reads against the declared inputs
pkf trace --emit build     # print an `inputs { … }` block matching reality
```

`--check` exits non-zero when the task read a workspace file no declared
input covers — the case that makes the cache return wrong answers — so
it works as a CI gate:

```
pkf: WARN 1 file(s) read but not covered by `inputs`:
pkf:        conf/settings.ini
pkf:      editing one of these will NOT invalidate the cache.

pkf: NOTE 1 declared input pattern(s) matched nothing read:
pkf:        docs/**/*.md
pkf:      these cost cache hits without protecting correctness.
```

Reads are filtered to files that exist under the workspace: the
toolchain, `/etc`, shared objects, the pkfire cache and `.git` are
dropped, as are directory opens (a `readdir` is not a content input) and
probes for files that do not exist. A path the task also wrote is
treated as an output, not an input — tasks routinely read back what they
just produced, and feeding that into `inputs` would make a task's key
depend on its own output.

## Why this is a command, not the keying path

vite-task uses the observed read set *as* the cache key. That is the
stronger design — there is no declaration to get wrong — but it changes
the contract in ways pkfire is not ready for:

- The first run of a task has no observed read set, so the key can only
  be computed *after* execution. Keying on it means a two-phase model:
  execute, record, then look up on the next run.
- A read set is per-machine. Toolchain paths, `$HOME`, and temp
  directories all show up; sharing entries through the remote cache
  needs a normalization pass that does not exist yet.
- Anything invisible to the shim (static binaries, `openat` under a
  directory fd) becomes a *correctness* bug rather than a reporting gap.

So `trace` is an auditing tool today: it tells you what your `inputs`
should say, and `--check` keeps them honest in CI. Promoting the
observed set to the key belongs with the hermetic sandbox executor in
[issue #60][issue] — once an action's inputs are materialized into a
sandbox, the observed read set and the declared one can be reconciled by
construction rather than by report.

[article]: https://zenn.dev/herp_inc/articles/strange-task-runner
[issue]: https://github.com/mizchi/pkfire/issues/60
