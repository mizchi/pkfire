# Changelog

All notable changes to pkfire are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The Pkl schema version, the `pkf` binary version, and the GitHub
Action version all move together — there is one tag per release
(`pkfire@<version>`) and one row per release in this file.

## [Unreleased]

### Added

- **Action-friendly tags (`v<ver>` + floating `v<major>`).** The
  Release workflow now pushes `v0.4.0` and `v0` at the same commit
  it built the release from. Use those from `uses:` instead of the
  underlying `pkfire@<ver>` tag — GitHub Actions cannot parse
  `uses: <repo>@<ref>` when the ref contains `@`, so writing
  `uses: mizchi/pkfire@pkfire@0.4.0` silently breaks the entire
  workflow file. The action's version-resolution now normalizes
  `v0.4.0`, `0.4.0`, `v0`, and `pkfire@0.4.0` to the same
  underlying release. Context: kawaz/pkf-tasks DR-0004.

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

### Previously-unreleased (now shipping in 0.4.0)

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

[Unreleased]: https://github.com/mizchi/pkfire/compare/pkfire@0.4.0...HEAD
[0.4.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.4.0
[0.1.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.1.0
