# pkfire

> Typed task runner with Bazel-style incremental caching, configured in [Pkl](https://pkl-lang.org/).

`pkfire` (CLI: `pkf`) is a task runner that replaces hand-written `justfile`s
with a typed, composable Pkl schema. Tasks declare their inputs, outputs, and
dependencies; `pkf` builds a DAG and executes only the steps whose action key
has changed. Cached outputs are restored from a content-addressed store.

## Status

Phase 0 — schema and CLI skeleton only. Nothing actually runs yet.

| Phase | Scope |
| --- | --- |
| 0 | Pkl schema, `pkl test` baseline, CLI skeleton |
| 1 | Load `Taskfile.pkl` via `pkl-go`, build DAG, run serially |
| 2 | Parallel execution honoring `deps` |
| 3 | Action key (BLAKE3 over cmd / env / inputs / tools / config) |
| 4 | Local CAS, hit/miss, output restore |
| 5 | Watch mode |
| 6 | Remote cache |

## Why Pkl

`just` recipes get unwieldy once you need shared variables, environment
matrices, or per-package overrides. Pkl gives a real type system, `amends`
for template inheritance, and `pkl test` for unit-testing the schema itself —
all while still emitting deterministic configuration.

## Example

```pkl
amends "package://pkg.pkl-lang.org/mizchi/pkfire@0.0.1#/Taskfile.pkl"

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
pkf run test
```

## Development

```sh
pkl test          # schema-level tests
go test ./...     # Go tests (once they exist)
go build ./cmd/pkf
```

## License

MIT — see [LICENSE](./LICENSE).
