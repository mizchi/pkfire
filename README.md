# pkfire

> Typed task runner with Bazel-style incremental caching, configured in [Pkl](https://pkl-lang.org/).

`pkfire` (CLI: `pkf`) replaces hand-written `justfile`s with a typed,
composable Pkl schema. Tasks declare their inputs, outputs, and
dependencies; `pkf` builds a DAG and executes only the steps whose
action key has changed. Cached outputs are restored from a
content-addressed store under `~/.cache/pkfire`.

## Quick start

```sh
go install github.com/mizchi/pkfire/cmd/pkf@latest

mkdir my-project && cd my-project
pkf init                # writes a starter Taskfile.pkl
pkf run hello           # smoke the generated task
```

`pkf init` writes a Taskfile that `amends` the schema over HTTPS, so
your project does not need a clone of this repo.

### Nix flake (no Go required)

The flake at the repository root produces a `pkf` derivation that
wraps the binary so the bundled Pkl CLI is on `PATH` automatically.
Users do not need a Go toolchain.

```sh
nix run github:mizchi/pkfire -- run hello       # one-shot
nix profile install github:mizchi/pkfire        # persistent
```

In a home-manager flake:

```nix
{
  inputs.pkfire.url = "github:mizchi/pkfire";

  outputs = { self, nixpkgs, home-manager, pkfire, ... }: {
    homeConfigurations.example = home-manager.lib.homeManagerConfiguration {
      modules = [{
        home.packages = [ pkfire.packages.${pkgs.system}.default ];
      }];
    };
  };
}
```

`nix develop` opens a shell with `go`, `pkl`, and `gopls` for working
on pkfire itself.

## Authoring a Taskfile

```pkl
amends "https://raw.githubusercontent.com/mizchi/pkfire/main/pkl/Taskfile.pkl"

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
| HTTPS, floating tip | `amends "https://raw.githubusercontent.com/mizchi/pkfire/main/pkl/Taskfile.pkl"` | What `pkf init` writes. Pkl fetches and caches. |
| HTTPS, pinned tag | `amends "https://raw.githubusercontent.com/mizchi/pkfire/v0.1.0/pkl/Taskfile.pkl"` | Reproducible across machines and CI. |
| Local clone | `amends "../pkfire/pkl/Taskfile.pkl"` | When `mizchi/pkfire` is a sibling checkout. |

A `package://pkg.pkl-lang.org/mizchi/pkfire` URI is planned but not
published yet — until then, do not use the form shown in older docs.

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

## Why Pkl

`just` recipes get unwieldy once you need shared variables, environment
matrices, or per-package overrides. Pkl gives a real type system,
`amends` for template inheritance, and `pkl test` for unit-testing the
schema itself — all while still emitting deterministic configuration.
The complex example under [`examples/dogfood/`](./examples/dogfood/Taskfile.pkl)
generates a cross-compile matrix with a `local function buildTask(p)`
where four near-duplicate `just` recipes would have lived.

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
| 7 | Pkl package publish (`pkg.pkl-lang.org/mizchi/pkfire`) | planned |

## Development

```sh
pkl test                                      # schema-level tests
go test -race ./...                           # Go tests
go install ./cmd/pkf
pkf run -f examples/dogfood/Taskfile.pkl ci   # dogfood
```

## License

MIT — see [LICENSE](./LICENSE).
