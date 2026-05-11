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
sorted input file digests, the Pkl module's canonical form, **plus**
any resolved CLI params and tail args when the task is the invocation
target). Two invocations with the same key are guaranteed to produce
the same outputs (assuming honest `inputs` declarations).

Above the pure run-it-once DAG, pkfire grows three orthogonal layers:

- **`service: true` + `pkf up`** — long-running processes
  (databases, dev servers) with process-group cleanup, readiness
  probes, and reuse-or-spawn semantics.
- **`acceptsArgs` + `params { ... }`** — typed CLI input
  (`pkf run task --bump=minor -- file1 file2`) folded into the
  action key so different invocations cache as different entries.
- **`pkf hooks install` + `pkf affected`** — git-aware
  orchestration: convention-based hook installation and
  changed-files-driven plan computation.

Each layer is opt-in via a schema field or a CLI subcommand; the
base "one cached task per change" model is unchanged.

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
  inheritEnv: Boolean = true                      // false = hermetic (PATH/HOME/LANG/... only)
  acceptsArgs: Boolean = false                    // forwards `pkf run task -- a b` as $@
  params: Listing<Param> = new {}                 // typed --name=value flags (see below)
}

class Param {
  name: String                     // lower-case; exposed to cmd as $NAME (uppercased)
  type: "string"|"enum"|"int"|"bool"
  choices: Listing<String>         // enum only
  default: String?                 // null = required; "10" for int, "true"/"false" for bool
  description: String?
}
```

## Authoring template (always start from this)

```pkl
amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.5.0#/Taskfile.pkl"

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
| [`assets/recipes/10-args-passthrough.pkl`](./assets/recipes/10-args-passthrough.pkl) | `acceptsArgs = true`: forward `pkf run task -- a b` to `cmd` as `$@` |
| [`assets/recipes/11-named-params.pkl`](./assets/recipes/11-named-params.pkl) | Typed flags: `params { ... }` with enum validation, defaults, required params |
| [`assets/recipes/12-task-library.pkl`](./assets/recipes/12-task-library.pkl) | Library-author skeleton: `abstract module` + `extends` polymorphism, `allTasks` export, runtime dispatch, release-tag scheme |
| [`assets/recipes/13-git-hooks.pkl`](./assets/recipes/13-git-hooks.pkl) | `pkf hooks install`: tasks named after git events (`pre-commit`, `pre-push`, `commit-msg`) wired to `.git/hooks/<event>` shims |
| [`assets/recipes/14-secretlint-pre-push.pkl`](./assets/recipes/14-secretlint-pre-push.pkl) | secretlint as a `pkf run pre-push` task (scans the outgoing diff, not every commit) — drops the prek dep for the "secretlint-only" hook case |

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
amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.5.0#/Taskfile.pkl"
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

## Runtime args (`acceptsArgs` and `params`)

Tasks can take command-line input. Two shapes:

- **`acceptsArgs = true`** — positional tail args after `--` land on
  `$1`, `$2`, ... and `$@` (always quote: `"$@"`). The just analogue
  is `just run *ARGS`.
- **`params { Param ... }`** — typed named flags. The caller passes
  `pkf run <task> --<name>=<value>`; inside `cmd` the value is
  available as `$NAME` (uppercased). Four types:
  - `"string"`: any value.
  - `"enum"`: must match one of `choices`.
  - `"int"`: parsable as a signed decimal integer.
  - `"bool"`: `--flag` alone = true, `--flag=true|false` explicit.
    Bool params never consume the next token as a value, so
    `--watch --port=80` is unambiguous.
  `default = "..."` makes the flag optional (the string itself is
  validated against `type`); omitting `default` makes it required.

```pkl
local bumpVersion = new Task {
  name = "bump-version"
  cmd = "npm version $BUMP --no-git-tag-version"
  cache = false
  params {
    new { name = "bump"; type = "enum"; choices { "patch"; "minor"; "major" }; default = "patch" }
  }
}

local script = new Task {
  name = "script"
  cmd = "node \"$@\""
  acceptsArgs = true
  cache = false
}
```

```sh
pkf run bump-version --bump=minor      # validated, sets $BUMP
pkf run script -- src/main.ts arg1     # $@ = "src/main.ts arg1"
pkf run script --lang=ts -- src/main.ts arg1   # combined
```

