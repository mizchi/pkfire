# Changelog

All notable changes to pkfire are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The Pkl schema version, the `pkf` binary version, and the GitHub
Action version all move together — there is one tag per release
(`pkfire@<version>`) and one row per release in this file.

## [Unreleased]

### Changed

- Examples now amend the published `pkfire@0.9.0` Pkl package.

## [0.9.0] - 2026-05-13

### Added

- `pkf explain --diff OLD_TASKFILE <task>` compares the action-key
  inputs for the current Taskfile against another Taskfile and reports
  which component changed (`cmd`, `shell`, `shellFlags`, `env`,
  `tools`, input file digests, or config hash).
- `pkf lint` now also flags suspicious rendered tasks: cacheable
  outputs with no inputs, services without a readiness probe, and
  tasks that have neither `cmd` nor `deps`.
- `pkf list --long` prints a compact audit table with visibility,
  cache/quiet state, deps, input/output counts, shell, flags, and cmd.
- `pkf lint --json` emits structured findings for editor/CI consumers.
- `pkf doctor` now checks whether `pkf` on `PATH` differs from the
  currently running binary, which helps catch stale hook installations.
- `pkf doctor --json` emits structured setup checks, and
  `pkf doctor --fix --dry-run` previews replacing a stale `pkf` on
  `PATH` with the currently running binary. Without `--dry-run`, the
  old binary is backed up before replacement.
- `pkf lint --fix` safely adds `cache = false` to tasks that declare
  outputs but no inputs; other lint findings remain suggestions.
- Added `examples/diagnostics` and recipe 15 to show diagnostics,
  machine-readable lint/doctor output, safe fix previews, internal
  audit tasks, quiet wrappers, and strict shell flags.
- The repo's own `Taskfile.pkl` now exposes `fmt` and `fmt:check`
  maintenance tasks, and `preflight` depends on the formatting check.

## [0.8.0] - 2026-05-13

### Added

- `Task.cmd` can be omitted for deps-only umbrella tasks. The
  rendered task succeeds after its dependencies complete without
  spawning a shell, so `ci` / `all` aggregators no longer need
  `cmd = ":"`.
- `Task.shellFlags` configures the arguments passed before `cmd`
  (default `List("-c")`). This keeps existing shell behavior while
  allowing strict bash flags or runtimes such as Node via
  `shellFlags = List("-e")`.
- `Task.quiet = true` suppresses pkfire's per-task diagnostic lines
  for that task while preserving the task's own stdout/stderr and the
  final run summary.

## [0.7.0] - 2026-05-13

### Added

- `pkf run -- args...` now forwards tail args to the `default`
  task when no explicit task name is given.
- `pkf list --unsorted` / `pkf graph --unsorted` preserve
  Taskfile declaration order, and `pkf list` aligns description
  columns.
- `Task.visibility = "internal"` hides helper tasks from
  `pkf list` / `pkf graph` by default; `--all` reveals them.
- `pkf list --color=auto|always|never` adds optional ANSI color
  to human-readable list output.
- `pkf graph --format tree` emits a terminal-readable dependency
  tree with `--target` and `--depth=N` support.
- `pkf lint` detects local `Task` definitions in the current
  Taskfile that are not rendered through `tasks { ... }`.

## [0.6.0] - 2026-05-11

Pkl schema is unchanged from 0.4.0 / 0.5.0 — this release ships
the second wave of `pkf` CLI features and runtime behavior on top
of the same schema surface. Existing Taskfiles keep working; the
`amends` URI bump is mechanical.

### Added

- **`pkf <plugin> <args>` plugin dispatch.** When `args[0]` isn't a
  built-in subcommand, pkfire looks for `pkf-<args[0]>` on PATH
  and execs it with the remaining args. Plugin inherits the
  user's terminal (stdin/stdout/stderr); `PKF_PLUGIN_NAME` env
  carries the invoked subcommand. Git-style extension point —
  write `pkf-release` once, call `pkf release`. No registration.
