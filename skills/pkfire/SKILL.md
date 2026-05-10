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
| [`assets/recipes/06-split-and-import.pkl`](./assets/recipes/06-split-and-import.pkl) | Single entry point, definitions split into `shared/` + `tasks/` |
| [`assets/recipes/07-hierarchical-amends.pkl`](./assets/recipes/07-hierarchical-amends.pkl) | Per-service Taskfiles that `amends` a project-root template |

## Project layout

Three layouts cover the realistic spectrum of Taskfile sizes.
Adopt them in this order — **upgrade only when the previous layout
hurts**, not before.

### A. Single Taskfile (default; up to ~30 tasks)

```
project/
└── Taskfile.pkl
```

Pkl's `local function` + `for` keep even matrix-heavy single files
readable; see recipe 02. Stay here unless one of B / C is solving a
real pain.

### B. Split + import (single entry point, definitions distributed)

```
project/
├── Taskfile.pkl              # entry: amends pkfire schema, imports + spreads
├── shared/
│   ├── sources.pkl           # `sources: Listing<String>`, `toolchain: Mapping<...>`
│   └── env.pkl
└── tasks/
    ├── build.pkl             # `import "../shared/..."`; exports `tasks: Listing<Task>`
    └── test.pkl
```

The root `Taskfile.pkl` `import`s each fragment and spreads its
`tasks` Listing:

```pkl
amends "https://.../Taskfile.pkl"
import "tasks/build.pkl" as bt
import "tasks/test.pkl" as tt

tasks { ...bt.tasks; ...tt.tasks }
```

Use this when one file is fine for the runner but humans want smaller
files. Pkfire still consumes a single `pkf run -f Taskfile.pkl <task>`
invocation, and Task references work across files because `import`
brings real values across the boundary.

### C. Hierarchical `amends` ("Know Your Place" pattern)

```
project/
├── Taskfile.pkl              # root: shared sources/tools, project-wide tasks (lint, format)
└── services/
    ├── api/
    │   └── Taskfile.pkl      # amends "../../Taskfile.pkl"; adds build:api, test:api
    └── web/
        └── Taskfile.pkl      # amends "../../Taskfile.pkl"; adds build:web, test:web
```

Inspired by [Know Your Place](https://pkl-lang.org/blog/know-your-place.html)
from the Pkl team: the **directory tree itself encodes structure**.
Each leaf Taskfile `amends` the root and `tasks { ...new local tasks }`
appends to the inherited Listing. Run a service in isolation:

```sh
pkf run -f services/api/Taskfile.pkl ci    # only api's subgraph
pkf run -f Taskfile.pkl lint               # project-wide root tasks
```

Why this beats (B) at scale:

- A team owning `services/api/` only edits `services/api/Taskfile.pkl`;
  cross-team reviews stay scoped.
- `pkl:reflect` can derive the leaf's identity (e.g. `api`, `web`) from
  its file path — see the upstream blog post for a `findRootModule`
  helper that walks the `amends` chain.
- The root file stays the canonical place for shared `sources`,
  `tools`, and policy tasks, so changing the lint command propagates
  everywhere by editing one file.

Trade-offs:

- One `pkf run` invocation only sees one Taskfile. There is no
  "umbrella ci that runs every leaf" without a small wrapper script
  (or a deliberately authored `services/Taskfile.pkl` that imports
  the leaves).
- Leaf authors must remember the `amends` URI is relative, and
  changing the root file's location breaks every leaf at once. Pin
  the root path or use a stable HTTPS schema instead.

### Picking between B and C

| Situation | Use |
| --- | --- |
| Many tasks, single team | **B** (split, one entry) |
| Many services, many teams | **C** (hierarchical amends) |
| Mix: shared + per-service | **C with B inside each leaf** is fine |

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