Both forms participate in the action key when `cache = true`, so
different invocations produce different cache entries — convenient
for codegen-with-flags but typically you want `cache = false` for
generic command wrappers (vitest filters, single-file scripts).

The CLI rejects unknown flags and missing required params *before*
the cmd runs, so a typo like `--bump=mahor` fails fast with a clear
message.

## Environment inheritance (`inheritEnv`)

Default: `inheritEnv = true`. The cmd sees every var in pkfire's own
environment (same semantics as `just`/`make`/`npm run`), so
`SSH_AUTH_SOCK`, `GPG_AGENT_INFO`, your locale, editor preferences,
and developer tokens all pass through without ceremony.

Switch to `inheritEnv = false` for hermetic tasks (release builds,
reproducibility-sensitive CI steps). In that mode only a small
allowlist passes through (`PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`,
`TERM`, `TMPDIR`, `LANG`, `LC_ALL`, `LC_CTYPE`, `TZ`) — the pre-0.4
behavior.

In *both* modes the action key only hashes the `env { ... }`
declared in Pkl, never the host environment. So a `NODE_ENV` shift
in your shell never silently invalidates cache; if you want a host
var to affect caching, copy it into `env` explicitly:

```pkl
env { ["NODE_ENV"] = read("env:NODE_ENV") }
```

## Publishing a task library on top of pkfire

Several patterns recur when a project grows beyond one Taskfile and
becomes a *library of reusable tasks* — shared across repos, or
published as its own Pkl package on `pkg.pkl-lang.org` for other
projects to consume. The worked example is
[kawaz/pkf-tasks](https://github.com/kawaz/pkf-tasks); the patterns
below are extracted from its design records (DR-0001 … DR-0004).

### Package layout

```
my-task-lib/
├── PklProject              # name, version, dependencies { ["pkfire"] {...} }
├── PklProject.deps.json    # generated by `pkl project resolve`
└── tasks/                  # one .pkl module per "topic"
    ├── vcs/
    │   ├── iface.pkl       # abstract module
    │   ├── jj.pkl          # extends iface.pkl
    │   ├── git.pkl         # extends iface.pkl
    │   └── auto.pkl        # extends iface.pkl — runtime dispatch
    └── docs/translations.pkl
```

Consumers import:

```pkl
amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.5.0#/Taskfile.pkl"
import "package://pkg.pkl-lang.org/github.com/<you>/my-task-lib/my-task-lib@0.1.0#/vcs/auto.pkl" as vcs

tasks { ...vcs.allTasks }
```

### Polymorphic modules: `abstract module` + `extends`

When the same logical task has multiple implementations (jj vs git,
docker vs podman, npm vs pnpm), declare an `abstract module` with
abstract task properties, then `extends` it from each implementation.
**Use `extends`, not `amends`** — `amends` against an abstract module
fails with `Cannot instantiate abstract class`.

```pkl
// vcs/iface.pkl
@ModuleInfo { minPklVersion = "0.31.0" }
abstract module com.example.vcs.iface
import "@pkfire/Taskfile.pkl"

abstract commit: Taskfile.Task
abstract push: Taskfile.Task

allTasks: Listing<Taskfile.Task> = new { commit; push }
```

```pkl
// vcs/jj.pkl
module com.example.vcs.jj
extends "iface.pkl"
import "@pkfire/Taskfile.pkl"

commit = new Taskfile.Task { name = "vcs:commit"; cmd = "jj describe ..." }
push   = new Taskfile.Task { name = "vcs:push";   cmd = "jj git push" }
```

The abstract property list acts as the interface contract: every
implementation must fill in every abstract entry, enforced at Pkl
evaluation time.

### Field-level override: `(base) { cmd = ...; description = ... }`

To inherit one task's structure (params, env, cache, shell, ...) and
only override specific fields, use Pkl's object-amends syntax:

```pkl
// auto.pkl picks one impl as the base and overrides cmd:
commit = (jj.commit) {
  description = "vcs commit (auto-detect: jj or git)"
  cmd = autoCmd(jj.commit.cmd, git.commit.cmd)
}
```

`(jj.commit) { ... }` returns a new Task with the listed fields
replaced and everything else (`params`, `env`, `cache`, ...) inherited.
Cleaner than rebuilding a Task from scratch when only the cmd differs.

### Runtime dispatch (Pkl can't see CWD)

Pkl evaluation is intentionally hermetic — it cannot read the working
directory's filesystem state. `read("file:.jj")` is a syntax error
(file URIs must be absolute), and absolute paths can't be portable
across consumers. So "detect what the user is running on" must happen
**at task execution time, inside the cmd**:

```pkl
// auto.pkl
local function autoCmd(jjCmd: String, gitCmd: String): String = """
  if jj root >/dev/null 2>&1; then
  \(indent(jjCmd))
  elif git rev-parse --git-dir >/dev/null 2>&1; then
  \(indent(gitCmd))
  else
    echo "vcs: no jj or git repository found" >&2; exit 1
  fi
  """
```

Use the underlying tool's own ancestor-search (`jj root`,
`git rev-parse --git-dir`, `npm prefix`, `cargo locate-project`)
instead of `[ -d .jj ]` style cwd-only checks — the latter break
when invoked from a sub-directory of the workspace.