- **`pkf run --remote-only` (also `pkf affected`).** Skips the
  local CAS entirely; reads + writes go straight to the remote
  cache configured via `PKFIRE_REMOTE_CACHE`. Useful for "did
  my last build actually push to remote?" smoke tests in CI.
  Requires the env var; errors clearly if it's not set.
- **`pkf graph --target X --depth=N`.** Limits BFS depth from
  the target so the rendered graph stays a localized
  neighborhood instead of the full transitive subgraph. Pair
  with `--format mermaid` for inline-renderable comment
  artifacts.
- **`pkf migrate --to=<ver>`.** Rewrites a Taskfile.pkl's
  `amends "...pkfire@<old>"` URI to a new version, then
  re-evaluates the file to verify the new schema actually
  loads. If `pkl eval` fails post-migration, the file is
  reverted to the original. `--dry-run` shows the diff
  without writing. `--skip-verify` bypasses the eval check
  (e.g. when pkl isn't on PATH).
- **`pkf pkl-cache warm`.** Pre-evaluates one or more Pkl
  files (default: the discovered Taskfile.pkl) so
  `~/.pkl/cache` is populated. CI prefetch step — runs once
  before parallel jobs so each later `pkl eval` / `pkf run`
  hits a populated cache instead of racing on the same
  fetch.
- **`pkf affected --watch`.** Watch loop that re-evaluates the
  affected set on every file change. The set itself can shift
  (a new edit pulls in different tasks), so each iteration
  re-runs `git diff`, recomputes the affected closure, builds
  a fresh plan, and executes. Watch targets cover every
  task's expanded inputs (broader than a single subgraph) so
  changes anywhere in the repo are noticed.
- **`gitChangedFiles` now unions committed + staged + working-
  tree edits.** Previously `pkf affected --since=<ref>` only
  saw committed-to-HEAD changes; uncommitted edits during local
  iteration didn't trigger affected tasks. The union covers
  all three diff modes, dedupes via map. CI-only flows where
  the working tree is clean still work the same.
- **`pkf run --profile=<name>` (also `pkf affected`).** Run-wide
  profile tag injected as `$PKF_PROFILE` so `cmd` can branch
  (`if [ "$PKF_PROFILE" = "ci" ]; then ...; fi`). Folded into
  every task's action key, so distinct profiles cache as
  distinct entries — `pkf run --profile=ci` and
  `--profile=dev` never share a cache slot even when every
  declared field is otherwise identical.
- **`pkf run --on-fail=shell`.** After a non-zero run, drop into
  `$SHELL` (or `/bin/bash`) in the first-failed task's
  resolved workdir, with `PKF_TASK_NAME` / `PKF_TASK_ROOT` /
  `PKF_WORKSPACE_ROOT` / `PKF_PROFILE` populated. `exit` returns
  to pkf with the original exit code. Doesn't reconstruct the
  failed task's full declared env (use `pkf explain <task>` from
  inside the shell to see it) — just enough context to poke
  around at the workdir.
- **`pkf run --keep-going` (also wired into `pkf affected`).**
  Bazel `-k` / make `-k` semantics: a failure in one subgraph
  doesn't cancel other independent subgraphs. Transitive
  downstreams of a failed task still skip (`OutcomeSkipped`).
  Execute aggregates failures via `errors.Join` so the caller
  sees every error, not just the first.
- **`pkf explain <task>`.** Dumps every input to the action
  key: cmd, shell, sorted env, sorted tools, every expanded
  input file with its content-hash prefix, the Pkl module's
  config hash, plus `acceptsArgs` / `params` declarations.
  Diagnostic for the recurring question "why isn't this hitting
  cache?" — diff two runs' `pkf explain <task>` outputs to see
  exactly which component flipped.
- **Auto-injected env vars `PKF_TASK_NAME` / `PKF_TASK_ROOT` /
  `PKF_WORKSPACE_ROOT`.** Every task's `cmd` now sees these
  three so it can reference its own context without hardcoding
  paths. Not part of the action key (they're constants of the
  task definition, already implicit via cmd / env / inputs).
