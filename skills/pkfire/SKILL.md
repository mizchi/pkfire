---
name: pkfire
description: Author and maintain `Taskfile.pkl` files for the `pkf` task runner. Use when adding, editing, or troubleshooting tasks in a project that has `pkf` installed (or is choosing it over `just` / `Taskfile.yml`). Covers the Pkl schema, the typed `deps` model, cache semantics (action key, local CAS, remote HTTP backend, symlink support), watch mode, and the common pitfalls. Recipes under `assets/recipes/` are copy-paste starting points for the patterns this skill describes.
---

# pkfire — authoring `Taskfile.pkl`

`pkf` is a typed task runner: tasks declare their inputs, outputs, and
dependencies in Pkl, and a content-addressed cache decides what
actually runs. This skill is for whoever is editing the `Taskfile.pkl`.

## When to invoke this skill

- A new task needs to be added or an existing task changed.
- A task is "always re-running" or "always hitting cache when it
  shouldn't" — that is a hashing question, not a runner bug.
- A team wants to share cache hits across machines / CI (remote cache).
- Migrating from `justfile` or `Taskfile.yml`.

Do **not** invoke for unrelated build-system questions (Make, Bazel,
Gradle, etc.) or for editing Pkl that does not amend pkfire's schema.

## Mental model

A Taskfile is a Pkl module that **amends** the pkfire schema and
declares one `local Task` per unit of work, then lists them in
`tasks { ... }`. The runner builds a DAG over `deps`, executes only
the tasks whose **action key** changed, and restores the cached
outputs of every other task from a CAS.

**Action key** = BLAKE3 over (`cmd`, `shell`, sorted env, sorted tools,
sorted input file digests, the Pkl module's canonical form). Two
invocations with the same key are guaranteed to produce the same
outputs (assuming honest `inputs` declarations).

## The two non-obvious rules

1. **Every authored task must appear in `tasks { ... }`.** Pkl's
   `amends` semantics forbid adding new top-level fields, so
   reflection-based auto-collection cannot work. A `local foo = new
   Task { ... }` that is not listed in `tasks` is dead code from the
   runner's perspective.
2. **`deps` are real Task references, not strings.** Write
   `deps { build }`, not `deps { "build" }`. A typo in a name is then a
   Pkl evaluation error, not a runtime DAG error.

## Schema cheat sheet

```pkl
class Task {
  name: String                                    // required, regex-checked
  cmd: String(length > 0)                         // required
  shell: String = "bash"
  inputs: Listing<String>  = new {}               // glob; missing files silently ignored
  outputs: Listing<String> = new {}               // restored on cache hit
  deps: Listing<Task>      = new {}               // direct references
  env: Mapping<String, String>   = new {}         // contributes to action key
  tools: Mapping<String, String> = new {}         // declared toolchain versions
  cache: Boolean = true                           // false = always run
  workdir: String?     = null                     // relative to Taskfile dir
  description: String? = null
}
```

## Authoring template (always start from this)

```pkl
amends "https://raw.githubusercontent.com/mizchi/pkfire/main/pkl/Taskfile.pkl"

local sources: Listing<String> = new {
  // file globs your build reads from
}

local build: Task = new {
  name = "build"
  cmd = "go build -o bin/app ./cmd/app"
  inputs = sources
  outputs { "bin/app" }
}

local test: Task = new {
  name = "test"
  cmd = "go test ./..."
  inputs = sources
  deps { build }      // direct Task reference
}

tasks { build; test }
```

Pin the schema URL to a tag (`/v0.1.0/`) for production / CI.

## Recipes (copy-paste starters)

| File | Pattern |
| --- | --- |
| [`assets/recipes/01-build-and-test.pkl`](./assets/recipes/01-build-and-test.pkl) | Minimum viable: one build, one test, deps chain |
| [`assets/recipes/02-multi-platform-matrix.pkl`](./assets/recipes/02-multi-platform-matrix.pkl) | Cross-compile matrix via `local function` + `for` |
| [`assets/recipes/03-monorepo.pkl`](./assets/recipes/03-monorepo.pkl) | Per-package tasks generated from a `Package` template |
| [`assets/recipes/04-dev-watch.pkl`](./assets/recipes/04-dev-watch.pkl) | A long-running dev task plus a quick lint pre-flight |
| [`assets/recipes/05-remote-cache.pkl`](./assets/recipes/05-remote-cache.pkl) | Same Taskfile, configured via env to use a remote cache |

## Common pitfalls

- **`A non-local object property cannot have a type annotation`** —
  you wrote `field: Task = ...` inside an `amends`. Use a `local`
  binding and add it to `tasks { ... }`.
- **Self-shadowing names cause stack overflow** — a function with
  `(p, deps: Listing<Task>): Task = new { deps = deps }` recurses
  forever because `deps` resolves to the field on the value being
  built. Rename the parameter (`taskDeps`).
- **`new {}` inside `Listing<Task>` is ambiguous** — write
  `new Listing<Task> { taskA; taskB }` to disambiguate.
- **`outputs` parents are not auto-created** — your `cmd` must
  `mkdir -p bin && ...` if it writes to `bin/app` and `bin/` does not
  exist yet (some tools, like `go build -o`, do this themselves).
- **Inputs with literal paths that do not exist are silently
  ignored** — useful tolerance for optional files (e.g. `go.sum` in
  a no-deps Go project), surprising when you misspelled a real file.
  Use `pkf run --print-hash <task>` to see what actually contributed.

## CLI tools

```sh
pkf list -v                    # cmd preview + deps + cache status
pkf run --dry-run <task>       # plan only, no execution, no cache touch
pkf run --print-hash <task>    # action keys for the subgraph
pkf run --watch <task>         # re-run on input change
pkf graph                      # Graphviz DOT
pkf graph --format mermaid     # GitHub-renderable
```

## Remote cache (optional)

```sh
export PKFIRE_REMOTE_CACHE=https://pkfire-cache.<account>.workers.dev
export PKFIRE_REMOTE_TOKEN=<bearer token>
```

Local cache stays the source of truth; the remote is consulted on a
local miss and warmed on a remote hit. See `examples/remote-cache-worker/`
in the upstream repo for a Cloudflare Worker reference backend that
GCs entries older than `CACHE_TTL_DAYS` (default 7) on a daily cron.
