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
  service: Boolean = false                        // long-running, supervised by `pkf up`
  shutdownTimeoutSeconds: Int = 5                 // SIGTERM grace before SIGKILL
  services: Listing<Task> = new {}                // services to bring up while this task runs
  readyPort: Int = 0                              // TCP port to probe; doubles as a reuse detector
  readyCmd: String = ""                           // shell snippet that exits 0 when ready
  readyTimeoutSeconds: Int = 30                   // wait budget for the probe after spawning
}
```

## Authoring template (always start from this)

```pkl
amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.3.0#/Taskfile.pkl"

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

The `package://...` URI is already version-pinned, so the same
checkout reproduces across machines and CI. To upgrade, bump the
`@<version>` segment — Pkl re-resolves and re-fetches on the next
run, then caches the new package locally.

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
| [`assets/recipes/08-services.pkl`](./assets/recipes/08-services.pkl) | `pkf up`: multiple long-running services with shared lifecycle |
| [`assets/recipes/09-test-against-services.pkl`](./assets/recipes/09-test-against-services.pkl) | `pkf run e2e` with `services { api }` — ephemeral stack for one-shot test |

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
amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.3.0#/Taskfile.pkl"
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
  the root path, or have leaves amend the pkfire package URI directly
  if they don't actually need anything from a project-root Taskfile.

### Picking between B and C

| Situation | Use |
| --- | --- |
| Many tasks, single team | **B** (split, one entry) |
| Many services, many teams | **C** (hierarchical amends) |
| Mix: shared + per-service | **C with B inside each leaf** is fine |

### Discovery (walk-up)

`pkf` discovers `Taskfile.pkl` the way `git` finds `.git/`: when
`-f` / `--file` is not specified, it walks up from the current
working directory and uses the nearest ancestor that has one. Layout C
benefits the most from this:

```sh
cd services/api/internal
pkf run ci      # finds services/api/Taskfile.pkl automatically
cd ../../..
pkf run lint    # finds the project-root Taskfile.pkl
```

An explicit `-f` opts out of walk-up — useful when the path is
relative to the *invocation* directory rather than to the Taskfile.

## Long-running services (`pkf up`)

Tasks marked `service = true` are long-running processes — dev
servers, databases, watchers — that pkfire supervises rather than
caches. `pkf up <task>` starts every service in the target's
subgraph, blocks until Ctrl+C, then sends SIGTERM to each service's
*process group* (so `bash -c "node server.js"` does not leak its
node child) and escalates to SIGKILL after `shutdownTimeoutSeconds`
(default 5).

```pkl
local db: Task = new {
  name = "db"
  cmd = "exec postgres -D ./data"
  service = true
  shutdownTimeoutSeconds = 15
}

local api: Task = new {
  name = "api"
  // `until pg_isready ...` is a hand-rolled readiness wait. v1 of
  // `pkf up` starts every service simultaneously; dependent services
  // must retry until upstream is ready.
  cmd = """
    until pg_isready -q; do sleep 0.2; done
    exec node server.js
    """
  service = true
  deps { db }
}

tasks { db; api }
```

```sh
pkf up api               # starts db + api, blocks until Ctrl+C
pkf up --watch api       # also restarts both on a source save
```

Rules of thumb:

- **Use `exec`** in the `cmd` so the real binary replaces the shell
  and receives signals directly — gives one fewer pid in `ps` and
  clearer logs. The runner sets the cmd's process group regardless,
  so non-`exec` cmds still get reaped.
- **`pkf run` rejects services in v1.** The runner happily blocks
  forever, but `pkf up` is the supervisor that knows about the
  service lifecycle. Use `pkf run` for tasks that terminate.
- **Non-service tasks may not depend on services.** A `build`
  shouldn't `deps { db }` — that means "wait for db to finish",
  which a service never does. The reverse (`db` as a service that
  needs `migrate` to run first) is fine.