- **`pkf completion <bash|zsh|fish>`.** Emit a shell-completion
  script to stdout. Dynamic task-name completion for `run` /
  `affected` / `clean` / `up` calls back into `pkf list` at
  completion time, so it always reflects the current Taskfile.
  Static subcommand lists for `hooks` / `cache` / `completion`
  / `graph --format`. Install with:
  ```sh
  pkf completion bash > ~/.bash_completion.d/pkf
  pkf completion zsh > "${fpath[1]}/_pkf"
  pkf completion fish > ~/.config/fish/completions/pkf.fish
  ```
- **`pkf run --quiet`.** Suppress per-task log lines
  (`[pkf] <task>: <cmd>` and `[pkf] <task>: hit/ran/...`).
  Errors and the end-of-run summary still print. Useful for CI
  logs and for invoking pkfire from another runner where the
  outer log already labels each step. Also wired into
  `pkf affected`.
- **`pkf clean [task...]`.** Remove tasks' declared `outputs`
  (resolved relative to each task's `workdir`). With no
  positional arg, cleans every task that declares outputs.
  `--dry-run` prints the paths without removing. Cache is
  intentionally untouched — use `pkf cache rm <key>` (or
  `pkf run --refresh`) to invalidate the cached result too.
  Glob targets (`pkf clean 'build:*'`) expand against the
  task list, same as `pkf run` / `pkf affected`.
- **Glob targets for `pkf run` / `pkf affected` / `pkf clean`.**
  Any target containing `*` or `?` is treated as a `path.Match`
  pattern and expanded against task names. So `pkf run
  'test:*'` runs every test-prefixed task in topological
  order. Literal (`*`-free) names pass through unchanged; a
  pattern that matches nothing falls through as the literal
  task name so the existing "unknown task" error surfaces.
- **`pkf cache <stats|prune|rm|clear>`.** Direct control over
  the local CAS at `$PKFIRE_CACHE_DIR` (default
  `$XDG_CACHE_HOME/pkfire`).
  - `stats` — entry count, total size, oldest/newest mtime.
  - `prune [--older-than=Nd]` (default 30d) — drop entries
    whose newest file mtime is older than the threshold.
    `--dry-run` previews. Accepts `Nd` (days),
    `Nh`, `Nm`, `Ns` durations.
  - `rm <action-key>...` — drop specific entries. Accepts
    full 64-char hex or any ≥ 2-char unique prefix.
  - `clear --yes` — nuke the entire `cas/` directory.
    Refuses without `--yes` so accidents stay rare.
- **Auto-generated GitHub Release notes from CHANGELOG.md.**
  The Release workflow now runs `scripts/release-notes.sh
  <version>` and feeds the section between `## [<version>]` and
  the next `## [...]` into `gh release create --notes-file`.
  Re-running the workflow on an existing tag (`workflow_dispatch`)
  also `gh release edit --notes-file` — so a CHANGELOG edit can
  be republished without recreating the release. Falls back to a
  terse default body when the section is missing. Self-tested by
  `pkf run test:release-notes` (wired into `preflight`).

## [0.5.0] - 2026-05-11

Pkl schema is unchanged from 0.4.0 — bumping in lockstep with the
binary/action per project convention. The amends URI change is
mechanical; no Taskfile rewrites needed.

The headline of 0.5.0 is the new **task-runner UX layer**: a
monorepo-aware `pkf affected` for CI, multi-target / default-task
ergonomics, cache-state preview in dry-run, end-of-run timing
summary, plus opt-in git-hook installation. Everything below
sits on top of the unchanged 0.4 schema.

### Added

- **`pkf affected --since=<ref>`.** Monorepo-CI killer: runs only
  tasks whose declared `inputs` glob matches a file in the
  asymmetric diff `<ref>...HEAD`, plus their transitive
  *dependents* in the deps DAG. The unaffected deps that come
  along in the resulting plan hit cache, so the actual work is
  minimal. Default ref is `origin/main` (fallback `origin/master`,
  then `HEAD~1`). Optional positional task names filter the
  affected set: `pkf affected --since=origin/main test:unit
  test:integration` restricts to those exact targets. `--dry-run`
  prints the plan with the same cache-prediction format the
  built-in `pkf run --dry-run` uses.
- **Multi-target `pkf run`.** `pkf run a b c` computes the
  topological union of the targets' subgraphs and runs once. Tail
  args / `--param=` are rejected with multi-target (which target
  would they apply to?) — single-target run keeps the existing
  invocation overlay.
- **Default task.** `pkf run` with no positional argument now
  invokes a task named `default` if one is declared. Errors with
  a `try pkf list` hint when neither a target nor a `default` task
  exists.
- **End-of-run summary + `--timing`.** Every non-watch `pkf run`
  / `pkf affected` now prints a one-line summary at the end:
  `[pkf] done: 6 tasks · 3 hit · 3 ran · 2 uncached (11.3s wall,
  12.0s CPU)`. Adding `--timing` follows with a per-task
  duration breakdown sorted descending — pinpoints the slow task
  without a profiler.
- **`pkf run --dry-run` previews cache state per task.** The
  output is a compact table with one row per task and a status
  column: `hit` (cache lookup will succeed → restore from CAS),
  `will run` (cacheable but no entry yet), `uncached`
  (`cache = false`), `service` (skipped by `pkf run` — preview
  only). Includes the 12-char action key prefix per row, a
  summary line, and a per-invocation overlay note (resolved
  params + tail args) when applicable. With `--no-cache` or
  `--refresh`, the lookup is treated as inert and every
  cacheable task shows `will run` — answers "what would
  `--refresh` actually re-run?". Remote cache is not consulted
  during dry-run to keep it fast.
- **`pkf hooks install` / `uninstall` / `list`.** Convention-based
  git hook manager: any task whose `name` matches a git client-side
  hook event (`pre-commit`, `pre-push`, `commit-msg`, ... full list
  in SKILL.md) becomes installable. Install writes
  `.git/hooks/<event>` as a 3-line shim that delegates to
  `pkf run <event> -- "$@"` (the trailing `$@` carries git's
  per-hook args). The shim is marked so uninstall removes only
  pkfire-managed hooks and won't clobber hand-written ones (use
  `--force` to overwrite). Designed to compose with — not replace —
  dedicated managers like [hk](https://hk.jdx.dev/) and lefthook.
- **`.envrc`-safe idempotent `pkf hooks install`.** Silent
  (zero stdout/stderr) when every shim is already present and
  bit-identical to what pkfire would write — safe to drop into
  `.envrc` for auto-install on `cd`. Writes go through tempfile
  + rename so concurrent reloads can't tear the shim.
- **Recipe 14: secretlint as a pkfire pre-push hook.** A
  copy-paste path for repos whose ONLY git hook concern is
  secrets-scanning: `pnpm add -D secretlint` + a 7-line
  `.secretlintrc.json` + this recipe + `pkf hooks install` = done,
  no prek / `.pre-commit-config.yaml`. Wires to pre-push (not
  pre-commit) so secretlint runs once per push instead of every
  micro-commit; scopes to the outgoing diff via `git diff
  '@{push}..HEAD'`. Composes with prek for projects that
  already use it.
- **GitHub Action friendly `v<ver>` + floating `v<major>` tags.**
  Release workflow now pushes `v0.5.0` and (refreshes) `v0` so
  consumers can write `uses: mizchi/pkfire@v0.5.0` (or `@v0`)
  without tripping GHA's `<repo>@<ref-with-@>` parse failure
  (kawaz/pkf-tasks DR-0004). Dedicated `v-tags.yml` workflow
  fires on Release-success via `workflow_run`, with manual
  recovery via `workflow_dispatch`. Implemented with git CLI
  rather than `gh api` because `git/refs` returned 403 from
  github-actions[bot] even with `Contents: write`. Backfill is
  intentionally skipped: the bot can't push refs whose commit
  contains workflow files different from `main` (no
  `workflows` permission on GITHUB_TOKEN), and old release
  commits trip that hook.
- **`pkf format` (alias for `pkl format`).** Defaults to the
  directory of the discovered Taskfile; `--check` maps to
  `--diff-name-only` (exit 11 on violations). No corresponding
  Taskfile wrapper task — the CLI is the canonical entry point.
- **`pkf doctor`.** Read-only diagnostic. Reports the `pkl` CLI
  version, cache dir + total size, remote-cache reachability
  when configured, and the resolved Taskfile + its `amends`
  line. Exits non-zero iff any check FAILed.
- **`pkf list --json`.** Machine-readable enumeration with every
  Task field for editor/CI tooling that wants to discover tasks
  without parsing the human-readable list.
- **`pkf run --refresh`.** Skip cache *lookup* but still *store*
  the result. Distinct from `--no-cache` (which disables both).
  Use when an undeclared dependency changed and you want to
  re-baseline rather than run uncached forever. Mutually
  exclusive with `--no-cache`.
- **Repo-root `Taskfile.pkl` for project maintenance.**
  Dogfoods pkfire on its own development flow. Tasks: `vet`,
  `test:go`, `test:race`, `test:pkl`, `test:examples`,
  `check-version`, `bump --to=<ver>`, `tag`, `preflight`
  (pre-commit gate aggregating vet + go/pkl/examples tests +
  version + format check). The cross-compile / release matrix
  stays in `examples/dogfood/Taskfile.pkl` (CI gate).
- **`test:examples` task.** `pkl eval` every published example
  Taskfile so schema/example-pin drift is caught before it
  ships — would have flagged the `examples/*` 0.1.0 pin that
  silently rode through three releases.
- **Action input `cache-pkl: false` (opt-in).** When `true`,
  the composite action wraps `actions/cache@v4` around
  `~/.pkl/cache` keyed on `PklProject.deps.json` +
  `Taskfile.pkl`. Override the key via `pkl-cache-key`. Off by
  default — projects that don't import remote Pkl packages
  don't pay the cache restore/save cost.
- **"Used by" README section + library-author SKILL section.**
  Knowledge extracted from kawaz/pkf-tasks (DR-0001 …
  DR-0004): `abstract module` + `extends` for polymorphism,
  `(base) { cmd = ...; description = ... }` object-amends,
  `allTasks: Listing<Task>` export, `name = "<scope>:<action>"`
  namespace convention, runtime dispatch pattern (Pkl can't see
  CWD), `read("env:X")` pitfalls. Recipe 12 is a copy-paste
  skeleton for the layout.
- **Environment / args / params policy section in README.**
  The non-obvious rules in one place — layer order (host <
  defaults.Env < task.Env < params), the deliberate asymmetry
  that `cmd` sees host env but the action key never hashes it,
  when to use `read("env:X")` vs `inheritEnv = false`, and the
  bool-param value-less form. Aimed at AI agents that were
  guessing the wrong way around.

### Fixed

- **Examples were pinned to `pkfire@0.1.0` across three
  releases.** `bump-version.sh` and
  `check-version-consistency.sh` used `git ls-files
  'examples/<name>/**/*.pkl'`, but git pathspec `**` matches
  **one or more** directory segments — top-level
  `examples/<name>/Taskfile.pkl` was silently invisible. Fix:
  enumerate the four example Taskfiles directly. examples
  swept to the current version.
- **Action.yml version resolver.** Now normalizes
  `v0.5.0` / `0.5.0` / `v0` / `pkfire@0.5.0` to the same
  underlying release tag.

### Changed

- `actions/checkout@v4` → `@v5`, `actions/setup-go@v5` → `@v6`
  across all workflows. Silences the Node.js 20 deprecation
  notice ahead of the 2026-06-02 forced runtime bump.
- All Pkl files in `pkl/`, `examples/`, and `skills/` reformatted
  with `pkl format`. No semantic changes; long-line wraps and
  spaces around `|` in type unions.

## [0.4.0] - 2026-05-11

### Added

- **Default-on `inheritEnv`.** New `Task.inheritEnv: Boolean = true`.
  By default `cmd` now sees pkfire's full ambient environment
  (`os.Environ()`), matching `just`/`make`/`npm run` semantics — so
  `SSH_AUTH_SOCK`, `GPG_AGENT_INFO`, locale, and dev-tool sockets
  pass through without `env { ["SSH_AUTH_SOCK"] = read("env:...") }`
  boilerplate. Set `inheritEnv = false` for hermetic tasks; that
  mode preserves the pre-0.4 small allowlist (`PATH`, `HOME`,
  `LANG`, ...). In both modes only the schema-declared `env { ... }`
  contributes to the action key, never the host environment.
- **Variadic tail args via `acceptsArgs`.** New
  `Task.acceptsArgs: Boolean = false`. When true,
  `pkf run <task> -- a b c` forwards `a b c` to `cmd` as `$1`,
  `$2`, ... and `$@` (using `bash -c '<script>' pkf a b c`). Maps
  to just's `*ARGS` shape. The args fold into the action key when
  `cache = true`, so different invocations cache as different
  entries.
- **Typed named flags via `params { Param ... }`.** New
  `Task.params: Listing<Param>` with the `Param` class
  (`name`/`type: "string"|"enum"|"int"|"bool"`/`choices`/`default`/`description`).
  The caller passes `pkf run <task> --<name>=<value>`; pkf
  validates the value's *type* (enum membership, integer
  parsability, "true"/"false" for bool) *before* the cmd runs, then
  exposes each resolved value to `cmd` as `$NAME` (uppercased).
  Bool params take the value-less form `--flag` (= true) so they
  don't consume the next token; explicit false is `--flag=false`.
  Defaults are themselves type-checked, so a typo like
  `default = "abc"` on an int param fails fast. Missing required
  params (no `default`) error client-side. Resolved values fold
  into the action key when `cache = true`, so `--bump=patch` and
  `--bump=minor` cache separately. Recipe at
  `skills/pkfire/assets/recipes/11-named-params.pkl`.