### Conventions worth following

- **`name = "<scope>:<action>"`** — namespace tasks by domain (`vcs:commit`,
  `docs:check-translations`, `lint:pkl`). The schema's name regex
  allows `:` and `/`, so `lint:rust/fmt` is also fine. Avoids collision
  with the consumer's own task names.
- **`allTasks: Listing<Task>` at module level** — let consumers do
  `tasks { ...mod.allTasks }` instead of listing each task by name.
  Keeps the consumer's Taskfile small and lets you add new tasks in
  the library without every consumer updating their import line.
- **Avoid `read("env:X")` for ergonomics-only env vars.** It fails
  with "resource not found" when `X` is unset, breaking eval in
  environments (CI containers, sandboxes) that don't have your
  developer-machine env. Rely on `inheritEnv = true` (the default)
  for `SSH_AUTH_SOCK`, `GPG_AGENT_INFO`, locale, etc. Use `read()`
  only when the value *should* be part of the action key (a release
  channel, a git SHA, a `NODE_ENV` you want to cache against).
- **Pin pkfire as a dependency, not via `amends` to a URL.** Library
  authors should declare pkfire in their `PklProject.dependencies`
  and reference it as `@pkfire/Taskfile.pkl` — that way the consumer
  gets a single Pkl package graph and `pkl project resolve` keeps
  things consistent.

### Releasing the library

Mirror pkfire's tag scheme: `<name>@<version>` as the release tag,
because `packageZipUrl` in `PklProject` expects that shape. Once
v0.1.0 of your package ships, the major-only pin (`@<name>@1`) becomes
resolvable by Pkl's package resolver. Stay exact-pinned during 0.0.x.

### CI cache for Pkl downloads

Pkl caches resolved packages under `~/.pkl/cache`. Add this to any
workflow that runs `pkl project resolve` or evaluates remote Pkl
packages — first-run network cost stays in the cache instead of
hitting `pkg.pkl-lang.org` on every CI run:

```yaml
- uses: actions/cache@v4
  with:
    path: ~/.pkl/cache
    key: pkl-cache-${{ hashFiles('**/PklProject.deps.json') }}
    restore-keys: pkl-cache-
- uses: mizchi/pkfire@v0.5.0
- run: pkl project resolve
```

## Git hooks (`pkf hooks install`)

`pkf hooks install` is a thin opt-in convenience: any task whose
`name` matches a git client-side hook event (`pre-commit`,
`pre-push`, `commit-msg`, `prepare-commit-msg`, `post-commit`,
`post-checkout`, `post-merge`, `pre-rebase`, `post-rewrite`)
becomes installable. The install step writes
`.git/hooks/<event>` as a 3-line shim:

```sh
#!/bin/sh
# managed by pkf hooks install
exec pkf run pre-commit -- "$@"
```

The trailing `-- "$@"` forwards git's per-hook args. `commit-msg`
receives the message-file path as `$1` (your task should declare
`acceptsArgs = true` to receive it inside `cmd`); `pre-push` gets
the remote name and URL; etc. See `git help githooks` for the per-
event arg list.

