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

## Execution log

`--execution-log=FILE` writes a JSON Lines record of the run: one
`{"kind":"action"}` object per action in completion order, then one
`{"kind":"summary"}` object.

Action fields: `task`, `status`, `startMs`, `durationMs`. `status` is
`ran`, `cached-local`, `cached-remote`, `umbrella`, `reported` (under
`--dry-run` / `--print-hash`) or `skipped`. `exitCode` is present only
for `ran`; `blockedBy` only for `skipped`, naming the action that
stopped it.

Summary fields: `version` (schema, currently `1`), `exitCode`,
`wallMs`, `actions`, `ran`, `cached`, `skipped`, and — when the chain is
longer than one action — `criticalPathMs` and `criticalPath`. The
critical path lives here because the log records no edges, so it cannot
be recomputed from the action lines.

The flag is a run-level concern like `--keep-going` and `-j`: it is not
part of any action key, so adding it never invalidates a cache entry.
An unwritable path is reported on stderr and leaves the exit code
alone.

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

## Toolchains

`toolchains` is resolved at key time; `tools` is a self-reported string
and only as accurate as the last edit.

```pkl
toolchains {
  new Toolchain { name = "go" }                        // `go --version`
  new Toolchain { name = "protoc"; versionCmd = "..." }
  new Toolchain { name = "cc"; hashBinary = true }
  new Toolchain { name = "shellcheck"; optional = true }
}
```

Resolution runs `command -v <name>` in the task's shell, then the
version command (default `<name> --version`), taking the first
non-empty line of stdout, or of stderr when stdout is empty.

Execution properties produced:

- `toolchain.<name>.version` — the version line, or `unknown` when the
  tool is present but the version command failed.
- `toolchain.<name>.digest` — only with `hashBinary = true`.
- `toolchain.<name>` = `absent` — only for a missing `optional` tool.

`forTarget` maps a `targetPlatform` to the executable to resolve
instead of `name`; a target with no entry falls back to `name`, so a
native build's key is unchanged by its presence. The selection is
recorded as `toolchain.<name>.selected` only when it differs from
`name`, the default version probe follows the selection
(`aarch64-linux-gnu-gcc --version`, not `cc --version`), and the memo
is keyed on the selected executable so one declaration resolving to two
compilers does not share a slot.

The resolved **path is never hashed** — two prefixes for the same
compiler must still share remote cache entries — and is reported by
`pkf explain`. A missing non-optional toolchain is fatal at key time.
Resolutions are memoized per process by (name, versionCmd, hashBinary).

`targetPlatform` is a descriptor field of its own, distinct from the
observed `executionPlatform`; null means "builds for the machine it
runs on".

## Configuration transitions

`targetPlatform` propagates down the graph before a run starts, over
the same edges the action graph has — declared `deps` and the artifact
edges derived from what a task reads. A dependency of a cross build is
part of that cross build: it keys for the target, and its `toolchains`
resolve for the target.

- Only a **declared** `targetPlatform` transitions anything. A task
  without one passes no opinion down, so an umbrella over a host task
  and a cross task does not force the execution platform onto shared
  dependencies.
- A task that declares its own is **never transitioned** by a consumer,
  and re-originates the transition for everything below it. That is the
  host-tool-inside-a-cross-build case.
- A task with nothing above it and no declaration builds for the
  execution platform.
- A task named on the command line alongside a cross build that needs
  it is built the way that build needs it: there is one `outputs` path
  and only one answer that satisfies both. On its own it is a host
  build, as before.

A task reached in **two different declared configurations in one run**
is refused before anything runs, naming both platforms and the task
that originated each. Both would write the same `outputs`; building it
twice needs per-configuration output roots, which do not exist yet. The
two ways out are running the targets separately or giving the shared
task its own `targetPlatform`.

Callers with no run set (`describe`) fall back to the task's own
declaration. `pkf explain X` resolves over the run set rooted at `X`,
so it reports the key `pkf run X` looks up; a task that a *different*
run reaches in another configuration keys differently there, and
`pkf run <that target> --print-hash` is what shows it.

Not a schema change: `targetPlatform` is unchanged, only where it
reaches. Action keys move for any task that is a dependency of one
declaring a `targetPlatform` — they were keyed wrong before.

## Steps

A task with `steps` is lowered into one action per step plus a
deps-only umbrella, before anything downstream sees the plan:

