# pkf runtime contract

This reference describes observable behavior of the pure-MoonBit
`pkf 0.14.0` implementation.

## Discovery and evaluation

Without `-f/--file`, pkf walks from the current directory toward the
filesystem root and selects the nearest `Taskfile.pkl`. A leading
explicit file flag disables walk-up.

The embedded `mizchi/pkl` loader evaluates the Taskfile and resolves
local, cached and remote `package://`, HTTP(S), and glob-import modules.
It extracts `output.value`, renders it as JSON, and parses the plan.
Normal `run`, `list`, `graph`, `affected`, `watch`, and `up`
do not shell out to `pkl eval`.

## DAG execution

`run <task>` performs a depth-first topological sort over the target's
transitive `deps`, then over the artifact edges analysis derives on
top of them (see "Action graph"):

- dependencies execute before their dependent;
- a task executes after the tasks producing the files it reads;
- a shared dependency executes once;
- cycles fail before execution;
- unknown tasks fail with nearby-name suggestions;
- the plan is sequential;
- the first non-zero command ends the run with that exit code, unless
  `--keep-going`;
- a task with an empty rendered command succeeds without spawning.

Only the explicit target receives named CLI values and tail arguments.
Dependencies resolve param defaults and receive no positionals.

Ordinary commands execute as:

```text
<shell> <shellFlags...> <cmd>
```

The task environment is `defaults.env`, overlaid by task `env`, then
resolved params under uppercase names. `inheritEnv` controls ambient
process inheritance. Relative regular-task `workdir` values resolve
from the Taskfile directory.

## Input matching and affected plans

Globs support literal segments, `?`, `*`, `**`, character classes,
and brace alternation. Matching input paths are sorted before hashing.
A missing literal or unmatched pattern contributes no file and is not
an error.

Affected computation is:

1. Directly select tasks whose `inputs` match any changed path.
2. Add transitive dependents over reverse `deps` edges.
3. Add every selected task's transitive dependencies.
4. Emit a dependency-before-dependent topological plan.

Tasks with empty `inputs` are never direct matches. `cache = false`
does not make a task automatically affected.

`watch` runs the same affected computation for filesystem events and
skips service tasks. It does not re-evaluate the Taskfile after each
event; restart watch after changing task definitions.

## Action key

For a cacheable task, pkf lowers the task into an *action descriptor*
and takes SHA-256 over its canonical serialization. Every field of the
descriptor is part of the key; there is no separate list of hashed
values to keep in sync with it.

```text
mnemonic              always "SpawnAction" today
executable            the shell
argv                  shell flags, cmd, forwarded positionals
env                   defaults.env + task.env + params, merged and sorted
inheritEnv            the flag itself
inputs                (path relative to the action root, file sha256)
consumedArtifacts     (repo-relative path, file sha256) for files
                      produced by tasks this one depends on
outputs               declared output patterns, sorted
workingDirectory      normalized `workdir`
executionPlatform     <os>/<arch>
executionProperties   tool versions, param values, --profile
```

The serialization is length-prefixed, so text inside a `cmd` cannot
forge a neighbouring field. `pkf run --explain-cache <task>` prints
the descriptor; a miss is always one of its lines differing from last
time.

The key excludes:

- the Taskfile source or canonical Pkl module;
- dependency action keys (the dependency's *outputs* are hashed
  instead, as `consumedArtifacts`);
- ambient environment variables, when `inheritEnv = true` — the flag
  is hashed, its effect is not;
- description, visibility, and service metadata.

Consequences:

- A dependency's outputs already reach the consumer's key; listing
  them in `inputs` as well is not required for correctness, only for
  affected/watch matching.
- Copy output-affecting host variables into task `env`.
- Set `cache = false` for nondeterministic or side-effect-only work.
- Changing only a task description does not invalidate cache.

## Action graph

`pkf run` lowers the requested targets into an action graph before
executing anything. Nodes are actions (one per task today); edges come
from declared `deps` and from artifacts — a task whose `inputs` reach
into another task's declared `outputs` is scheduled after it, and that
producer's outputs are hashed into its key.

Inference orders and keys the tasks a run already contains; it never
adds a task to the run. `pkf run consumer` executes only `consumer`
even when another task produces what it reads. `pkf lint` reports that
case as `undeclared-artifact-dep`.

