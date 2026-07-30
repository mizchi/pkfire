---
name: pkfire
description: Explain, operate, and troubleshoot `pkf`, the pure-MoonBit CLI for the pkfire typed task runner, and author or maintain its `Taskfile.pkl` files. Use when a user asks what pkf is, wants to inspect or run a task graph, add cached tasks or services, model affected-file workflows, migrate from just/Make/Taskfile.yml, diagnose Pkl package or cache behavior, or change pkfire itself. This skill distinguishes the current MoonBit implementation from stale Go-era documentation and records the exact schema, action-key, service, and CLI contracts.
---

# pkf executable specification

## Version and authority

Treat this skill as the operational specification for `pkf 0.14.0`.
Start by running `pkf version`; when the installed version differs,
inspect that checkout's sources before relying on version-sensitive
details.

Resolve conflicts in this order:

1. `pkl/Taskfile.pkl` defines the authored and rendered Pkl contract.
2. `src/cmd/pkf/main.mbt` defines CLI and runtime behavior.
3. MoonBit tests and `conformance/` define observable compatibility.
4. This skill and `README.md` explain the behavior.

If a lower-priority document contradicts code or conformance, follow
the implementation and update the document. Do not infer current
behavior from Go-era comments, shell completions, or release recipes.

Read the detailed references only when needed:

- [Schema contract](./references/schema.md): every Pkl type and field,
  rendered envelope, templates, and authoring invariants.
- [Runtime contract](./references/runtime.md): evaluation, DAG ordering,
  SHA-256 action keys, local/remote cache, services, args, and affected
  workflows.
- [CLI contract](./references/cli.md): the currently implemented command
  and flag surface, including accepted no-ops and legacy-only flags.

## Product model

`pkfire` is the project and Pkl schema; `pkf` is its command-line
program. A Taskfile is typed configuration, not a shell-script parser.

```text
Taskfile.pkl
  -> embedded Pkl evaluation
  -> output.value { defaults, taskOrder, tasks, workflowTests }
  -> dependency DAG
  -> sequential task execution
  -> local CAS, then optional HTTP remote cache
```

Normal Taskfile evaluation is in-process through `mizchi/pkl`. Local
files, cached and remote `package://` modules, HTTP(S) modules, and
glob imports are resolved by the embedded loader. The external `pkl`
binary is still used by `format`, migration verification, and
`pkl-cache warm`.

## Authoring invariants

Enforce these rules:

1. Amend the version-pinned pkfire schema.
2. Declare each task as a `local` `Task` value.
3. Add every authored task to the module-level `tasks { ... }`.
4. Put actual Task references in `deps` and `services`, never names.
5. Give every task a unique `name`.
6. Declare all files that affect deterministic output in `inputs`.
7. Declare restorable artifacts in `outputs`, or set `cache = false`.
8. Use `deps` for work that must finish; use `services` for processes
   that must stay alive while a body task runs.

The two mistakes to check first are an unlisted local task and a string
dependency. Pkl's `amends` semantics cannot auto-collect arbitrary
top-level properties.

Start from:

```pkl
amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.14.0#/Taskfile.pkl"

local sources: Listing<String> = new {
  "src/**/*.mbt"
  "moon.mod"
}

local build: Task = new {
  name = "build"
  description = "Build the native binary"
  cmd = "moon build --target native"
  inputs = sources
  outputs { "_build/native/debug/build/main/main.exe" }
}

local test: Task = new {
  name = "test"
  cmd = "moon test"
  inputs = sources
  deps { build }
  cache = false
}

tasks { build; test }
```

Prefer a single Taskfile until its ownership or size creates real pain.
For split files, export typed `Listing<Task>` values and spread them
from one root Taskfile. Use hierarchical `amends` only when directory
ownership itself is part of the design.

## Execution contract

`pkf` walks upward from the current directory to find the nearest
`Taskfile.pkl`, unless a leading `-f/--file` is provided. Relative
task `workdir` values for ordinary commands resolve from the Taskfile
directory.

`pkf run <task>` topologically orders that task and its transitive
`deps`, detects cycles, and runs dependencies before the target. The
current MoonBit runner executes this plan sequentially and stops at the
first non-zero exit. A task with no `cmd` is a deps-only umbrella.

Named `params` become uppercase environment variables. Positional
arguments are forwarded as `$1...$@` only when `acceptsArgs = true`.
Only the explicitly requested target receives CLI params and positional
args; dependencies resolve their defaults.

## Cache contract

The current action key is SHA-256 over this ordered canonical feed:

1. `cmd` and `shell`
2. indexed `shellFlags`
3. sorted task `env`
4. sorted `tools`
5. sorted matched input paths and each file's SHA-256
6. sorted resolved target params
7. indexed positional args

