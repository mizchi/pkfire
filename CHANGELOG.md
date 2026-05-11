# Changelog

All notable changes to pkfire are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The Pkl schema version, the `pkf` binary version, and the GitHub
Action version all move together — there is one tag per release
(`pkfire@<version>`) and one row per release in this file.

## [Unreleased]

### Added

- **Recipe 14: secretlint as a pkfire pre-commit hook.** A
  copy-paste path for repos whose ONLY git hook concern is
  secrets-scanning: `pnpm add -D secretlint` + a 7-line
  `.secretlintrc.json` + this recipe + `pkf hooks install` = done,
  no prek / `.pre-commit-config.yaml`. Scopes to staged files via
  `git diff --cached --name-only -z` so unstaged junk in the
  working tree doesn't trip the hook. Documents the
  composition with prek for projects that already use it.
- **`pkf hooks install` / `uninstall` / `list`.** Convention-based
  git hook manager: any task whose `name` matches a git client-side
  hook event (`pre-commit`, `pre-push`, `commit-msg`, ... full list
  in SKILL.md) becomes installable. Install writes
  `.git/hooks/<event>` as a 3-line shim that delegates to
  `pkf run <event> -- "$@"` (the trailing `$@` carries git's
  per-hook args). The shim is marked so uninstall removes only
  pkfire-managed hooks and won't clobber hand-written ones (use
  `--force` to overwrite). Designed to compose with — not replace —
  dedicated managers like [hk](https://hk.jdx.dev/) and lefthook:
  use them when you need staged-file scoping or check/fix duality,
  use `pkf hooks` when a `pkf run pre-commit` is enough. Recipe 13
  covers the patterns.

## [0.5.0] - 2026-05-11

Pkl schema is unchanged from 0.4.0 — bumping in lockstep with the
binary/action per project convention. The amends URI change is
mechanical; no Taskfile rewrites needed.

### Added

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

[Unreleased]: https://github.com/mizchi/pkfire/compare/pkfire@0.5.0...HEAD
[0.5.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.5.0
[0.4.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.4.0
[0.1.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.1.0