- **Task names may now contain `/`.** The name regex is relaxed
  from `^[a-zA-Z][a-zA-Z0-9_:.-]*$` to
  `^[a-zA-Z][a-zA-Z0-9_:./-]*$`. Lets the directory tree drive task
  identity (`check-translate/docs:DESIGN`,
  `services/api/build`) when one task per subtree is the natural
  decomposition. Cache layout is unaffected — entries are keyed by
  the action-key digest, not the task name.

### Changed

- Schema bumped to 0.4.0. Adds `inheritEnv`, `acceptsArgs`,
  `params` to `Task`; adds the `Param` class. All new fields have
  sensible defaults so an existing 0.3.x Taskfile keeps evaluating
  unchanged; but the runtime behavior shifts for tasks that
  previously relied on the pre-0.4 hermetic-allowlist env: tasks
  that now see `SSH_AUTH_SOCK` (etc.) get them via inheritance.
  Set `inheritEnv = false` per-task to opt back into the old
  behavior.

### Added (services + supervision, all new in 0.4.0)

- **Per-service granular restart in `pkf up --watch`.** Each service
  now has its own action key tracked across watch iterations. On a
  file event, `pkf` recomputes every service's key and restarts only
  the ones whose key actually changed. Editing `src/api/foo.ts` no
  longer takes down `db` (which had a 15-second crash-recovery
  window), only `api`. The pre-service plan is re-executed each
  iteration so cached steps skip immediately.