```pkl
steps {
  new Step { name = "codegen"; cmd = "..."; inputs { "schema/**" }; outputs { "gen/**" } }
  new Step { name = "compile"; cmd = "..."; inputs { "src/**"; "gen/**" }; outputs { "lib/**" } }
}
```

- Each step becomes a task named `<task>/<step>` with its own `inputs`,
  `outputs`, action key and cache entry. `pkf run <task>/<step>` works.
- Steps inherit `shell`, `shellFlags`, `env`, `tools`, `cache`,
  `workdir`, `inheritEnv`, `hermetic`, `params` from the task.
- Chained by `deps` in declaration order; the first step inherits the
  task's own `deps`. Ordering is not left to artifact inference — a
  step with no outputs would float free.
- Steps are `visibility = "internal"`; `--all` reveals them.
- The umbrella keeps `provides`, and carries the union of the steps'
  `inputs` and `outputs` for `clean` and `affected`. It is not a
  producer or consumer in the action graph: it spawns nothing.
- Artifact collection follows *through* a producer that writes nothing,
  so a consumer of the pipeline keys on what the steps wrote.

Rejected at load time: `cmd` together with `steps`, `services` or
`service = true` together with `steps`, duplicate step names within a
task, and a composed `<task>/<step>` that collides with a real task.

## Providers

A task's `provides` block is data its **direct** dependents receive:

```pkl
provides = new Providers {
  executable = "target/release/cli"   // literal path, must be in `outputs`
  env { ["CLI_CHANNEL"] = "stable" }
}
```

Dependents see `executable` as `$PKF_<TASK>_EXECUTABLE` (task name
uppercased, non-alphanumerics to `_`), with the path re-rooted into the
dependent's own `workdir` — a producer in `crates/cli` and a consumer
in `apps/web` get `../../crates/cli/target/release/cli`. `env` entries
arrive under their own names.

Rules:

- Direct dependents only; providers do not travel a second hop.
- Precedence is `defaults.env` < providers < task `env` < params.
- `executable` must be matched by the producer's `outputs`, and the
  producer must have a `cmd`; otherwise the Taskfile is rejected at
  load time.
- Values land in the merged env overlay, so they are in the action key
  like any other variable. A producer declaring nothing changes no key.
- Sorted by name, so evaluation order cannot affect the key.

`pkf explain <task>` prints a `providers (N):` block naming each
value's origin. The file equivalent needs no schema —
`inputs { ...producer.outputs }` is ordinary Pkl.

## Command dispatch

`pkf <name>` where `<name>` is not a built-in subcommand is rewritten to
`pkf run <name>` and re-dispatched, so flags, params, positionals and
globs behave identically.

- Built-ins always win. A task sharing a name with one is reachable only
  as `pkf run <name>`; `pkf lint` reports it as `shadowed-by-builtin`.
- The fallback fires only when the name resolves to a task or matches a
  task glob; otherwise the name is reported as unknown, with near
  misses from both the subcommand list and the task list.
- A token starting with `-` is never a task name.
- Outside a project the name is reported unknown rather than
  complaining about a missing Taskfile.

## Timeouts and platform requirements

`timeoutSeconds > 0` runs the command under a deadline. On expiry the
shell is signalled first, then the descendants enumerated before it was
killed (a dead shell's children are reparented and can no longer be
found through it); SIGTERM, five-second grace, then SIGKILL. The task
fails with exit 143. Signalling children first would let the shell run
the next line of the script, so the order is load-bearing. Not hashed.

`requiresPlatform` is a list of `<os>/<arch>` strings checked before the
command is spawned; empty means any. A mismatch is fatal and names the
task, the requirement and the machine. Not hashed — the execution
platform already is.

`retries > 0` re-spawns the command after a failure, up to that many
extra attempts. Each attempt is announced on stderr; the count reaches
`--execution-log` as `attempts` (omitted when 1) and the summary's
`retried`. Services stay up across attempts, but a sandbox does not — a
retry always gets a fresh tree, so it cannot inherit the debris of the
attempt that failed, and a failed attempt's partial outputs are never
collected. Exhausting the budget fails with the command's own exit
code. Not hashed: only the successful attempt is stored.

## Evaluation cache

The rendered Taskfile is memoized under `<cache_root>/eval/<slot>`.