A cycle over declared and derived edges is reported before any task
runs, naming each edge's reason. A task does not consume its own
outputs, so a formatter that rewrites what it reads is not a cycle.

## Local cache

The cache root is selected in this order:

1. `PKFIRE_MBT_CACHE_DIR`
2. `$XDG_CACHE_HOME/pkfire-mbt`
3. `$HOME/.cache/pkfire-mbt`
4. `.pkfire-mbt-cache`

Entries live under:

```text
<root>/cas/<first-two-key-chars>/<remaining-key>/entry.tar.gz
```

On hit, the gzip-compressed tar is restored into the Taskfile directory.
After a successful miss, pkf expands existing `outputs`, archives
regular files and recursive directory contents, preserves file modes
best-effort, and writes the entry.

Known `0.14.0` implementation gap: `cache_store` writes only
`entry.tar.gz`, while `cache_hit` still tests for a legacy `manifest`
file. A newly stored local entry is visible to `cache stats` but is not
recognized as a hit. A remote GET can still restore an archive, but the
next invocation consults the remote again. Treat local reuse as broken
until the hit check and archive layout are reconciled.

Current path caveat: cache input/output expansion is rooted at the
Taskfile directory even when `workdir` is set. `clean` instead joins
outputs to `workdir`. Until those behaviors converge, prefer
Taskfile-relative input/output paths and make subdirectory paths
explicit.

## Remote cache

Configure:

```sh
PKFIRE_MBT_REMOTE_CACHE=https://cache.example
PKFIRE_MBT_REMOTE_TOKEN=optional-bearer-token
```

The wire object is:

```text
GET|PUT <base>/cas/<first-two>/<remaining>/entry.tar.gz
Authorization: Bearer <token>
```

A remote hit warms the local CAS and restores outputs. A successful
local execution stores locally, then uploads best-effort. Remote GET
misses and network failures fall back to execution; PUT failure is
logged and does not fail the task.

Do not configure the legacy `PKFIRE_REMOTE_CACHE` or
`PKFIRE_REMOTE_TOKEN` names for this version.

## Params and args

The invocation grammar is:

```sh
pkf run <task> [--name=value | --bool-flag]... [-- positional...]
```

Declared params validate `string`, `enum`, `int`, and `bool`.
Missing required params fail. A bare named flag resolves to `"true"`.
The current parser ignores provided names that the target did not
declare; do not rely on unknown-flag rejection.

When `acceptsArgs = true`, pkf invokes a POSIX-style shell so the task
name occupies `$0` and user positionals occupy `$1...$@`. Quote
`"$@"` in commands.

Params and positionals are part of the target action key.

## Services

`up [service...]` starts authored service tasks in Taskfile order,
waits for readiness, remains in the foreground, and shuts them down in
reverse order on SIGINT/SIGTERM.

A terminating task's `services { ... }` are started before its command
and always stopped afterward. Cache lookup happens first, so a body-task
cache hit does not start services.

Readiness:

- `readyPort > 0` probes `127.0.0.1:<port>`.
- An already-open port reuses an external service and skips teardown.
- `readyCmd` is run until it exits zero.
- When both are set, both must pass.
- Probes poll every 100 ms until `readyTimeoutSeconds`.

Shutdown targets the spawned process tree with SIGTERM, waits
`shutdownTimeoutSeconds`, then sends SIGKILL.

Current limitations:

- Service dependencies are not recursively expanded from
  `services`; list every required service on the body task.
- `up` uses authored service order rather than a dependency topology.
- A relative service `workdir` is passed directly to process spawning,
  unlike ordinary tasks' Taskfile-relative resolution. Prefer no
  service `workdir`, an absolute path, or an explicit `cd` in `cmd`.
- Only a target explicitly marked as a service is rejected by
  `run`; keep services out of `deps` to avoid blocking execution.

## Git hooks

`hooks install` recognizes standard client-side event names such as
`pre-commit`, `pre-push`, and `commit-msg`. It writes:

```sh
#!/bin/sh
# managed by pkf hooks install
exec pkf run <event> -- "$@"
```

Installation is idempotent. Non-pkfire hooks are preserved unless
`--force` is used. Uninstall removes only marked shims. Hook tasks
should set `cache = false`; use `acceptsArgs = true` when the Git
event supplies positional arguments.
