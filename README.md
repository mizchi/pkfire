# pkfire

[![Test](https://github.com/mizchi/pkfire/actions/workflows/test.yml/badge.svg)](https://github.com/mizchi/pkfire/actions/workflows/test.yml)
[![Nix](https://github.com/mizchi/pkfire/actions/workflows/nix.yml/badge.svg)](https://github.com/mizchi/pkfire/actions/workflows/nix.yml)

> Typed task runner with Bazel-style incremental caching, configured in [Pkl](https://pkl-lang.org/).

The name `pkfire` comes from "Pkl task fire": define tasks in Pkl,
then fire them through the `pkf` CLI.

`pkfire` (CLI: `pkf`) replaces hand-written `justfile`s with a typed,
composable Pkl schema. Tasks declare their inputs, outputs, and
dependencies; `pkf` builds a DAG and executes only the steps whose
action key has changed. Cached outputs are restored from a
content-addressed store under `~/.cache/pkfire`.

## Why pkfire

pkfire competes with the same lightweight task runners you already
reach for — `make`, [`just`](https://github.com/casey/just), npm
scripts, `package.json` `"scripts"`, `Taskfile.yml`. They all work
fine for a handful of one-line shell commands. The pain shows up
once a project has:

- **Shared inputs** ("these 6 globs of `.go` files feed three
  different tasks") that you keep copy-pasting.
- **Matrix duplication** — four near-identical recipes for
  `linux-amd64`, `linux-arm64`, `darwin-amd64`, `darwin-arm64`.
- **Per-package overrides** in a monorepo where every package has a
  `build` and `test` step that differs only in path and toolchain.
- **No way to verify** the runner config itself — a typo in a task
  name only fails when you run that task, in CI, on a Friday.

These tools are string-based: every task is shell, every value is
text, every reference is by name. They have no notion of "this
identifier should resolve to a Task that already exists". So they
duplicate.

pkfire describes the same tasks in [Pkl](https://pkl-lang.org/),
which is a typed configuration language with template inheritance
(`amends`), per-module testing (`pkl test`), and ordinary functions.
A repeated task shape becomes a one-line `local function testTask(p)`
that the schema invokes for each package or platform — see
[`examples/monorepo/`](./examples/monorepo/Taskfile.pkl), where a
per-package test/build template replaces a wall of near-duplicate
`just` recipes. Renaming a task in one place updates every reference;
misspelling a dependency fails at evaluation time, before the runner
starts.

On top of the language layer, pkfire adds the parts a string-based
runner can't: a content-addressed cache keyed on inputs/cmd/env, an
HTTP remote cache so CI and teammates can share hits, and a watch
mode that reruns only the affected subgraph.

## Install

### Homebrew (Apple Silicon macOS)

This repository doubles as a custom Homebrew tap. Register its explicit URL
once, then install `pkf`; Homebrew also installs the required Pkl CLI:

```sh
brew tap mizchi/pkfire https://github.com/mizchi/pkfire
brew install mizchi/pkfire/pkf
```

Upgrade later with `brew update && brew upgrade pkf`. Intel macOS is not
supported because the MoonBit toolchain does not provide an x86_64 macOS
binary.

### Install script

`pkf` is a self-contained MoonBit binary. The installer detects your
platform, downloads the matching release tarball, verifies its
checksum, and drops `pkf` into `~/.local/bin`:

```sh
curl -fsSL https://raw.githubusercontent.com/mizchi/pkfire/main/install.sh | sh
```

Customize with env vars or flags:

```sh
# pin a version and choose the install dir
curl -fsSL https://raw.githubusercontent.com/mizchi/pkfire/main/install.sh \
  | sh -s -- --version 0.12.0 --dir /usr/local/bin
# env-var form: PKF_VERSION, PKF_INSTALL_DIR, PKF_NO_VERIFY
```

### Manual download

Or grab the tarball for your platform from the
[latest release](https://github.com/mizchi/pkfire/releases/latest):

```sh
# pick your target: linux-amd64 | linux-arm64 | darwin-arm64
target=linux-amd64
curl -fsSL -O "https://github.com/mizchi/pkfire/releases/latest/download/pkf-${target}.tar.gz"
tar -xzf "pkf-${target}.tar.gz"
install -m 0755 pkf /usr/local/bin/pkf
```

Intel macOS (`darwin-amd64`) and Windows are not supported. You also
need the Pkl CLI (`pkl`) on `PATH`; install it from
[pkl-lang.org](https://pkl-lang.org/main/current/pkl-cli/) or via your
package manager. (The GitHub Action and the Nix package below bundle
`pkl` for you.)

### GitHub Actions

A setup-only composite action lives at the repo root:

```yaml
# .github/workflows/ci.yml
jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: mizchi/pkfire@v0.16.0       # or @v0 to track the latest 0.x
      - run: pkf run ci
```

The action downloads the matching `pkf` binary and the Pkl CLI for
the runner (`linux-amd64`, `linux-arm64`, `darwin-arm64`) and adds them
to `PATH`. Intel macOS (`darwin-amd64`) is not supported. After it runs,
the rest of the workflow calls `pkf` directly — no `go install`, no Pkl
bootstrap.

> **Why `@v0.5.0` and not `@pkfire@0.16.0`?** GitHub Actions cannot
> parse `uses: <repo>@<ref>` when the ref itself contains `@` — the
> whole workflow file fails to load with a generic
> "workflow file issue" error and zero jobs run. Pkl release tags
> are `pkfire@<ver>` for the package URI, so the Release workflow
> additionally publishes `v<ver>` and a floating `v<major>` tag at
> the same commit. Use those from `uses:`. For maximum supply-chain
> safety, pin to the commit SHA directly:
> `uses: mizchi/pkfire@<40-char-sha> # v0.5.0`.

Pin the action ref to a release tag so the action code, the `pkf`
binary, and the Pkl schema all move together. To share cache hits
across CI runs and developers, wire the remote cache env:

```yaml
      - uses: mizchi/pkfire@v0.16.0
      - run: pkf run ci
        env:
          PKFIRE_REMOTE_CACHE: ${{ vars.PKFIRE_REMOTE_CACHE }}
          PKFIRE_REMOTE_TOKEN: ${{ secrets.PKFIRE_REMOTE_TOKEN }}
```

Inputs:

| Input | Default | Notes |
| --- | --- | --- |
| `version` | the action ref, falling back to the latest release | Accepts `v0.5.0`, `0.4.0`, `v0` (floating major), or the underlying `pkfire@0.16.0`. Pinning via `uses: mizchi/pkfire@v0.16.0` is the recommended form. |
| `pkl-version` | `0.32.1` | Set to `none` to skip the Pkl install when only `pkf` is needed. |
| `install-dir` | `${{ runner.temp }}/pkfire-bin` | Both binaries are placed here; the dir is appended to `GITHUB_PATH`. |
| `cache-pkl` | `false` | Set to `true` to cache `~/.pkl/cache` between runs. Useful for projects that consume remote Pkl packages (`amends` / `import` of `package://pkg.pkl-lang.org/...`). |
| `pkl-cache-key` | `pkl-<hashFiles>` of `PklProject.deps.json` + `Taskfile.pkl` | Override only if the default key collides across unrelated jobs in the same repo. |

### Nix (no toolchain required)

```sh
nix run github:mizchi/pkfire -- run hello       # one-shot
nix profile install github:mizchi/pkfire        # persistent
```

The flake installs the prebuilt `pkf` release binary (patched for the
Nix closure on Linux) and wraps it so the bundled Pkl CLI is on `PATH`
automatically — end users install neither a MoonBit toolchain nor Pkl
themselves. The Nix workflow on every push to `main` and on every PR
verifies the flake builds cleanly on `aarch64-darwin` and `x86_64-linux`
runners; the badge above tracks its status.

`nix develop` opens a shell with the MoonBit toolchain (`moon`) and
`pkl` for working on pkfire itself.

## Quick start

```sh
mkdir my-project && cd my-project
pkf init                # writes a starter Taskfile.pkl
pkf run hello           # smoke the generated task
```

`pkf init` writes a Taskfile that `amends` the schema over HTTPS, so
your project does not need a clone of this repo.

## Authoring a Taskfile

```pkl
amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.16.0#/Taskfile.pkl"

local build = new Task {
  name = "build"
  cmd = "moon build --target native --release"
  inputs { "src/**/*.mbt"; "src/**/moon.pkg"; "moon.mod" }
  outputs { "_build/native/release/build/main/main.exe" }
}

local test = new Task {
  name = "test"
  cmd = "moon test"
  inputs { "src/**/*.mbt"; "src/**/moon.pkg"; "moon.mod" }
  deps { build }            // direct Task reference, typo-checked by Pkl
}

tasks { build; test }
```

Each task is a `Task` instance with a unique `name`. Dependencies are
*Task references* (`deps { build }`), not strings — referencing an
undefined task fails at Pkl evaluation time with a name-resolution
error, before the runner ever starts. Renaming a task in one place
updates every reference automatically.

Tasks that only aggregate dependencies can omit `cmd`:

```pkl
local ci = new Task {
  name = "ci"
  deps { build; test }
}
```

`cmd` runs as `<shell> <shellFlags...> <cmd>`. The default is
`shell = "bash"` and `shellFlags = List("-c")`; override
`shellFlags` for strict mode or non-`-c` runtimes:

```pkl
local strict = new Task {
  name = "strict"
  shellFlags = List("-eu", "-o", "pipefail", "-c")
  cmd = "pkl format --check ."
}

local nodeSnippet = new Task {
  name = "node-snippet"
  shell = "node"
  shellFlags = List("-e")
  cmd = "console.log(process.argv.slice(2))"
}
```

For wrapper tasks whose stdout/stderr is the product, set
`quiet = true` to suppress pkfire's per-task diagnostic lines without
hiding the command's own output.

When `-f` is not supplied, `pkf` walks up from the current directory
to find the nearest `Taskfile.pkl` (the same discovery rule git uses
for `.git/`), so any of these works the same:

```sh
cd services/api/internal && pkf run ci    # uses services/api/Taskfile.pkl
cd /repo/root && pkf run ci               # uses /repo/root/Taskfile.pkl
```

```sh
pkf list                       # show public tasks
pkf list --all                 # include internal tasks
pkf list -v                    # add cmd preview and deps
pkf list --json                # machine-readable (for editor / CI tooling)
pkf test                       # shorthand: `run` is optional for a task name
pkf run test                   # builds first, then tests; second run hits cache
pkf run --dry-run test         # preview: per-task hit/will-run/uncached status + cmd
pkf run --print-hash test      # print action keys, do not execute
pkf run --explain-cache test   # explain cache hit/miss/forced-run decisions
pkf run --no-cache test        # bypass cache lookup AND store for this run
pkf run --refresh test         # bypass cache lookup but DO re-store (re-baseline)
pkf up dev                     # start every service:true task in dev's subgraph
pkf graph                      # dependency tree, one root per line
pkf graph --format dot         # Graphviz DOT (pipe to `dot -Tsvg`)
pkf graph --format mermaid     # Mermaid flowchart (renders on GitHub)
pkf graph --json               # machine-readable graph (tasks + edges)
pkf graph --target test        # only `test` and what it depends on
pkf graph --target test --depth=1  # one hop: direct dependencies only
pkf doctor                     # diagnose pkf PATH, pkl/cache/remote/taskfile setup
pkf doctor --json              # emit structured setup checks
pkf format                     # pkl format -w on the Taskfile's directory
pkf format --check pkl examples # exit non-zero (CI-friendly) if anything is unformatted
pkf hooks install              # write .git/hooks/<event> shims for matching tasks
pkf hooks list                 # show which hook events are wired
pkf affected src/main.go       # list tasks affected by the given changed paths
pkf affected --changed=changed.txt     # read newline-separated changed paths from a file
pkf affected --check           # run workflowTests declared in Taskfile.pkl
pkf run a b c                  # run multiple targets in one go (topological union)
pkf run                        # no args = the `default` task (errors if absent)
pkf run -- a b c               # forward args to the `default` task when it accepts args
pkf run --timing build         # also print per-task wall time at the end
pkf run --execution-log=run.jsonl build  # write a machine-readable record of the run
pkf run --config mode=release build      # build setting for the run, propagates to deps
pkf run 'test:*'               # glob over task names (also works on affected / clean)
pkf clean                      # rm declared outputs of every task
pkf clean --dry-run            # list what would be removed, remove nothing
pkf cache stats                # entries, blobs, size, how much sharing saved
pkf cache prune --older-than=7d  # drop stale entries (--dry-run to preview)
pkf cache rm <action-key>      # remove a specific entry (≥2-char prefix accepted)
pkf cache clear --yes          # nuke everything (scripting-safe with --yes)
pkf cache vacuum               # hold the cache under its size ceiling, LRU-first (runs daily on its own)
pkf run --quiet build          # suppress per-task log lines (errors + summary still print)
pkf completion bash > ~/.bash_completion.d/pkf  # dynamic task-name completion
pkf completion zsh > "${fpath[1]}/_pkf"
pkf completion fish > ~/.config/fish/completions/pkf.fish
pkf run --keep-going lint test # don't stop on first failure (Bazel / make -k)
pkf run -j 4 ci                # run up to 4 actions at once, respecting the graph
pkf run -j auto ci             # one per available CPU (capped at 16)
pkf run --sandbox test         # run against only the declared inputs
pkf explain build              # dump every input to the action key (cache-miss debug)
pkf run --profile=ci build     # tag the run; $PKF_PROFILE + cache splits per profile
pkf run --remote-only build    # skip local cache, only consult remote (verify remote populated)
pkf trace build                # list the workspace files the task actually read
pkf trace --check build        # fail when a file is read but no declared input covers it
pkf trace --emit build         # print an `inputs { ... }` block matching the observed reads
pkf lint                       # detect dead local tasks, cache footguns, and suspicious task definitions
pkf lint --json                # emit machine-readable findings for CI/editor tooling
pkf migrate --to=0.5.0         # rewrite Taskfile.pkl's amends URI + verify
pkf pkl-cache warm             # pre-populate ~/.pkl/cache (CI prefetch step)
pkf <plugin> <args>            # exec `pkf-<plugin>` on PATH (git-style fallthrough)
```

`pkf lint` also solves intersections between input globs, declared output
globs, and a repository-local `PKFIRE_MBT_CACHE_DIR`. It reports a concrete
witness path for self-loops and cross-task cycles. `pkf watch` runs the same
check before starting and refuses configurations that can repeatedly trigger
themselves. For example, `inputs { "**/*" }` must not overlap `outputs`, and a
custom cache directory should normally live outside the repository or under
the built-in excluded `.cache/` directory.

Inside `cmd`, three env vars are always injected so tasks can
reference their own context without hardcoding paths:

- `PKF_TASK_NAME` — the task's `name`.
- `PKF_TASK_ROOT` — absolute path to the task's `workdir` (or the
  Taskfile directory when `workdir` is null).
- `PKF_WORKSPACE_ROOT` — absolute path to the Taskfile's directory.

These are NOT part of the action key — they're constants of the
task definition, already implicit in the hash via cmd / env / inputs.

For cache debugging, `pkf run --explain-cache <task>` prints each task's
action key, cache decision, declared outputs, matched input file count,
and input patterns that matched no files. Use `pkf explain <task>` when
you need the full component-by-component action-key dump.

`pkf graph` prints a dependency tree; `--format dot` and
`--format mermaid` draw it, and `--json` emits `{tasks, edges}` for
tooling:

```sh
pkf graph                                  # tree (default)
pkf graph --format dot | dot -Tsvg -o tasks.svg
pkf graph --format mermaid > tasks.mmd     # paste into a PR
pkf graph --json | jq '.edges'
```

`--target TASK` narrows the drawing to one task and what it depends on,
and `--depth N` stops after N hops — `--depth=1` is "what does this
directly need?".

The drawn formats show **both** kinds of edge the runner honours:
declared `deps` as a solid arrow, and the ones
[derived from artifacts](#artifacts-the-files-are-the-edges) as a
dashed one labelled with the output pattern that links them. A picture
of half the ordering constraints would be worse than none — you would
use it to reason about a build whose real shape is different.

```mermaid
flowchart LR
  gen["gen"]
  consume["consume"]
  gen -. "dist/out.txt" .-> consume
```

`--json` deliberately stays as it was: it is a machine contract, and
adding a field to it to serve a human-readable concern would break
every consumer.

### Machine-readable introspection

Use `pkf list --json` when tooling needs the task inventory, and
`pkf graph --json` when it also needs dependency edges. Both commands
respect visibility by default; pass `--all` to include internal tasks.

`pkf list --json` emits:

```json
{
  "tasks": [
    {
      "name": "build",
      "description": "Compile the app",
      "visibility": "public",
      "cmd": "moon build --target native --release",
      "deps": [],
      "inputs": ["src/**/*.mbt", "src/**/moon.pkg", "moon.mod"],
      "outputs": ["_build/native/release/build/main/main.exe"],
      "cache": true,
      "workdir": "services/api",
      "service": false,
      "services": [],
      "acceptsArgs": false,
      "inheritEnv": true
    }
  ]
}
```

`pkf graph --json` emits the same task metadata, plus `kind` and
`edges`:

```json
{
  "tasks": [
    { "name": "build", "kind": "task", "deps": [], "cache": true },
    { "name": "ci", "kind": "aggregate", "deps": ["build"], "cache": true }
  ],
  "edges": [
    { "from": "build", "to": "ci" }
  ]
}
```

Task `kind` is one of `task`, `aggregate`, `service`, or `noop`.
Graph `edges` point from dependency to dependent.

### Testing affected workflows

When you first write `inputs`, `outputs`, and `deps`, pin the expected
file-change workflow next to the tasks:

```pkl
local build = new Task {
  name = "build"
  cmd = "moon build --target native --release"
  inputs { "src/**/*.mbt"; "moon.mod" }
  outputs { "_build/native/release/build/main/main.exe" }
}

local test = new Task {
  name = "test"
  cmd = "moon test"
  inputs { "src/**/*.mbt" }
  deps { build }
}

tasks { build; test }

workflowTests {
  new {
    name = "source edit rebuilds and retests"
    changed { "src/main.mbt" }
    direct { "build" }
    tasks { "build"; "test" }
  }
}
```

`pkf affected --check` runs those cases without executing task
commands. For ad-hoc debugging, use
`pkf affected --files src/main.go --explain --dry-run` to see which
input pattern matched and which tasks would be in the run plan. The
reverse view is `pkf explain test`: it now prints declared deps,
dependents, input patterns, outputs, and the upstream input patterns
that can make the task affected.

## Environment, args, and the action key

This section is the part that *trips up automated agents* — the rules
look obvious once stated but they look the wrong way around if you
guess. Read once, refer back as needed.

### Layer order (later wins)

Every `cmd` runs against an env merged from four layers:

```
1. host env (os.Environ())             ← inherited from the shell that ran pkf
2. defaults.Env                        ← Taskfile-wide common values
3. task.Env                            ← per-task overrides
4. resolved params (uppercased name)   ← `--bump=patch` → $BUMP
```

Plus, when `acceptsArgs = true`, anything after `--` on the command
line is forwarded as `$1`, `$2`, ..., `"$@"`.

### A task with no `inputs` is never cached

`cache` defaults to `true`, but a task that declares no `inputs` is run
every time regardless. Its action key depends only on the command and
its environment, so nothing you edit can change it: the first run would
store an entry and every run after it would be a permanent hit. `pkf run
--dry-run` says so explicitly:

```
pkf: pre-push  will run (uncached: no declared inputs)  bb57cea3
```

Declaring `inputs` is what opts a task into caching. A task with
`inputs` and no `outputs` — a type-check or a linter — still caches
usefully: the hit means "these exact sources already passed".

### The action descriptor

The action key is a SHA-256 over a canonical serialization of the
*action descriptor* — the complete description of the process a task
spawns. Every value that reaches the command, and every value that
decides what the command is expected to leave behind, is a field of the
descriptor, so nothing can be visible to `cmd` and invisible to the key
by accident:

```
mnemonic  executable  argv  env  inheritEnv
inputs (path + digest)  consumedArtifacts (path + digest)
outputs  workingDirectory
executionPlatform  executionProperties
```

`pkf run --explain-cache <task>` prints it; that dump is the answer to
"why did this miss?", because a miss is always one of those lines
differing from last time.

### Evaluation is cached too

The action cache makes the *tasks* free; evaluating the Taskfile was
still paid on every invocation — about 85% of the work of a warm run.
That is memoized now:

```
pkf list                    182 ms  ->    4 ms
pkf run fmt:check (cached)  190 ms  ->    7 ms
```

An evaluation is a pure function of the modules it read, and the Pkl
loader already walks `amends` / `extends` / `import` — glob imports
included — so it knows that set exactly. The entry records every module
with its digest and re-validates all of them on lookup: edit the
Taskfile, edit anything it imports, add or remove a file matching an
`import*` glob, and the next run re-evaluates. Anything unexpected — an
unreadable module, an entry from an older format — is a miss rather
than a guess, because a stale plan would run yesterday's commands and
report success.

`PKFIRE_MBT_NO_EVAL_CACHE=1` turns it off.

### `run` is optional

`pkf build` means `pkf run build`. Flags, params and positionals behave
exactly as if you had spelled `run` out, because it is the same code
path:

```sh
pkf build --mode=prod          # params
pkf greet -- world             # positionals
pkf 'test:*'                   # globs
pkf build --no-cache           # runner flags
```

**A built-in subcommand always wins.** A Taskfile that declares a task
called `list` does not change what `pkf list` does — a command whose
meaning depends on the repository you happen to be in is a command
nobody can learn. The shadowed task stays reachable as `pkf run list`,
and `pkf lint` reports the collision as `shadowed-by-builtin` so it is
not a surprise you find by typing it.

The shorthand only fires when the name is a real task, so a typo still
says so — and, since it cannot know which half you meant, it offers
whichever near misses exist on either side:

```
$ pkf helo
pkf: unknown subcommand or task `helo`
  did you mean the subcommand: help
  did you mean the task: hello
```

### What a run tells you it skipped

Every run ends with one line saying how much of it was actually redone:

```
$ pkf run ci
pkf: $ build
pkf: $ test
pkf: 3 task(s) · 1 cached · 2 ran · 4.1s

$ pkf run ci                       # nothing changed
pkf: # build (cache hit 5a1b2c3d, replaying logs)
bundle: 412 kB
pkf: # test (cache hit 9e0f1a2b, replaying logs)
ok  47 passed
pkf: 3 task(s) · 3 cached · 0 ran · 12ms  (nothing to rebuild)
```

The per-task `# name (cache hit …)` lines were always there, but in a
fifty-task build they scroll past, and the question left afterwards is
the one the summary answers. A remote hit is counted separately
(`2 cached (1 remote)`) because "my cache works" and "CI's cache works"
are different facts. Tasks skipped after a failure are counted too, so
a run that stopped early cannot look like a run that finished.

Deps-only umbrella tasks are not counted: they spawn nothing, and
calling them "ran" would overstate the build. `--quiet` suppresses the
line along with the per-task ones, and `--dry-run` / `--print-hash`
omit it because nothing was executed to summarise.

### Replayed logs

A cache hit prints what the run that filled the entry printed. The
stdout and stderr of a cached task are stored inside the entry
alongside its outputs, so a hit reproduces the transcript instead of
swallowing it — a build's output should not depend on whether the cache
happened to be warm, or a green CI log becomes unreadable the moment
caching starts working.

Remote hits replay too: the entry carries the logs, so a task first run
on someone else's machine still prints its test summary on yours.

Three details:

- A task that printed nothing says nothing extra — the hit line stays
  `# name (cache hit 5a1b2c3d)` rather than claiming a replay of an
  empty log.
- Each stream is capped at 1 MiB in the entry, with a line saying how
  much was dropped. Entries are downloaded whole on a remote hit, and
  an uncapped `-v` build would make that expensive for output nobody
  reads.
- Capturing means the command writes to a pipe rather than to the
  terminal, so tools that colour conditionally will turn colour off.
  This applies only to tasks that are actually cached; anything
  uncacheable — `cache = false`, no declared `inputs`, `--no-cache` —
  still gets the terminal directly. Output is not delayed either way:
  sequentially it is forwarded as it arrives.

`.pkf-meta/` is reserved inside a cache entry for this. A task that
declares an output under that prefix is rejected rather than silently
mis-cached.

### Running actions in parallel

`pkf run -j N` runs up to `N` actions at once; `-j auto` uses one per
available CPU, capped at 16. Sequential is still the default, because
raising it changes when a Taskfile's side effects happen relative to
each other and that is the author's call, not the runner's.

The graph decides what may overlap. An action starts only once
everything it depends on has finished — declared `deps` and derived
artifact edges alike — so `-j` cannot reorder a build into
incorrectness; it can only stop independent branches from waiting on
each other.

Two behaviours change with `N > 1`:

- **Output is buffered per action.** Sequentially the command writes
  straight to your terminal, which is what makes a long build
  watchable. With several commands running at once those bytes would
  arrive shuffled, so each action's output is captured and printed as
  one block when it finishes — attributable, at the cost of arriving
  late.
- **Ties break on the topological order.** When several actions are
  ready, the one earliest in that order goes first. `-j 1` is therefore
  identical to the old sequential walk, and any `-j` schedules the same
  way twice in a row.

A failure stops *scheduling*; it does not kill what is already running,
because cancelling a compiler mid-write leaves a half-written output
that a later run would treat as real. `--keep-going` keeps launching,
but only actions whose dependencies all succeeded — anything downstream
of a failure is reported as skipped:

```
pkf: task `build` failed with exit code 1
pkf: - test (skipped: `build` failed)
pkf: - ci (skipped: `build` failed)
```

`--timing` reports the critical path, which is the number that decides
how long a parallel run takes — shortening anything off that chain
changes nothing:

```
pkf:   total  1.0s wall
pkf:   critical path  1.0s  compile -> link -> package
```

Two caveats. A task that expects a terminal (progress bars, colour
detection) sees a pipe under `-j`. And two tasks that each declare the
same `services { … }` will each start it; services are not deduplicated
across concurrent actions yet.

### A record of the run, for something other than a human

`--timing` prints, and printing is where the record ends: the numbers
scroll past and nothing else can read them. The questions that outlast
one terminal — is CI's cache actually hitting, which action has been
getting slower, what did last night's build redo — are asked by tooling,
over many runs.

`--execution-log=FILE` writes one JSON object per line: an `action` line
per action in completion order, then a `summary` line.

```console
$ pkf run --execution-log=run.jsonl pack
$ cat run.jsonl
{"kind":"action","task":"gen","status":"ran","exitCode":0,"startMs":0,"durationMs":5}
{"kind":"action","task":"pack","status":"ran","exitCode":0,"startMs":5,"durationMs":5}
{"kind":"summary","version":1,"exitCode":0,"wallMs":10,"actions":2,"ran":2,"cached":0,"skipped":0,"criticalPathMs":10,"criticalPath":["gen","pack"]}
```

`status` is one of `ran`, `cached-local`, `cached-remote`, `umbrella`,
`reported` (under `--dry-run` / `--print-hash`) or `skipped`. A local
hit and a remote fetch are separate values because they cost very
different amounts of time. Only `ran` carries an `exitCode` — a cache
hit has none rather than a zero, so a consumer filtering on "exited
zero" does not pick up work that never happened — and only `skipped`
carries `blockedBy`, naming the action that stopped it.

The summary carries `criticalPath` because it cannot be recovered from
the action lines: the log records no edges, and under `-j 1` everything
runs back to back whether or not the graph required it.

JSON Lines rather than one document, for two reasons: `jq`, `grep` and a
spreadsheet import all take a line at a time without ceremony, and a run
that dies partway still leaves every completed line valid — which is the
run whose log you most want to read. An unwritable path is reported on
stderr but never changes the exit code; a log that failed to write is
not a reason to fail a build that succeeded.

### Running an action against only what it declared

`inputs` has always been a promise about what a command reads, and
nothing checked it. A task that reads a file it never declared runs
fine and caches fine — and then serves a stale hit the day that file
changes, so the failure shows up as a wrong build, far from the
undeclared read that caused it.

`pkf run --sandbox` makes the promise structural. Before the command
runs, pkfire builds a tree containing exactly the declared inputs and
the outputs of the actions this one depends on, and runs the command
there:

```
$ pkf run sneaky              # reads a file it never declared
pkf: $ sneaky
$ pkf run --sandbox sneaky
cat: undeclared/extra.txt: No such file or directory
pkf: task `sneaky` failed with exit code 1
```

Declared outputs are collected back into the workspace afterwards.
Anything else the command wrote stays in the sandbox and is reported,
because an undeclared output is usually a missing `outputs` line:

```
pkf: task `messy` wrote `dist/scratch.log` without declaring it as an
     output (discarded; add it to `outputs` to keep it)
```

A failed action produces nothing at all: a command that died half-way
has written half an output, and the sandbox is what lets that stay out
of the tree.

This is Bazel's symlink forest and deliberately not its namespace
sandbox. Inputs are symlinked, so materializing a large input set costs
almost nothing — and **absolute paths still resolve**. `/usr/bin/cc`,
`$HOME/.cargo`, the toolchain generally, are all still reachable. That
is a real limit: hermetic *toolchains* are a separate problem, and a
sandbox that hid `/usr/bin` would make every task fail for a reason
that has nothing to do with its `inputs`. What this catches is the
mistake people actually make, which is reading a workspace file you
forgot to declare.

A task can opt in permanently with `hermetic = true`, which is the
checked-in form of the flag:

```pkl
local check = new Task {
  name = "check"
  cmd = "cargo clippy -- -D warnings"
  inputs { "src/**"; "Cargo.toml"; "Cargo.lock" }
  hermetic = true
}
```

`hermetic = true` also seals the environment — the ambient host
variables are dropped, whatever `inheritEnv` says — because a task told
to depend on nothing it did not declare should not be reading a
`$SOME_VAR` the action key cannot see either. That is not silent:
`pkf run --explain-cache` prints the descriptor with `inheritEnv:
false`, which is what the key hashes. `hermetic` is part of the key
too, so a hermetic and a non-hermetic run of the same task never share
a cache entry.

Tasks with no declared `inputs` run unsandboxed — there is nothing to
constrain — as does a task whose root shares no ancestor with the repo,
which cannot be mirrored; both say so rather than pretending.
[`pkf trace`](./docs/auto-inputs.md) is the complement: the sandbox
tells you that you forgot something, `trace --emit` tells you what to
write down.

### Artifacts: the files are the edges

A declared `outputs` pattern makes its task the *producer* of those
paths. A task whose `inputs` reach into that region is a *consumer*,
and pkfire derives the edge between them rather than making you write
it twice:

```pkl
local build = new Task {
  name = "build"
  cmd = "esbuild src/app.ts --outfile=dist/app.js"
  inputs { "src/**" }
  outputs { "dist/app.js" }
}

local size = new Task {
  name = "size"
  cmd = "wc -c dist/app.js"
  inputs { "dist/app.js" }   // no `deps { build }` needed for ordering
}
```

Two things follow, and both are about the cache being right rather
than about typing less:

- **Order.** In any run containing both, `build` is scheduled before
  `size`. `pkf run size build` runs them in that order regardless of
  how you listed them.
- **Key soundness.** The outputs of everything a task depends on are
  hashed into its action key as `consumedArtifacts`. Before this, a
  task that declared `deps { build }` but no matching `inputs` line had
  a key that could not see a single byte `build` wrote — so it stayed a
  cache hit while the thing it consumed changed underneath it.

`pkf explain <task>` reports both halves: input patterns are annotated
with the task that produces them, and an `artifacts:` line counts the
files hashed in from dependencies.

Inference orders and keys the tasks in a run; it does not change which
tasks a run contains. `pkf run size` on its own still runs only `size`,
because pulling in a producer would execute a command you did not ask
for — `deps` remains how a Taskfile says "build this first". `pkf lint`
reports the gap as `undeclared-artifact-dep` so you can write the
`deps` line down:

```
task "size" reads "dist/app.js", which task "build" declares as output
"dist/app.js" (e.g. dist/app.js), but does not depend on it
```

A task never consumes its own outputs: a formatter that reads and
rewrites `src/**` is a fixpoint, not a cycle. A genuine cycle — two
tasks each reading what the other writes — is reported before anything
runs, naming the patterns and a path that matches both.

### Timeouts

A command that hangs blocks the run until something outside kills it,
and what that something reports is a job timeout rather than the task
responsible:

```pkl
timeoutSeconds = 300
```

The kill is the whole process tree, and the shell is signalled **before**
the children it started. That ordering is the feature: a shell whose
child dies first notices, concludes the command finished, and runs the
next line of a script that was supposed to have been stopped —
`sleep 60 && echo after` printed `after`. SIGTERM, then SIGKILL after a
five-second grace, the same sequence that stops a service. The task
fails with exit 143, so a log reading only the number still says
"terminated".

Raising a timeout does not invalidate the cache: it changes nothing
about what the command produces.

### Retries

For the test suite that fails one run in fifty on a race nobody has
time to find this week:

```pkl
retries = 2
```

Without it the choice is a red build on a green tree or `|| true` in the
`cmd`, and `|| true` never comes back out — it hides the day the test
starts failing every time. A retry keeps the failure visible instead:

```
pkf: $ test
pkf: task `test` failed with exit code 1; retrying (attempt 2 of 3)
pkf: $ test
```

Every attempt is printed, and the count lands in `--execution-log` as
`attempts` on the action and `retried` on the summary — so "this task
retries constantly" is a number someone can act on rather than a feeling.

Only a genuinely non-deterministic task should set this. A retry cannot
fix a missing `inputs` line — the second attempt reads the same
undeclared file — and it costs the run the time of every attempt. A task
that fails every time still fails, with the command's own exit code.

Under `--sandbox` each attempt gets a fresh sandbox, so a retry never
reads what the attempt that failed left behind, and a half-written
output from a failed attempt never reaches the workspace. Services
started for the task stay up across attempts: a flaky test usually needs
its database still running.

Like `timeoutSeconds`, `retries` is not part of the action key. Only the
attempt that succeeded is stored, and what it produced does not depend
on how many came before it.

### Platform requirements

```pkl
requiresPlatform { "linux/amd64"; "linux/arm64" }
```

Checked before the command is spawned, so a task that cannot run here
says so by name instead of failing somewhere inside a script with
whatever the first platform-specific tool in it happens to print:

```
pkf: task `build:deb` requires execution platform linux/amd64 or linux/arm64,
     but this machine is darwin/arm64
```

### Toolchains: resolved, not declared

`tools { ["go"] = "1.26.2" }` is a string you type and then have to
remember to change. Nothing checks it, so upgrading Go leaves the
action key where it was and every entry the old compiler built stays a
hit. A `Toolchain` is the same declaration made checkable:

```pkl
local build = new Task {
  name = "build"
  cmd = "go build ./..."
  inputs { "**/*.go"; "go.mod" }
  outputs { "bin/app" }
  toolchains {
    new Toolchain { name = "go" }
    new Toolchain { name = "protoc"; versionCmd = "protoc --version" }
  }
}
```

pkfire finds the executable on `PATH`, asks it its version, and keys on
what it observed. Upgrade the compiler and the key moves with nothing
edited.

`hashBinary = true` hashes the executable's bytes too. That is the
sound option — a version string can lie, and two builds of `go1.26.2`
are not necessarily the same compiler — but it costs a read of the
whole executable per run, so it is opt-in rather than the default.

The **resolved path stays out of the key**. `/opt/homebrew/bin/go` and
`/usr/bin/go` are the same toolchain as far as a build is concerned,
and hashing the path would split the cache between two machines that
should share it — which is the whole reason a remote cache exists.
`pkf explain` reports it, because that is where someone asking "why is
my key different from CI's" will look:

```
toolchains (1):
  go  go version go1.26.2 darwin/arm64
    /opt/homebrew/bin/go
```

A declared toolchain that is missing is fatal at key time, so the
message names the task and the tool rather than surfacing as a shell's
`command not found` on whichever line happened to use it.
`optional = true` records the absence in the key instead, so a run that
went ahead without the tool cannot share an entry with one that had it.

Resolution is memoized per process: thirty tasks naming one compiler
interrogate it once.

### Cross-compiling: what a task builds *for*

The execution platform — the machine running the action — is always in
the key. `targetPlatform` is the other half:

```pkl
targetPlatform = "linux/arm64"
```

Two cross-compiles that issue the same command on the same machine and
differ only in where the result is meant to run are different actions,
and key differently. Null, the default, means the task builds for the
machine it runs on.

**It propagates down the graph.** A dependency of a cross build is part
of that cross build:

```pkl
local lib = new Task { name = "lib"; /* no targetPlatform */ }
local app = new Task { name = "app"; targetPlatform = "linux/arm64"; deps { lib } }
```

`pkf run lib` builds `lib` for the machine it runs on. `pkf run app`
builds it for `linux/arm64` — same task, different action key, and its
`toolchains` resolve to the cross compiler too. Without this a cross
build's dependencies were resolved and keyed for the host, so two
different cross builds shared one entry for a library that should have
been built twice.

Only a declared `targetPlatform` propagates. A task that declares none
passes no opinion down, so a `ci` umbrella over a host task and a cross
task does not force the host platform onto everything beneath it.

A task that declares its own platform is never transitioned by whoever
depends on it — which is exactly what a code generator that has to run
on the build machine needs:

```pkl
local codegen = new Task { name = "codegen"; targetPlatform = "linux/amd64" }
```

**One task cannot be built for two targets in the same run yet.** It has
one set of `outputs`, so both configurations would write the same paths.
That is refused by name rather than silently built once and handed to
both:

```
pkf: task `lib` is needed for two target platforms in one run: linux/riscv64
  (via `other-app`) and linux/arm64 (via `app`).
  Both would write the same `outputs`, so pkfire cannot build it twice yet.
  Either run them separately, or give `lib` its own `targetPlatform`
  so it pins one configuration regardless of who depends on it.
```

Building it twice needs per-configuration output roots — Bazel's
`bazel-out/<config>/…` — which pkfire does not have. Until it does, the
refusal is the honest answer.

### Build settings: how a subtree is built

`targetPlatform` says *where* a subtree's output is meant to run.
`config` is the same mechanism for everything else:

```pkl
local app = new Task {
  name = "app"
  config { ["mode"] = "release" }
  deps { lib }
}
```

`lib` is now built in release mode too — without saying so, and without
being duplicated once per mode. Each setting reaches the command as
`$PKF_CONFIG_<KEY>` uppercased, so a script can act on it:

```sh
cc $([ "$PKF_CONFIG_MODE" = release ] && echo -O2) -o out src.c
```

Settings **merge per key** rather than replacing wholesale. A host tool
that must always build unoptimized pins the one setting it cares about
and inherits the rest:

```pkl
local codegen = new Task {
  name = "codegen"
  config { ["mode"] = "debug" }   // keeps app's `lto`, overrides `mode`
}
```

`pkf run --config KEY=VALUE` seeds the run — repeatable, and a task's own
declaration still wins for its subtree, so pinning cannot be overridden
from the outside.

Settings are part of the action key, because the command sees them. They
are not `env`, which is one task's environment and reaches nothing else,
and not `params`, which are per-invocation flags rather than a property
of a subtree. Two different values for one setting on one task in the
same run are refused exactly as two platforms are, and the message names
the setting that differs rather than the whole configuration:

```
pkf: task `lib` is needed for two build configurations in one run: …
  Differs on: mode: debug vs release
```

It also *selects the toolchain*, which is what makes `toolchains` a
resolver rather than a lookup. One declaration:

```pkl
local ccTool = new Toolchain {
  name = "cc"
  forTarget {
    ["linux/arm64"] = "aarch64-linux-gnu-gcc"
    ["linux/amd64"] = "x86_64-linux-gnu-gcc"
  }
}
```

A task building for `linux/arm64` resolves `cc` to the cross compiler
and asks *that* binary its version. `pkf explain` names both halves,
because "the Taskfile says `cc`, so which compiler was that?" is the
question a cross-compile makes you ask:

```
toolchains (1):
  cc -> aarch64-linux-gnu-gcc  aarch64-linux-gnu-gcc 13.2
    /usr/bin/aarch64-linux-gnu-gcc
```

A target with no entry falls back to the declared name, so a native
build needs no special case and its key is unchanged by adding a
`forTarget` line for some other platform.

### Steps: one task, several cached actions

A task is one command and therefore one cache key. A pipeline written
as one `&&` chain re-runs all of it whenever any part has to. `steps`
splits that:

```pkl
local bundle = new Task {
  name = "bundle"
  steps {
    new Step {
      name = "codegen"
      cmd = "pnpm codegen"
      inputs { "schema/**" }
      outputs { "gen/**" }
    }
    new Step {
      name = "compile"
      cmd = "tsc -b"
      inputs { "src/**"; "gen/**" }
      outputs { "lib/**" }
    }
    new Step {
      name = "link"
      cmd = "esbuild lib/index.js --bundle --outfile=dist/app.js"
      inputs { "lib/**" }
      outputs { "dist/app.js" }
    }
  }
}
```

Each step has its own `inputs` and `outputs`, so each has its own
action key and its own cache entry. Edit `src/` and `codegen` is not
re-run:

```
$ pkf run bundle
pkf: # bundle/codegen (cache hit 3f2063a2, replaying logs)
pkf: $ bundle/compile
pkf: $ bundle/link
pkf: 3 task(s) · 1 cached · 2 ran · 14ms
```

Everything except `cmd`, `inputs` and `outputs` comes from the task —
`shell`, `env`, `workdir`, `tools`, `cache`, `hermetic`, `inheritEnv`,
`params` — so a pipeline is configured once and a step says only what
it runs and what it touches.

Steps run under `<task>/<step>`, which is what the output calls them
and what `pkf run bundle/link` accepts. They are `internal`, so
`pkf list` still shows one task and `pkf list --all` shows the
pipeline. Depending on `bundle` means depending on the whole of it.

Ordering is **declaration order**, not inference. Artifact inference
would order any two steps where one reads what the other writes, but a
step with no outputs — a migration, a lint, a check — would float free
of the sequence its author wrote down.

`steps` cannot be combined with `cmd` (a task is one or the other) or
with `services` (a service's lifetime spans one command, and which step
of a pipeline it should wrap has no answer worth guessing at).
Duplicate step names, and a step whose composed name collides with a
real task, are refused when the Taskfile loads.

### Providers: what a dependency hands over

`deps` has meant one thing: run that first. A `provides` block makes it
carry data as well.

```pkl
local cli = new Task {
  name = "cli"
  workdir = "crates/cli"
  cmd = "cargo build --release"
  inputs { "src/**"; "Cargo.toml" }
  outputs { "target/release/cli" }
  provides = new Providers {
    executable = "target/release/cli"
    env { ["CLI_CHANNEL"] = "stable" }
  }
}

local smoke = new Task {
  name = "smoke"
  workdir = "apps/web"
  cmd = "\"$PKF_CLI_EXECUTABLE\" --version"
  deps { cli }
}
```

`smoke` runs from `apps/web`, so the path it needs is not the one `cli`
declared — it is `../../crates/cli/target/release/cli`, the walk
between the two directories. That is the point: a provider is not a
string constant you could inline, it is a value resolved into the
consumer's own working directory. `env` providers are the other half,
for the things that are not files at all.

Everything a provider puts in front of the command goes into the action
key, which is the reason to route it through `provides` rather than
through the shell: a value the command can read and the key cannot see
is how a cache goes stale. Change `CLI_CHANNEL` and `smoke` misses —
`cli`, whose own key does not contain it, does not.

Three rules:

- **Direct dependents only.** A provider does not travel a second hop.
  A variable appearing in a task that never named the producer is a
  surprise, not a convenience; a task that wants to pass something
  along declares it itself.
- **The consumer wins a collision.** Provider values sit between the
  module `defaults.env` and the task's own `env`, so a task's local
  declaration is never overridden by something it merely depends on.
- **`executable` must be something the task produces.** A path no
  `outputs` pattern covers is refused when the Taskfile loads, because
  the failure would otherwise surface in the *dependent's* command and
  be reported against the wrong task.

`pkf explain <task>` lists them with their origin, which is the answer
to "where did `$PKF_CLI_EXECUTABLE` come from?":

```
providers (2):
  PKF_CLI_EXECUTABLE=../../crates/cli/target/cli  (executable from `cli`)
  CLI_CHANNEL=stable  (env from `cli`)
```

The file half of a provider needs no schema — `inputs { ...cli.outputs }`
is ordinary Pkl and has always worked, and the bytes behind an
`executable` are already hashed into the consumer's key as consumed
artifacts.

### Two contracts that are NOT the same

| | Visible to `cmd`? | Part of the action key? |
| --- | :---: | :---: |
| host env (when `inheritEnv = true`, the default) | ✓ | ✗ |
| host env (when `inheritEnv = false`, allowlist only: `PATH HOME LANG ...`) | partial | ✗ |
| the `inheritEnv` flag itself | — | ✓ |
| `defaults.Env` | ✓ | ✓ |
| `task.Env` | ✓ | ✓ |
| resolved `params` values (`$NAME`) | ✓ | ✓ (when `cache = true`) |
| tail args from `-- a b c` (`$@`) | ✓ | ✓ (when `cache = true`) |
| `task.Tools` | as env hints only | ✓ |
| `hermetic` | ✓ (it decides what the command can read) | ✓ |
| declared `outputs` | ✗ | ✓ |
| outputs of the tasks this one depends on | ✓ (they are on disk) | ✓ |
| `workdir` | ✓ (it is the cwd) | ✓ |
| execution platform (`<os>/<arch>`) | ✗ | ✓ |
| `--profile=NAME` (`$PKF_PROFILE`) | ✓ | ✓ |

The mismatch on the "host env" row is deliberate. `cmd` should be
able to use `SSH_AUTH_SOCK`, `GPG_AGENT_INFO`, your `LANG`, your
editor — without those silently busting cache the next time you
ssh-add a different key. Only schema-declared layers participate in
the action key.

### When to use what

- **You want `cmd` to see a host env var.** Default state. Do
  nothing — `inheritEnv = true` already passes everything through.
- **You want a host env var to *also* affect cache.** Read it into
  `task.Env` explicitly:
  ```pkl
  env { ["NODE_ENV"] = read("env:NODE_ENV") }
  ```
  Now `cmd` sees `$NODE_ENV`, AND a change to it invalidates the
  cache entry. The host env still flows through for everything
  else; this only promotes one value into the hashed layer.
- **You want hermetic builds** (release pipelines, reproducibility-
  sensitive CI). Set `inheritEnv = false` per task. `cmd` then sees
  only the tiny allowlist plus whatever you put in `env { ... }`,
  and the action key fully describes the env.
- **You want runtime input that changes per invocation** (a port, a
  bump kind, a watch flag). Declare `params { ... }`:
  ```pkl
  params {
    new { name = "bump"; type = "enum"; choices { "patch"; "minor"; "major" }; default = "patch" }
    new { name = "port"; type = "int";  default = "3000" }
    new { name = "watch"; type = "bool"; default = "false" }
  }
  ```
  Callers pass `pkf run task --bump=minor --port=8080 --watch`;
  `cmd` reads `$BUMP`, `$PORT`, `$WATCH`. Different values cache as
  different entries — usually what you want.
- **You want variadic positional args** (the `just *ARGS` shape).
  Set `acceptsArgs = true` and write `cmd = "node \"$@\""`. Callers
  pass `pkf run task -- a b c`. The args fold into the action key,
  so command wrappers typically also set `cache = false`.
- **You want helper tasks hidden from normal discovery.** Set
  `visibility = "internal"`. `pkf list` and `pkf graph` hide it by
  default, `--all` reveals it, and `pkf run <name>` can still execute
  it directly.

### Things that confuse agents

- **`read("env:X")` is NOT how you read host env at runtime.** It is
  Pkl-evaluation-time interpolation: the *value at the time pkf
  evaluated the Taskfile* gets baked into the rendered task. That
  is exactly what you want when you want the value to affect the
  action key, but if you only need `cmd` to see the var, plain
  inheritance is enough — don't write `read("env:...")` for
  ergonomics-only env like `SSH_AUTH_SOCK`.
- **`$VAR` inside `cmd` is shell expansion, not Pkl interpolation.**
  Write `cmd = "echo $HOME"` — pkfire passes the literal string to
  bash, bash expands `$HOME` from the merged env. Pkl's `\(...)`
  interpolation runs at schema evaluation time and bakes a
  constant into the rendered task — useful occasionally but rarely
  what you want for env vars.
- **`acceptsArgs = false` is the default for a reason.** A task
  that silently absorbs whatever comes after its name is a typo
  vector. Opt in only for command wrappers (`script`, `test
  --grep=...`, etc.).
- **`bool` params do not consume the next token.** `--watch
  --port=80` parses as `WATCH=true PORT=80`. Use `--watch=false`
  for explicit negation. (`int`, `string`, `enum` *do* take the
  next token when written without `=`.)

## Pointing at the schema

The `Taskfile.pkl` schema lives in this repo. From a downstream project
pick whichever option fits:

| Option | `amends` line | Notes |
| --- | --- | --- |
| Pkl package (recommended) | `amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.16.0#/Taskfile.pkl"` | Versioned, integrity-checked, cached by Pkl. |
| HTTPS, floating tip | `amends "https://raw.githubusercontent.com/mizchi/pkfire/main/pkl/Taskfile.pkl"` | What older `pkf init` wrote. Pkl fetches and caches. |
| HTTPS, pinned tag | `amends "https://raw.githubusercontent.com/mizchi/pkfire/pkfire@0.16.0/pkl/Taskfile.pkl"` | Pinned to a release tag, no package resolution. |
| Local clone | `amends "../pkfire/pkl/Taskfile.pkl"` | When `mizchi/pkfire` is a sibling checkout. |

The package is published as a GitHub release whose tag matches
`pkfire@<version>`. `pkg.pkl-lang.org` redirects the URI above to the
release zip — see `pkl/PklProject` for the metadata and
`.github/workflows/pkl-publish.yml` for the publish flow.

## How the cache is stored

An entry used to be one gzipped tar per action key. That is correct, and
it makes a hit a single file read — but it stores every output of every
key in full, and outputs mostly do not change. Measured on a task with
300 declared outputs: editing one input file stored a second 8 MB
archive of which all but one file was a byte-identical copy of the
first.

So an entry is two things:

```
<cache>/ac/<key[0:2]>/<key[2:]>/result.json    what the action produced
<cache>/blobs/<digest[0:2]>/<digest[2:]>       the bytes, named by content
```

The manifest lists each output's path, mode and content digest; the
blobs are shared by every entry that produced the same bytes. Two keys
whose outputs differ in one file now cost one file, not one tree. On the
300-output task above, the second run costs one blob instead of 8 MB —
`pkf cache stats` reports the difference:

```console
$ pkf cache stats
entries:   2
blobs:     301
size:      7.7 MB
shared:    7.6 MB saved (49% of 15.4 MB stored once)
```

Blobs are named by the SHA-256 of their *uncompressed* content and
stored gzipped: the same bytes have to land on the same name whichever
run wrote them, and gzip output is not required to be identical across
versions. The manifest is written last, after every blob it names, so an
entry that exists is one whose contents are already on disk.

Because entries share blobs, removing an entry frees nothing by itself.
`pkf cache prune` and `pkf cache rm` sweep afterwards and report what the
sweep actually deleted, which for a shared blob is nothing:

```console
$ pkf cache rm 68e964b2
removed 68e964b2...
removed 1 entries and 1 blob(s) (26.4 KB freed)
```

Entries written before the split are still read, so upgrading does not
cold-start a warm cache. Nothing writes there again, and they age out
through `prune` like anything else.

## Remote cache

Set `PKFIRE_REMOTE_CACHE` (and optionally `PKFIRE_REMOTE_TOKEN`) to point
`pkf` at any HTTP server that speaks the cache protocol — the local CAS
becomes a write-through layer, and a teammate / CI runner that has never
built before can restore artifacts from the remote on its first run.

```sh
export PKFIRE_REMOTE_CACHE=https://pkfire-cache.<account>.workers.dev
export PKFIRE_REMOTE_TOKEN=<auth token>
pkf run build    # hits local first → falls back to remote → falls back to running
```

The reference backend is a 60-line Cloudflare Worker that stores blobs
in R2 and runs a daily TTL-based GC; see
[`examples/remote-cache-worker/`](./examples/remote-cache-worker/).

Protocol summary:

```
GET  /v1/cas/<hex64>   → 200 + tar.zst | 404
HEAD /v1/cas/<hex64>   → 200 | 404
PUT  /v1/cas/<hex64>   → 201 (or 200 if already present)
Authorization: Bearer <token>   (optional)
Content-Length: <bytes>         (on PUT)
```

Uploads declare `Content-Length` rather than using chunked transfer
encoding, so a backend that reads bodies by length alone — most object
stores, and any handler that does not special-case `Transfer-Encoding` —
receives the whole archive. `examples/remote-cache-worker/testing/`
holds a deliberately strict server that rejects a chunked body outright;
CI uploads to it and fetches back, so a client that stops declaring the
length fails the build rather than silently storing nothing.

## Skill

If you author Pkl tasks with help from a Claude Code agent (or any
similar tool that consumes APM-style skills), point it at
[`skills/pkfire/SKILL.md`](./skills/pkfire/SKILL.md). It documents the
schema, the typed-`deps` model, the cache semantics, and the common
pitfalls, plus copy-paste recipes under
[`skills/pkfire/assets/recipes/`](./skills/pkfire/assets/recipes/) for
build/test, split/import, services, hooks, diagnostics, and cache
workflows.

## Used by

Real-world consumers building on top of the schema or the action.
Open a PR to add yours.

| Project | What it provides |
| --- | --- |
| [kawaz/pkf-tasks](https://github.com/kawaz/pkf-tasks) | Shared Pkl task modules published as a Pkl package: `vcs/auto.pkl` (jj/git runtime dispatch via abstract module + extends), `docs/translations.pkl` (translation-pair integrity), `lint/pkl.pkl` (`pkl format -w`). Worked example of the library-author patterns documented in [`skills/pkfire/SKILL.md`](./skills/pkfire/SKILL.md). |

## Examples

| Path | What it shows |
| --- | --- |
| [`examples/basic`](./examples/basic/Taskfile.pkl) | Smallest possible Taskfile (one `hello`, one `build`, one `test`) |
| [`examples/node`](./examples/node/) | Node project using the built-in `node:test` runner; zero dev deps |
| [`examples/rust`](./examples/rust/) | Single-binary Rust crate driven through `cargo` (fmt + clippy + test + build) |
| [`examples/monorepo`](./examples/monorepo/) | pnpm workspaces with one Task generated per package via a `Package` template |
| [`examples/diagnostics`](./examples/diagnostics/) | `lint --json`, `doctor --json`, internal tasks, quiet output, strict shell flags |
| [`examples/split-import`](./examples/split-import/) | Single entry Taskfile with task fragments under `tasks/`, shared constants, and typed cross-file deps |
| [`examples/dogfood`](./examples/dogfood/Taskfile.pkl) | pkfire builds itself: cross-compile matrix + checksum + integration |
| [`examples/remote-cache-worker`](./examples/remote-cache-worker/) | Cloudflare Worker that backs the remote-cache protocol with R2 |

## Status

| Phase | Scope | Status |
| --- | --- | --- |
| 0 | Pkl schema, `pkl test` baseline, CLI skeleton | ✅ |
| 1 | Load `Taskfile.pkl` via `pkl-go`, build DAG, run serially | ✅ |
| 2 | Parallel execution honoring `deps` (per-task IO capture) | ✅ `pkf run -j N` / `-j auto`; sequential remains the default |
| 3 | Action key (SHA-256 over a canonical action descriptor) | ✅ |
| 4 | Local CAS, hit/miss, output restore | ✅ |
| 5 | Watch mode (`pkf watch <task>`) | ✅ |
| 6 | Remote cache (HTTP backend + reference Cloudflare Worker) | ✅ |
| 7 | Pkl package publish (`pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire`) | ✅ |
| 8 | GitHub Action (`mizchi/pkfire@pkfire@<ver>`) + pre-built binaries on release | ✅ |
| 9 | `pkf up`: long-running services (`service = true`) with process-group cleanup and watch-driven restart | ✅ |
| 10 | `services { ... }` on a body task: `pkf run e2e` brings up live servers, runs the test, releases everything | ✅ |
| 11 | Readiness probes (`readyPort` / `readyCmd`): reuse already-running services and gate dependents on real readiness | ✅ |
| 12 | Env inheritance default + variadic tail args (`acceptsArgs`) + typed named params (`params` w/ string/enum/int/bool) + `/` in task names | ✅ |
| 13 | Input auditing via libc interposition (`pkf trace`) — see [docs/auto-inputs.md](./docs/auto-inputs.md) | ✅ Linux only |
| 14 | Sandboxed execution (`pkf run --sandbox`, or `hermetic = true` per task): declared inputs only, declared outputs collected back, ambient env sealed | ✅ symlink forest; absolute paths (the toolchain) still resolve |
| — | Presentation flags the Go implementation had and the MoonBit port has not reimplemented: `list --long` / `--unsorted` / `--color`, `doctor --fix`, `explain --diff`, `lint --fix` | ⛔ they exit with "unknown flag"; `list --json` covers the tooling cases |

The [Bazel-style build engine roadmap][roadmap] tracks what separates
this from a real action-graph engine. Hermetic execution, the parallel
scheduler and the ActionCache/CAS split have landed; remote execution
has not.

[roadmap]: https://github.com/mizchi/pkfire/issues/60

## Development

pkfire dogfoods itself: the repo's own `Taskfile.pkl` declares the
maintenance tasks, and the build / integration gate lives in
`examples/dogfood/Taskfile.pkl`. `pkf` itself is a MoonBit program
rooted at the repo root (`moon.mod` + `src/`); build it with the
MoonBit toolchain, then drive the rest with the freshly built binary.

```sh
moon build src/cmd/pkf --target native --release
BIN=_build/native/release/build/mizchi/pkf/src/cmd/pkf/pkf.exe

"$BIN" list                                      # see all maintenance tasks
"$BIN" run preflight                             # moon check/test + pkl-test + examples + version + format
"$BIN" run conformance                           # contract harness: candidate vs frozen goldens (44/44)
"$BIN" run fmt                                    # pkl format -w on Taskfile.pkl, pkl/, examples/, skills/
"$BIN" run fmt:check                             # formatting check without writing
"$BIN" run -f examples/dogfood/Taskfile.pkl ci   # full build + integration gate
```

To cut a Pkl package release:

```sh
# 1. Bump README + skills + recipes + PklProject. Examples are NOT
#    touched here — they pin to a *published* URL and would 404 on
#    `pkl eval` until the release workflow finishes.
pkf run bump --to=<new-version>
git commit -am "release: pkfire@<new-version>"

# 2. Tag locally and push. Release + v-tags workflows fire.
# The Release workflow extracts the body for the GitHub release page
# from CHANGELOG.md's `## [<new-version>]` section automatically —
# update that section BEFORE this step so the published notes match.
pkf run tag
git push origin main "pkfire@<new-version>"

# 3. After the publish workflow uploads the package, bump examples
#    in a follow-up commit.
perl -i -pe 's/pkfire\@<old>/pkfire\@<new-version>/g' \
  examples/basic/Taskfile.pkl examples/node/Taskfile.pkl \
  examples/rust/Taskfile.pkl examples/monorepo/Taskfile.pkl \
  examples/diagnostics/Taskfile.pkl examples/split-import/Taskfile.pkl \
  examples/split-import/tasks/*.pkl
git commit -am "examples: bump amends URI to pkfire@<new-version>"
git push
```

`pkf run check-version` (wrapping
`scripts/check-version-consistency.sh`) covers the in-flight
schema version across README + skills + recipes. Examples are
excluded for the publish-order reason above.

## License

MIT — see [LICENSE](./LICENSE).
