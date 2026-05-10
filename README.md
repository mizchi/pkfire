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

## Authoring a Taskfile

```pkl
amends "https://raw.githubusercontent.com/mizchi/pkfire/main/pkl/Taskfile.pkl"

tasks {
  ["build"] = new Task {
    cmd = "go build -o bin/app ./cmd/app"
    inputs { "**/*.go"; "go.mod"; "go.sum" }
    outputs { "bin/app" }
  }
  ["test"] = new Task {
    cmd = "go test ./..."
    inputs { "**/*.go" }
    deps { "build" }
  }
}
```

```sh
pkf list                # show declared tasks
pkf run test            # builds first, then tests; second run hits cache
pkf run -j 8 test       # cap parallelism at 8
pkf run --print-hash test   # show action keys without executing
pkf run --no-cache test     # bypass cache for this run
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
| 5 | Watch mode | planned |
| 6 | Remote cache + Pkl package publish | planned |

## Development

```sh
pkl test                                      # schema-level tests
go test -race ./...                           # Go tests
go install ./cmd/pkf
pkf run -f examples/dogfood/Taskfile.pkl ci   # dogfood
```

## License

MIT — see [LICENSE](./LICENSE).
