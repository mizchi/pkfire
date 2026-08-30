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
- the plan is sequential unless `-j N` raises the limit;
- the first non-zero command ends the run with that exit code; with
  `--keep-going` independent actions keep running and the ones
  downstream of the failure are reported as skipped;
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

## Run summary

Every `pkf run` ends with one line: total tasks, how many were cache
hits (remote counted separately), how many ran, how many were skipped
after a failure, and the wall clock. A fully cached run says
`(nothing to rebuild)`.

Deps-only umbrella tasks are not counted — they spawn nothing.
`--quiet` suppresses the line; `--dry-run` and `--print-hash` omit it
because nothing was executed.

## Scheduling

`pkf run -j N` runs up to N actions concurrently, `-j auto` one per
available CPU (capped at 16); the default is 1. An action starts only
when every action it depends on has finished, so `-j` changes when work
happens, never what depends on what. Among ready actions the one
earliest in the topological order goes first, which makes `-j 1`
identical to the sequential walk and any `-j` reproducible.

A failure stops scheduling but does not cancel actions already
running. With `N > 1` each action's output is captured and printed as
a block on completion instead of streamed, so a task that expects a
terminal sees a pipe. Services are not deduplicated across concurrent
actions.

`--timing` reports per-action durations, the wall clock, and the
critical path — the longest chain of actions the graph required to run
in sequence.

## Sandboxing

`pkf run --sandbox` materializes an action's declared inputs, and the
outputs of the actions it depends on, into a tree mirroring the repo,
and runs the command there. Inputs are symlinked, so absolute paths —
the toolchain, `$HOME` — still resolve; what the sandbox removes is
access to undeclared *workspace* files.

- an undeclared read finds nothing, so the command fails;
- declared outputs are moved back into the workspace on success;
- a failed action produces nothing: partial outputs stay in the
  sandbox;
- an undeclared write is reported and discarded;
- a task with no declared `inputs` runs unsandboxed (nothing to
  constrain), as does one whose `workdir` resolves outside the repo.

`hermetic = true` on a Task is the per-task, checked-in form: it turns
the sandbox on for that task without the flag, and additionally drops
the ambient environment whatever `inheritEnv` says. The descriptor
records the effective `inheritEnv` (false) and carries `hermetic` as an
execution property, so a hermetic and a non-hermetic run of the same
task never share a cache entry — the second may have been computed
from a file the first cannot see.

`--sandbox` alone does not change the key: it is how you find out
whether a task's `inputs` are honest before committing to the field.

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

The entry also carries the run's stdout and stderr under a reserved
`.pkf-meta/` prefix, capped at 1 MiB per stream. A restore hands those
members to the runner and never writes them into the workspace; the
hit line becomes `# name (cache hit <key>, replaying logs)` and the
stored streams are printed verbatim. A task that printed nothing keeps
the plain hit line. Declaring an output under `.pkf-meta/` is rejected
at load time — it would be stored and then dropped on every hit.

Capture uses pipes, so a cached task's command does not see a terminal
and colour-on-tty detection turns colour off. Uncacheable tasks
(`cache = false`, empty `inputs`, `--no-cache`) are unaffected, and
sequential output is still forwarded as it arrives rather than buffered
to the end.

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
