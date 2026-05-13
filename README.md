# pkfire

[![Test](https://github.com/mizchi/pkfire/actions/workflows/test.yml/badge.svg)](https://github.com/mizchi/pkfire/actions/workflows/test.yml)
[![Nix](https://github.com/mizchi/pkfire/actions/workflows/nix.yml/badge.svg)](https://github.com/mizchi/pkfire/actions/workflows/nix.yml)

> Typed task runner with Bazel-style incremental caching, configured in [Pkl](https://pkl-lang.org/).

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
A cross-compile matrix becomes a one-line `local function
buildTask(p)` that the schema invokes for each platform — see
[`examples/dogfood/`](./examples/dogfood/Taskfile.pkl), where four
near-duplicate `just` recipes were collapsed into a single template.
Renaming a task in one place updates every reference; misspelling a
dependency fails at evaluation time, before the runner starts.

On top of the language layer, pkfire adds the parts a string-based
runner can't: a content-addressed cache keyed on inputs/cmd/env, an
HTTP remote cache so CI and teammates can share hits, and a watch
mode that reruns only the affected subgraph.

## Install

### Go

```sh
go install github.com/mizchi/pkfire/cmd/pkf@latest
```

You also need the Pkl CLI (`pkl`) on `PATH`; install it from
[pkl-lang.org](https://pkl-lang.org/main/current/pkl-cli/) or via your
package manager.

### GitHub Actions

A setup-only composite action lives at the repo root:

```yaml
# .github/workflows/ci.yml
jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: mizchi/pkfire@v0.7.0       # or @v0 to track the latest 0.x
      - run: pkf run ci
```

The action downloads the matching `pkf` binary and the Pkl CLI for
the runner (`linux/darwin × amd64/arm64`) and adds them to `PATH`.
After it runs, the rest of the workflow calls `pkf` directly — no
`go install`, no Pkl bootstrap.

> **Why `@v0.5.0` and not `@pkfire@0.7.0`?** GitHub Actions cannot
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
      - uses: mizchi/pkfire@v0.7.0
      - run: pkf run ci
        env:
          PKFIRE_REMOTE_CACHE: ${{ vars.PKFIRE_REMOTE_CACHE }}
          PKFIRE_REMOTE_TOKEN: ${{ secrets.PKFIRE_REMOTE_TOKEN }}
```

Inputs:

| Input | Default | Notes |
| --- | --- | --- |
| `version` | the action ref, falling back to the latest release | Accepts `v0.5.0`, `0.4.0`, `v0` (floating major), or the underlying `pkfire@0.7.0`. Pinning via `uses: mizchi/pkfire@v0.7.0` is the recommended form. |
| `pkl-version` | `0.31.1` | Set to `none` to skip the Pkl install when only `pkf` is needed. |
| `install-dir` | `${{ runner.temp }}/pkfire-bin` | Both binaries are placed here; the dir is appended to `GITHUB_PATH`. |
| `cache-pkl` | `false` | Set to `true` to cache `~/.pkl/cache` between runs. Useful for projects that consume remote Pkl packages (`amends` / `import` of `package://pkg.pkl-lang.org/...`). |
| `pkl-cache-key` | `pkl-<hashFiles>` of `PklProject.deps.json` + `Taskfile.pkl` | Override only if the default key collides across unrelated jobs in the same repo. |

### Nix (no Go toolchain required)

```sh
nix run github:mizchi/pkfire -- run hello       # one-shot
nix profile install github:mizchi/pkfire        # persistent
```

The flake builds the `pkf` binary and wraps it so the bundled Pkl CLI
is on `PATH` automatically — end users do not install Go or Pkl
themselves. The Nix workflow on every push to `main` and on every PR
verifies the flake builds cleanly on `aarch64-darwin` and
`x86_64-linux` runners; the badge above tracks its status.

`nix develop` opens a shell with `go`, `pkl`, and `gopls` for working
on pkfire itself.

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
amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.7.0#/Taskfile.pkl"

local build = new Task {
  name = "build"
  cmd = "go build -o bin/app ./cmd/app"
  inputs { "**/*.go"; "go.mod"; "go.sum" }
  outputs { "bin/app" }
}

local test = new Task {
  name = "test"
  cmd = "go test ./..."
  inputs { "**/*.go" }
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
pkf list --unsorted            # show tasks in Taskfile declaration order
pkf list --all                 # include internal tasks
pkf list --color=always        # force ANSI color (auto, always, never)
pkf list -v                    # add cmd preview and deps
pkf list --json                # machine-readable (for editor / CI tooling)
pkf run test                   # builds first, then tests; second run hits cache
pkf run -j 8 test              # cap parallelism at 8
pkf run --watch test           # re-run on input changes (Ctrl+C to stop)
pkf run --dry-run test         # preview: per-task hit/will-run/uncached status + cmd
pkf run --print-hash test      # print action keys, do not execute
pkf run --no-cache test        # bypass cache lookup AND store for this run
pkf run --refresh test         # bypass cache lookup but DO re-store (re-baseline)
pkf up dev                     # start every service:true task in dev's subgraph
pkf up --watch dev             # same, plus restart-on-change
pkf graph                      # emit Graphviz DOT for the full DAG
pkf graph --format mermaid     # emit Mermaid flowchart (renders on GitHub)
pkf graph --target test        # only the subgraph rooted at `test`
pkf doctor                     # diagnose pkl/cache/remote/taskfile setup
pkf format                     # pkl format -w on the Taskfile's directory
pkf format --check pkl examples # exit 11 (CI-friendly) if anything is unformatted
pkf hooks install              # write .git/hooks/<event> shims for matching tasks
pkf hooks list                 # show which hook events are wired
pkf affected --since=origin/main test  # run only tasks affected by the PR diff
pkf run a b c                  # run multiple targets in one go (topological union)
pkf run                        # no args = the `default` task (errors if absent)
pkf run -- a b c               # forward args to the `default` task when it accepts args
pkf run --timing build         # also print per-task wall time at the end
pkf run 'test:*'               # glob over task names (also works on affected / clean)
pkf clean                      # rm declared outputs of every task; --dry-run to preview
pkf cache stats                # local CAS: entries, size, oldest/newest
pkf cache prune --older-than=7d  # drop stale entries (--dry-run to preview)
pkf cache rm <action-key>      # remove a specific entry (≥2-char prefix accepted)
pkf cache clear --yes          # nuke everything (scripting-safe with --yes)
pkf run --quiet build          # suppress per-task log lines (errors + summary still print)
pkf completion bash > ~/.bash_completion.d/pkf  # dynamic task-name completion
pkf completion zsh > "${fpath[1]}/_pkf"
pkf completion fish > ~/.config/fish/completions/pkf.fish
pkf run --keep-going lint test # don't stop on first failure (Bazel / make -k)
pkf explain build              # dump every input to the action key (cache-miss debug)
pkf run --profile=ci build     # tag the run; $PKF_PROFILE + cache splits per profile
pkf run --on-fail=shell build  # drop into $SHELL in the failed task's workdir on error
pkf run --remote-only build    # skip local cache, only consult remote (verify remote populated)
pkf affected --watch           # re-evaluate affected set on every file change
pkf graph --target build --depth=1   # show only direct deps (one hop)
pkf graph --format tree        # terminal-readable dependency tree (roots only when no target)
pkf graph --format tree --target test --depth=2  # tree with deps up to two hops
pkf lint                       # detect local Task definitions omitted from tasks { ... }
pkf migrate --to=0.5.0         # rewrite Taskfile.pkl's amends URI + verify
pkf pkl-cache warm             # pre-populate ~/.pkl/cache (CI prefetch step)
pkf <plugin> <args>            # exec `pkf-<plugin>` on PATH (git-style fallthrough)
```

Inside `cmd`, three env vars are always injected so tasks can
reference their own context without hardcoding paths:

- `PKF_TASK_NAME` — the task's `name`.
- `PKF_TASK_ROOT` — absolute path to the task's `workdir` (or the
  Taskfile directory when `workdir` is null).
- `PKF_WORKSPACE_ROOT` — absolute path to the Taskfile's directory.

These are NOT part of the action key — they're constants of the
task definition, already implicit in the hash via cmd / env / inputs.

Visualizing a Taskfile is a single pipeline:

```sh
pkf graph | dot -Tsvg -o tasks.svg
pkf graph --format mermaid > tasks.mmd
pkf graph --format tree --target test
```

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

### Two contracts that are NOT the same

| | Visible to `cmd`? | Part of the action key? |
| --- | :---: | :---: |
| host env (when `inheritEnv = true`, the default) | ✓ | ✗ |
| host env (when `inheritEnv = false`, allowlist only: `PATH HOME LANG ...`) | partial | ✗ |
| `defaults.Env` | ✓ | ✓ |
| `task.Env` | ✓ | ✓ |
| resolved `params` values (`$NAME`) | ✓ | ✓ (when `cache = true`) |
| tail args from `-- a b c` (`$@`) | ✓ | ✓ (when `cache = true`) |
| `task.Tools` | as env hints only | ✓ |

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
| Pkl package (recommended) | `amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.7.0#/Taskfile.pkl"` | Versioned, integrity-checked, cached by Pkl. |
| HTTPS, floating tip | `amends "https://raw.githubusercontent.com/mizchi/pkfire/main/pkl/Taskfile.pkl"` | What older `pkf init` wrote. Pkl fetches and caches. |
| HTTPS, pinned tag | `amends "https://raw.githubusercontent.com/mizchi/pkfire/pkfire@0.7.0/pkl/Taskfile.pkl"` | Pinned to a release tag, no package resolution. |
| Local clone | `amends "../pkfire/pkl/Taskfile.pkl"` | When `mizchi/pkfire` is a sibling checkout. |

The package is published as a GitHub release whose tag matches
`pkfire@<version>`. `pkg.pkl-lang.org` redirects the URI above to the
release zip — see `pkl/PklProject` for the metadata and
`.github/workflows/pkl-publish.yml` for the publish flow.

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
```

## Skill

If you author Pkl tasks with help from a Claude Code agent (or any
similar tool that consumes APM-style skills), point it at
[`skills/pkfire/SKILL.md`](./skills/pkfire/SKILL.md). It documents the
schema, the typed-`deps` model, the cache semantics, and the common
pitfalls, plus five copy-paste recipes under
[`skills/pkfire/assets/recipes/`](./skills/pkfire/assets/recipes/) for
build/test, cross-compile matrix, monorepo, dev/watch, and remote
cache.

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
| [`examples/dogfood`](./examples/dogfood/Taskfile.pkl) | pkfire builds itself: cross-compile matrix + checksum + integration |
| [`examples/remote-cache-worker`](./examples/remote-cache-worker/) | Cloudflare Worker that backs the remote-cache protocol with R2 |

## Status

| Phase | Scope | Status |
| --- | --- | --- |
| 0 | Pkl schema, `pkl test` baseline, CLI skeleton | ✅ |
| 1 | Load `Taskfile.pkl` via `pkl-go`, build DAG, run serially | ✅ |
| 2 | Parallel execution honoring `deps` (per-task IO capture) | ✅ |
| 3 | Action key (BLAKE3 over cmd / shell flags / env / inputs / tools / config) | ✅ |
| 4 | Local CAS, hit/miss, output restore | ✅ |
| 5 | Watch mode (`pkf run --watch`) | ✅ |
| 6 | Remote cache (HTTP backend + reference Cloudflare Worker) | ✅ |
| 7 | Pkl package publish (`pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire`) | ✅ |
| 8 | GitHub Action (`mizchi/pkfire@pkfire@<ver>`) + pre-built binaries on release | ✅ |
| 9 | `pkf up`: long-running services (`service = true`) with process-group cleanup and watch-driven restart | ✅ |
| 10 | `services { ... }` on a body task: `pkf run e2e` brings up live servers, runs the test, releases everything | ✅ |
| 11 | Readiness probes (`readyPort` / `readyCmd`): reuse already-running services and gate dependents on real readiness | ✅ |
| 12 | Env inheritance default + variadic tail args (`acceptsArgs`) + typed named params (`params` w/ string/enum/int/bool) + `/` in task names | ✅ |

## Development

pkfire dogfoods itself: the repo's own `Taskfile.pkl` declares the
maintenance tasks, and the cross-compile / integration matrix lives
in `examples/dogfood/Taskfile.pkl`. Both work with the `pkf` binary
you'd install for any other project.

```sh
go install ./cmd/pkf

pkf list                                      # see all maintenance tasks
pkf run preflight                             # vet + go-test + pkl-test + version consistency
pkf run test:race                             # go test -race ./...
pkf run fmt                                   # pkl format -w on pkl/, examples/, skills/
pkf run -f examples/dogfood/Taskfile.pkl ci   # full release gate (cross-compile + integration)
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
  examples/rust/Taskfile.pkl examples/monorepo/Taskfile.pkl
git commit -am "examples: bump amends URI to pkfire@<new-version>"
git push
```

`pkf run check-version` (wrapping
`scripts/check-version-consistency.sh`) covers the in-flight
schema version across README + skills + recipes. Examples are
excluded for the publish-order reason above.

## License

MIT — see [LICENSE](./LICENSE).