```sh
pkf hooks install         # write shims for every matching task
pkf hooks install --force # also replace hand-written or other-tool hooks
pkf hooks list            # report which events have tasks + which are installed
pkf hooks uninstall       # remove only pkfire-managed shims
```

The shim is marked with a comment so uninstall and reinstall are
idempotent and *will not* touch hooks installed by other tools
(husky, lefthook, hk, etc.) unless you pass `--force`.

### Auto-install on `cd` (direnv)

`pkf hooks install` is **silent on no-op**: when every matching
shim is already present and bit-identical to what pkfire would
write, the command produces no output. That makes it safe to drop
into `.envrc` so the hooks always get re-installed (and
re-aligned to the current Taskfile) the first time you `cd` into
the repo on a fresh checkout:

```sh
# .envrc
if command -v pkf >/dev/null; then
  pkf hooks install
fi
```

The first `direnv reload` after the Taskfile changes writes a line
to stdout. Every subsequent reload is quiet. File writes go
through tempfile + rename so a concurrent reload (two terminals
hitting `cd` at the same moment) won't tear the shim.

### Rules of thumb

- **`cache = false` on every hook task.** Hooks fire on a tree that
  shifts every commit; the action key (which is keyed on declared
  `inputs`) is not a meaningful cache for "did the staged set
  change". Set `cache = false` explicitly. pkfire warns when an
  installable hook task has `cache = true`.
- **Don't reuse the same task name for the hook target and the
  underlying gate.** Declare a thin `pre-commit` task that
  `deps { lint; typecheck }` instead of inlining everything — it
  keeps the hooks layer (config: which event → which task)
  separable from the gate logic.
- **Staged-file scoping happens in `cmd`, not in `inputs`.**
  pkfire does not currently inject a `$STAGED_FILES` env or filter
  `inputs` to the staged subset. If you want lint-only-staged-files
  behavior, write `git diff --cached --name-only` inside the `cmd`
  and feed the result to your linter. Recipe 13 shows the pattern.

### Relationship to hk / lefthook / pre-commit