- **Per-service log prefix.** Service stdout/stderr lines are now
  prefixed with `[<service-name>] ` so a `pkf up dev` mixing db +
  api + web in one terminal stays readable. Partial lines are
  buffered until the trailing newline arrives, and any unflushed
  remainder is emitted (with a synthesized newline) when the service
  exits, so nothing is dropped.
- **Reuse + readiness now apply to `pkf up`, not just
  `pkf run` + `services { ... }`.** A service's `readyPort`/`readyCmd`
  is consulted before `pkf up` spawns it; an already-running
  instance (typically another `pkf up` session in a different shell
  or a docker-compose stack) is reused, and shutdown leaves the
  reused process alone. `pkf up dev` in two terminals no longer
  port-collides.
- **Aggregator targets are first-class.** A non-service task that
  exists only to list services in `deps { ... }` (the canonical
  `local dev = new Task { deps { db; api; web } }` pattern) now
  works as a `pkf up dev` target — pkfire strips the service deps
  from the pre-service plan instead of erroring out.
- **Readiness probes (`readyPort`, `readyCmd`,
  `readyTimeoutSeconds`).** A service that declares a probe is
  *reused* when the probe already passes — pkfire dials once
  before spawning, and on success skips both the spawn and the
  teardown. `pkf run e2e` against an already-running `pkf up dev`
  no longer port-collides; it logs `reusing existing service "db"`
  and lets the dev session keep ownership. After a fresh spawn,
  pkfire polls the probe (every 250ms, up to
  `readyTimeoutSeconds`) before letting dependent services or the
  body task's cmd start, replacing hand-rolled `until pg_isready`
  loops in user `cmd`s. `readyPort` and `readyCmd` compose: both
  must pass when both are set.
