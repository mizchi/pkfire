# Changelog

All notable changes to pkfire are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The Pkl schema version, the `pkf` binary version, and the GitHub
Action version all move together — there is one tag per release
(`pkfire@<version>`) and one row per release in this file.

## [Unreleased]

### Added

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

[Unreleased]: https://github.com/mizchi/pkfire/compare/pkfire@0.1.0...HEAD
[0.1.0]: https://github.com/mizchi/pkfire/releases/tag/pkfire@0.1.0