Do not describe the current key as BLAKE3. It does not include the Pkl
module's canonical form, dependency keys, `defaults.env`, ambient
environment, `workdir`, or output paths. If a dependency artifact
affects a task, declare that artifact as an input to the dependent task.

Missing literal inputs match zero files and do not fail. On a local hit,
`pkf` restores an `entry.tar.gz` from the CAS. On a miss it may fetch
the same archive from the remote cache, run the command, store existing
declared outputs locally, and best-effort PUT the archive remotely.

Use the current environment names:

```sh
export PKFIRE_MBT_CACHE_DIR=/custom/cache
export PKFIRE_MBT_REMOTE_CACHE=https://cache.example
export PKFIRE_MBT_REMOTE_TOKEN=secret
```

The default root is `$XDG_CACHE_HOME/pkfire-mbt` or
`$HOME/.cache/pkfire-mbt`. Names without `_MBT_` belong to the older
implementation and are not read by `pkf 0.14.0`.

## Services

Declare long-running tasks with `service = true`. Start them explicitly
with `pkf up [service...]`, or attach them to a terminating task:

```pkl
local api: Task = new {
  name = "api"
  cmd = "exec node server.js"
  service = true
  readyPort = 3000
  shutdownTimeoutSeconds = 5
}

local e2e: Task = new {
  name = "e2e"
  cmd = "pnpm exec playwright test"
  services { api }
  cache = false
}

tasks { api; e2e }
```

`readyPort` and `readyCmd` must both pass when both are configured.
An already-open `readyPort` causes reuse without spawn or teardown.
Spawned services are stopped in reverse order with SIGTERM, then
SIGKILL after the grace period.

Do not put a live service in `deps`; use `services`. The current
implementation does not recursively start a service's own
`services` closure.

## Current command surface

Use only the implemented surface below; see the [CLI contract](./references/cli.md)
before generating flags:

```sh
pkf version
pkf list [-v|--verbose] [--all] [--json]
pkf graph [--all] [--json]
pkf info [--all] [--json]
pkf describe [--json] <task>
pkf explain <task>
pkf run <task> [--param=value] [-- positional...]
pkf affected <path>...
pkf affected --changed=<newline-file>
pkf affected --check
pkf watch [task...]
pkf up [service...]
pkf clean [task-or-glob...]
pkf lint [--json]
pkf doctor [--json]
pkf format [--check] [path...]
pkf migrate --to=<version> [--dry-run] [--skip-verify]
pkf hooks <install|uninstall|list> [--force]
pkf cache <stats|prune|rm|clear>
pkf pkl-cache [warm] [path...]
pkf completion <bash|zsh|fish>
pkf init
```

### Version-sensitive limitations

For `0.14.0`, do not claim or generate these older interfaces:

- `pkf run` has no default target, multi-target mode, `--dry-run`,
  `--print-hash`, `--no-cache`, `--refresh`, `--timing`,
  `--remote-only`, or `-j/--jobs`.
- `pkf affected` has no `--since`, `--files`, `--explain`,
  target execution, or dry-run mode; it prints the computed plan.
- `pkf list` has no `--long`, `--unsorted`, or color flag.
- `pkf graph` has no format or target selector.
- `pkf lint --fix/--dry-run`, `pkf explain --diff`, and
  `pkf clean --dry-run` are accepted compatibility no-ops.
  In particular, `clean --dry-run` still removes outputs.
- The local store writes `entry.tar.gz`, but the `0.14.0` hit check still
  looks for the removed `manifest` marker. Newly stored entries therefore
  appear in cache statistics but are not reused as local hits. Do not
  promise working local reuse until that implementation gap is fixed.
- Undeclared named flags passed to `pkf run` are currently ignored.
  Validate the task's declared params instead of relying on unknown-flag
  rejection.
- `specRef` is accepted and rendered by the Pkl schema, but the current
  MoonBit plan parser does not surface it through CLI output.

## Agent workflow

Follow exploration, Red, Green, Refactoring:

1. Run `pkf version`, `pkf info --json`, `pkf list -v`, and
   `pkf graph --json` to inspect the actual project.
2. Reproduce an error or add a `workflowTests` case before changing
   `inputs`, `deps`, or affected behavior.
3. Make the smallest typed Taskfile change.
4. Run `pkl eval Taskfile.pkl`, `pkf lint`, and
   `pkf affected --check`.
5. Run the changed task, then rerun it when cache behavior is part of
   the contract.
6. Run `pkf format --check`.

When changing pkfire itself, also run:

```sh
pkf run preflight
pkf run conformance
```

Treat recipes under `assets/recipes/` as starting material, not as
normative CLI documentation. Load only the recipe matching the user's
task and validate every referenced command against the current CLI
contract before copying it.