- **Long-running services via `pkf up`.** A new `service: Boolean`
  field on `Task` marks a task as a supervised process. `pkf up
  <target>` runs every non-service dep first, then starts the
  services concurrently and blocks until Ctrl+C. `pkf up --watch
  <target>` adds a stop-rebuild-restart loop on input changes. The
  runner now sets every cmd as a process-group leader and signals
  the whole group on cancel (SIGTERM → grace → SIGKILL), so a
  `bash -c "node server.js"` style task no longer leaks its node
  child. Grace period is per-task via
  `shutdownTimeoutSeconds: Int = 5`. Recipe at
  `skills/pkfire/assets/recipes/08-services.pkl` shows a full
  db + api + web stack.
- **Tests against live services via `services { ... }` on a task.**
  A task can declare `services: Listing<Task>`; `pkf run` brings
  those services up before invoking `cmd` and releases them when
  it returns (success or failure). Services nest — listing `api`
  also brings up `api.services` (typically `db`). Cache hits skip
  spinup entirely. Recipe 09 covers the e2e + ephemeral postgres
  case.
- GitHub Action at the repo root (`mizchi/pkfire@pkfire@<version>`)
  that installs `pkf` and the Pkl CLI on the runner.
- Pre-built `pkf` binaries for `linux/darwin × amd64/arm64`,
  attached to each release.
