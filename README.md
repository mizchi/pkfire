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
      - uses: actions/checkout@v4
      - uses: mizchi/pkfire@pkfire@0.1.0
      - run: pkf run ci
```

The action downloads the matching `pkf` binary and the Pkl CLI for
the runner (`linux/darwin × amd64/arm64`) and adds them to `PATH`.
After it runs, the rest of the workflow calls `pkf` directly — no
`go install`, no Pkl bootstrap.

Pin the action ref to a release tag (`pkfire@0.1.0`) so the action
code, the `pkf` binary, and the Pkl schema all move together. To
share cache hits across CI runs and developers, wire the remote
cache env:

```yaml
      - uses: mizchi/pkfire@pkfire@0.1.0
      - run: pkf run ci
        env:
          PKFIRE_REMOTE_CACHE: ${{ vars.PKFIRE_REMOTE_CACHE }}
          PKFIRE_REMOTE_TOKEN: ${{ secrets.PKFIRE_REMOTE_TOKEN }}
```

Inputs:

| Input | Default | Notes |
| --- | --- | --- |
| `version` | the action ref, falling back to the latest release | Pin both the action and the binary together by writing `mizchi/pkfire@pkfire@0.1.0`. Override here if you want to install a different binary than the action ref. |
| `pkl-version` | `0.31.1` | Set to `none` to skip the Pkl install when only `pkf` is needed. |
| `install-dir` | `${{ runner.temp }}/pkfire-bin` | Both binaries are placed here; the dir is appended to `GITHUB_PATH`. |

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
amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.1.0#/Taskfile.pkl"

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

When `-f` is not supplied, `pkf` walks up from the current directory
to find the nearest `Taskfile.pkl` (the same discovery rule git uses
for `.git/`), so any of these works the same:

```sh
cd services/api/internal && pkf run ci    # uses services/api/Taskfile.pkl
cd /repo/root && pkf run ci               # uses /repo/root/Taskfile.pkl
```

```sh
pkf list                       # show declared tasks
pkf list -v                    # add cmd preview and deps
pkf run test                   # builds first, then tests; second run hits cache
pkf run -j 8 test              # cap parallelism at 8
pkf run --watch test           # re-run on input changes (Ctrl+C to stop)
pkf run --dry-run test         # print the execution plan, do not execute
pkf run --print-hash test      # print action keys, do not execute
pkf run --no-cache test        # bypass cache for this run
pkf graph                      # emit Graphviz DOT for the full DAG
pkf graph --format mermaid     # emit Mermaid flowchart (renders on GitHub)
pkf graph --target test        # only the subgraph rooted at `test`
```

Visualizing a Taskfile is a single pipeline:

```sh
pkf graph | dot -Tsvg -o tasks.svg
pkf graph --format mermaid > tasks.mmd
```

## Pointing at the schema

The `Taskfile.pkl` schema lives in this repo. From a downstream project
pick whichever option fits:

| Option | `amends` line | Notes |
| --- | --- | --- |
| Pkl package (recommended) | `amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.1.0#/Taskfile.pkl"` | Versioned, integrity-checked, cached by Pkl. |
| HTTPS, floating tip | `amends "https://raw.githubusercontent.com/mizchi/pkfire/main/pkl/Taskfile.pkl"` | What older `pkf init` wrote. Pkl fetches and caches. |
| HTTPS, pinned tag | `amends "https://raw.githubusercontent.com/mizchi/pkfire/pkfire@0.1.0/pkl/Taskfile.pkl"` | Pinned to a release tag, no package resolution. |
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
| 3 | Action key (BLAKE3 over cmd / env / inputs / tools / config) | ✅ |
| 4 | Local CAS, hit/miss, output restore | ✅ |
| 5 | Watch mode (`pkf run --watch`) | ✅ |
| 6 | Remote cache (HTTP backend + reference Cloudflare Worker) | ✅ |
| 7 | Pkl package publish (`pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire`) | ✅ |
| 8 | GitHub Action (`mizchi/pkfire@pkfire@<ver>`) + pre-built binaries on release | ✅ |

## Development

```sh
pkl test --project-dir pkl                    # schema-level tests
pkl project package pkl                       # build the publishable .out/pkfire@<ver>/ artifacts
go test -race ./...                           # Go tests
go install ./cmd/pkf
pkf run -f examples/dogfood/Taskfile.pkl ci   # dogfood
```

To cut a Pkl package release:

```sh
# 1. bump every `pkfire@<old>` reference (PklProject + examples + recipes
#    + skills + README) in one shot
scripts/bump-version.sh <new-version>
# 2. commit, tag, push
git commit -am "release: pkfire@<new-version>"
git tag    "pkfire@<new-version>"
git push origin main "pkfire@<new-version>"
# 3. .github/workflows/pkl-publish.yml gates on the test suite, then
#    builds and uploads the Pkl package + cross-compiled binaries.
```

Both pre-commit and CI run `scripts/check-version-consistency.sh` so a
forgotten reference becomes a red build, not a stale URI in the wild.

## License

MIT — see [LICENSE](./LICENSE).