- The slot is keyed on the Taskfile's path and its own bytes.
- The entry records `(module, digest)` for every module the loader read
  and `(dir, listing digest)` for each directory containing one. Every
  record is re-validated on lookup; any mismatch, unreadable module, or
  older format version is a miss.
- The directory listings are what catch a *new* file matching an
  `import*` glob, which changes the module graph without changing any
  recorded module's bytes.
- `package://` modules are recorded by URI, which is version-pinned.
- `PKFIRE_MBT_NO_EVAL_CACHE=1` disables it.

## Glob expansion

A wildcard pattern walks only what it can match, bounded by the pattern
itself rather than by any cache:

- the walk starts at the literal directory prefix before the first
  wildcard (`src/**/*.mbt` starts at `src/`);
- it stops descending past as many components as the pattern has,
  unless the pattern contains `**` (`.mooncakes/*/*/moon.mod` stops at
  depth 3).

A literal pattern with no wildcard skips the walk entirely. A prefix
directory that does not exist yields no matches and no diagnostic —
`outputs { "dist/**" }` before anything has built `dist` is ordinary.

Nothing here is memoized, so a file a previous task in the same run
wrote is still found.

## Local cache

The cache root is selected in this order:

1. `PKFIRE_MBT_CACHE_DIR`
2. `$XDG_CACHE_HOME/pkfire-mbt`
3. `$HOME/.cache/pkfire-mbt`
4. `.pkfire-mbt-cache`

An entry is an ActionCache manifest plus content-named blobs:

```text
<root>/ac/<first-two-key-chars>/<remaining-key>/result.json
<root>/blobs/<first-two-digest-chars>/<remaining-digest>
```

`result.json` is `{version, outputs, stdout?, stderr?}`. Each output is
`{path, kind, mode}` plus `{digest, size}` for a file or `{target}` for
a symlink; `kind` is `file`, `dir` or `symlink`, and the list keeps the
order outputs were collected in, so a directory is created before what
is inside it. A manifest whose `version` this runner does not recognise
is a miss, never a partial restore.

Blobs are named by the SHA-256 of their **uncompressed** content and
stored gzipped — the same bytes must land on the same name whichever
run wrote them, and gzip output is not guaranteed identical across
versions. Blobs are immutable and shared: two entries whose outputs
differ in one file cost one blob, not two trees.

After a successful miss, pkf expands existing `outputs`, walks declared
directories (recording symlinks rather than following them), writes one
blob per file, and publishes the manifest last — so an entry that exists
is one whose contents are all already on disk. Every blob and the
manifest go through a temp file and a rename.

On hit the manifest is validated in full before anything is written:
unsafe paths, escaping symlinks, a missing blob, or a claimed expansion
past the 4 GiB cap all read as a miss with a reason on stderr.

The entry also carries the run's stdout and stderr as blobs, capped at
1 MiB per stream (they ride the archive under a reserved `.pkf-meta/`
prefix on the wire). A restore hands those to the runner and never
writes them into the workspace; the hit line becomes
`# name (cache hit <key>, replaying logs)` and the stored streams are
printed verbatim. A task that printed nothing keeps the plain hit line.
Declaring an output under `.pkf-meta/` is rejected at load time — it
would be stored and then dropped on every hit.

Entries written before the split live at
`<root>/cas/<first-two>/<remaining>/entry.tar.gz` and are still read, so
an upgrade does not cold-start a warm cache. Nothing writes there again.

Because entries share blobs, removing one frees nothing by itself.
`pkf cache prune` and `pkf cache rm` delete manifests and then sweep
every blob no remaining manifest names, reporting what the sweep
actually deleted. `pkf cache clear` removes manifests, blobs and any
pre-split archives; the Pkl evaluation cache under the same root is left
alone. `pkf cache stats` reports entries, blob count, bytes on disk, and
how much the sharing saved.

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

Uploads declare `Content-Length`; the body is never chunked. A backend
that reads by length alone would otherwise store a zero-byte object and
return success, and every later fetch would get a well-formed empty
archive.

The wire format is unchanged by the local split: still one archive per
key. A push rebuilds it from the blobs; a fetch validates it and takes
it apart into blobs and a manifest, so the fetched entry is a real local
hit next run rather than another round-trip. A remote entry that fails
validation never reaches the blob store.

A remote hit warms the local store and restores outputs. A successful
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