[hk](https://hk.jdx.dev/) (by the mise author) is a purpose-built
git-hook manager configured in Pkl. It has features pkfire
deliberately doesn't: staged-file globs with `{{files}}`
templating, separate `check` vs `fix` commands, exclusive locks,
file-set scoping, fail-fast. If you need those, **use hk** and
have its steps shell out to `pkf run <task>` for the actual work —
the two compose cleanly.

`pkf hooks install` exists for the case where the project already
runs everything through pkfire and a single `pkf run pre-commit`
is enough; adding a second config tool just to dispatch a hook is
overhead. Same logic for [lefthook](https://github.com/evilmartians/lefthook)
and [pre-commit](https://pre-commit.com/) — pkfire's built-in is
the dependency-light path; the dedicated managers are the
feature-rich path.

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

## Selective execution

Real workflows rarely "run every task". A few patterns cover the
common selection questions:

```sh
pkf run                        # no args → the task named `default` (errors clearly when absent)
pkf run a b c                  # multi-target: topological union of all subgraphs
pkf run --refresh build        # skip cache lookup but re-store result (re-baseline)
pkf run --no-cache test        # skip lookup AND store for this run
```

**Monorepo CI: `pkf affected --since=<ref>`.** Runs only the tasks
whose declared `inputs` glob matches a file in the asymmetric diff
`<since>...HEAD`, plus their transitive *dependents* in the deps
DAG. The unaffected deps that come along in the plan hit cache, so
the actual work is minimal.

```sh
pkf affected --since=origin/main           # everything affected by the PR
pkf affected --since=origin/main test:unit # filter to specific targets (exact names)
pkf affected --since=HEAD~1 --dry-run      # preview without running
```

Default `--since` chain: `origin/main` → `origin/master` → `HEAD~1`.
Tasks with empty `inputs` are never affected by file changes (they
explicitly declared no file dependencies). Tasks with `cache = false`
are still subject to the same affected-set test — they don't get
auto-pulled in just because they're always-run.

## CLI tools

### Inspection (read-only)

```sh
pkf list                       # one task per line + description
pkf list -v                    # cmd preview + deps + cache status
pkf list --json                # machine-readable; for editor / CI tooling
pkf graph                      # Graphviz DOT
pkf graph --format mermaid     # GitHub-renderable
pkf graph --target build       # only the subgraph rooted at `build`
pkf doctor                     # diagnose pkl / cache / remote / Taskfile setup
```

### Execution preview

```sh
pkf run --dry-run build        # table: per-task hit/will-run/uncached + action key + cmd
pkf run --print-hash build     # raw action keys for the subgraph
pkf run --no-cache --dry-run build   # "what would --refresh re-run?" introspection
```

The `--dry-run` table classifies each task as `hit` (cache will
short-circuit), `will run` (cacheable but no entry), `uncached`
(`cache = false`), or `service` (skipped by `pkf run` — preview
only). With `--no-cache` / `--refresh`, the lookup is inert so
every cacheable task shows `will run`. Remote cache is NOT
consulted during dry-run to keep it fast.

### Execution

```sh
pkf run build                  # run + cache as usual
pkf run --watch build          # re-run on input change (Ctrl+C to stop)
pkf run -j 8 build             # cap parallelism (default: NumCPU)
pkf run --timing build         # add per-task duration breakdown at the end
pkf up dev                     # supervise every `service: true` task in the subgraph
pkf up --watch dev             # plus restart-on-change
```

After every non-watch run, pkfire prints a single summary line:

```
[pkf] done: 6 tasks · 3 hit · 3 ran · 2 uncached (11.3s wall, 12.0s CPU)
```

`--timing` follows with a table sorted by duration descending —
pinpoints the slow task without a profiler.

### Maintenance / hooks

```sh
pkf format                     # pkl format -w (defaults to Taskfile's dir)
pkf format --check pkl examples skills  # exit 11 on unformatted (CI-friendly)
pkf hooks install              # write .git/hooks/<event> shims for hook-named tasks
pkf hooks list                 # show which events are wired
pkf hooks uninstall            # remove only pkfire-managed shims
pkf init                       # write a starter Taskfile.pkl
```

`pkf hooks install` is silent on no-op, so it's safe in `.envrc`
— see the [Git hooks](#git-hooks-pkf-hooks-install) section.

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
      - uses: actions/checkout@v5
      - uses: mizchi/pkfire@v0.5.0      # or @v0 to track latest 0.x
      - run: pkf run ci
```

The `mizchi/pkfire` action is a setup-only composite that installs
the matching `pkf` binary plus the Pkl CLI on the runner
(`linux/darwin × amd64/arm64`) and adds them to `PATH`. After it
runs, the rest of the workflow uses `pkf` directly — no extra
tooling steps.

**Do not write `uses: mizchi/pkfire@pkfire@0.5.0`.** GHA's parser
treats the `@` in the ref as a syntax break and fails the *whole
workflow file*, with no jobs run and a generic "workflow file
issue" error. Pkl release tags happen to be `pkfire@<ver>` (because
the package URI requires it), so the Release workflow also pushes
`v<ver>` + a floating `v<major>` tag at the same commit — use
those for `uses:`. Or SHA-pin: `uses: mizchi/pkfire@<sha> # v0.5.0`.

To share cache hits across CI runs and developer machines, point
`pkf` at a remote cache via env:

```yaml
      - uses: mizchi/pkfire@v0.5.0
      - run: pkf run ci
        env:
          PKFIRE_REMOTE_CACHE: ${{ vars.PKFIRE_REMOTE_CACHE }}
          PKFIRE_REMOTE_TOKEN: ${{ secrets.PKFIRE_REMOTE_TOKEN }}
```

Inputs:

| Input | Default | Notes |
| --- | --- | --- |
| `version` | inferred from `${{ github.action_ref }}`, falls back to latest release | Accepts `v0.5.0`, `0.4.0`, `v0` (floating major), or the underlying `pkfire@0.5.0`. Pinning via `uses: mizchi/pkfire@v0.5.0` is the recommended form. |
| `pkl-version` | `0.31.1` | Set to `none` to skip Pkl install (e.g. when only `pkf` is needed). |
| `install-dir` | `${{ runner.temp }}/pkfire-bin` | Both binaries land here, and the directory is appended to `GITHUB_PATH`. |