- **Cache is implicitly disabled** for service tasks — you never
  want to "skip" starting a server because its inputs haven't
  changed.

### Tests that need live servers (`services { ... }` on the task)

For one-shot commands that need backing services for the duration
of their `cmd` (e2e tests, smoke scripts, migration checks),
declare them via `services { ... }` on the body task instead of
running a separate `pkf up`:

```pkl
local e2e: Task = new {
  name = "e2e"
  cmd = """
    until curl -fsS http://localhost:3000/health >/dev/null; do sleep 0.2; done
    pnpm exec playwright test
    """
  inputs { "tests/**/*.ts" }
  cache = false
  services { api }   // api in turn declares services { db }
}
```

`pkf run e2e` brings up `api` (and recursively `api`'s own
services like `db`), runs the test cmd, then stops everything in
reverse order — same SIGTERM-grace-SIGKILL flow as `pkf up`.

`services { ... }` differs from `deps { ... }` along the
"finishing" axis: `deps { build }` waits for `build` to *exit
successfully* before this task starts; `services { db }` waits for
`db` to *start* (a service is never expected to exit) and keeps it
running for the duration. The two compose — the same task can
have both.

Recipe 09 has the full picture, including a Drizzle migration
check that uses just `services { db }` without `api`.

### Reuse vs spawn (`readyPort` / `readyCmd`)

A service with a readiness probe is *reused* when the probe
already passes:

```pkl
local db = new Task {
  name = "db"
  cmd = "exec postgres -D ./data"
  service = true
  readyPort = 5432
  readyTimeoutSeconds = 15
}
```

When `pkf run e2e` (or any task with `services { db }`) starts,
pkfire dials `localhost:5432` once. If the dial succeeds, db is
already up — typically because `pkf up dev` is running in another
shell, or you started postgres yourself. pkfire logs
`reusing existing service "db"`, skips the spawn, and skips the
teardown so the existing process keeps running after this run
finishes.

If the dial fails, pkfire spawns the cmd and then *polls* the
probe every 250ms for up to `readyTimeoutSeconds` before letting
dependent services or the body task proceed. Without a probe the
runner would race — the body would `pnpm exec playwright` against
a server that hasn't bound its port yet.

`readyCmd` covers the cases TCP can't:
`readyCmd = "pg_isready -h localhost"` (a port may be open before
postgres has finished crash-recovery), or `redis-cli ping`, or any
exit-0-when-ready shell snippet. `readyPort` and `readyCmd`
compose — set both and both must pass.

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

## Running pkfire in GitHub Actions

```yaml
jobs:
  ci:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: mizchi/pkfire@pkfire@0.3.0
      - run: pkf run ci
```

The `mizchi/pkfire` action is a setup-only composite that installs
the matching `pkf` binary plus the Pkl CLI on the runner
(`linux/darwin × amd64/arm64`) and adds them to `PATH`. After it
runs, the rest of the workflow uses `pkf` directly — no extra
tooling steps.

To share cache hits across CI runs and developer machines, point
`pkf` at a remote cache via env:

```yaml
      - uses: mizchi/pkfire@pkfire@0.3.0
      - run: pkf run ci
        env:
          PKFIRE_REMOTE_CACHE: ${{ vars.PKFIRE_REMOTE_CACHE }}
          PKFIRE_REMOTE_TOKEN: ${{ secrets.PKFIRE_REMOTE_TOKEN }}
```

Inputs:

| Input | Default | Notes |
| --- | --- | --- |
| `version` | inferred from `${{ github.action_ref }}`, falls back to latest release | Pin via `mizchi/pkfire@pkfire@0.3.0` to lock both the action.yml and the binary together. |
| `pkl-version` | `0.31.1` | Set to `none` to skip Pkl install (e.g. when only `pkf` is needed). |
| `install-dir` | `${{ runner.temp }}/pkfire-bin` | Both binaries land here, and the directory is appended to `GITHUB_PATH`. |