- `Test` CI workflow that runs the `examples/dogfood` `ci` aggregate
  (vet + go-test + pkl-test + cross-compile matrix + checksum +
  integration smoke) on every PR and push to main; the Release
  workflow gates on it.
- `scripts/check-version-consistency.sh` (and `bump-version.sh`) to
  keep every `pkfire@<ver>` reference in sync with the version
  declared in `pkl/PklProject`. Wired into CI.
- `pkf init` now embeds the running binary's version into the
  `amends` URI (release builds pin to their package; dev builds fall
  back to the main HTTPS URL).

### Changed

- Schema bumped to 0.3.0. Adds `service`,
  `shutdownTimeoutSeconds`, `services`, `readyPort`, `readyCmd`,
  `readyTimeoutSeconds` to `Task`; all are optional with sensible
  defaults, so existing 0.1.0 Taskfiles keep evaluating, but an
  older binary cannot decode a 0.3.0 schema. Bump `pkf` and the
  `amends` URI together.

## [0.1.0] - 2026-05-10

### Added

- First Pkl package release at
  `package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.1.0`.
- Typed DAG schema with `Task` references for `deps`, action key
  hashing over inputs/cmd/env/tools, local CAS, watch mode, and an
  HTTP remote-cache backend (with a Cloudflare Worker reference
  implementation).
- Examples for basic, Node, Rust, monorepo, dogfood, and the
  remote-cache worker.
- Skill at `skills/pkfire/SKILL.md` plus seven copy-paste recipes.
- Nix flake (`nix run github:mizchi/pkfire`) and Go install path.

[Unreleased]: https://github.com/mizchi/pkfire/compare/pkfire@0.8.0...HEAD
[0.8.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.8.0
[0.7.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.7.0
[0.6.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.6.0
[0.5.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.5.0
[0.4.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.4.0
[0.3.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.3.0
[0.2.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.2.0
[0.1.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.1.0
