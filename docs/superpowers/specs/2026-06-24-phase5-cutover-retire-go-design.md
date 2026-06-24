# Phase 5 — Cutover + Retire Go Design

**Date:** 2026-06-24
**Status:** Approved design
**Part of:** pkf Go→MoonBit canonical-binary migration (final phase)

## Goal

Make the MoonBit `pkf` the **sole** implementation: delete ALL Go (the `pkf`
implementation AND the Go conformance harness), rewrite the candidate-vs-golden
conformance check as a **MoonBit-native runner**, and cut over CI / dev tooling / docs.
The repo ends with **zero Go**.

## Locked decision (this phase)

**Full Go purge** (user choice): delete `cmd/pkf/`, `internal/`, `go.mod`, `go.sum`,
**and** the Go conformance harness `conformance/*.go`. The frozen goldens
(`conformance/golden/`), the scenario schema (`conformance/Conformance.pkl`,
`conformance/scenarios.pkl`), and fixtures (`conformance/fixtures/`) SURVIVE and are
driven by a new MoonBit conformance runner.

## Background / current state (post Phase 4)

- Distribution already ships the MoonBit binary (release matrix, flake) — no Go in the
  build/release path. Remaining Go is: `cmd/pkf/` (9.4 KLOC) + `internal/` (4 KLOC, sole
  dep `apple/pkl-go`) + `conformance/*.go` (1 KLOC harness) + `go.mod`/`go.sum`.
- The Go harness has three test entry points: `TestCandidateParity` (runs `PKF_MBT_BIN`
  vs frozen goldens — **no Go pkf needed**, the contract gate), `TestOracleSelfConsistency`
  + `TestUpdateGolden` (need the Go pkf as oracle — **migration-era only**).
- Remaining Go references: `.github/workflows/{test.yml,conformance.yml,nix.yml}`,
  `Taskfile.pkl` tasks (`vet`/`test:go`/`test:race`/`conformance`/`lintTaskfile`/
  `testWorkflow`/`preflight`), `flake.nix` devShell (`go`/`gopls`), README `### Go` install
  section + devShell note + a `go install` example.
- Survives untouched: `pkl/` schema package, `examples/`, `conformance/golden|fixtures`,
  `pkf-mbt/` stays a subdirectory (no promotion — flake/CI reference `./pkf-mbt/` paths).

## Scope

### In scope
1. **MoonBit conformance runner** (`conformance/` becomes a MoonBit module). Replaces
   `conformance/*.go`. Must reproduce the Go harness's contract semantics so the EXISTING
   frozen goldens still pass 41/41:
   - **Scenario loader**: eval `scenarios.pkl` (typed by `Conformance.pkl`) to JSON via the
     embedded `@pkl` loader (the runner is MoonBit, depends on `mizchi/pkl`), yielding the
     scenario list (id, fixture, argv, contract).
   - **Runner**: copy the fixture into an isolated temp dir (honour `PKF_CONFORMANCE_SUBDIR`),
     run `$PKF_MBT_BIN <argv>` there, capture stdout/stderr/exit + filesystem delta
     (created/modified) and deletions (the Phase 2d `fsDelta`/`fsDeleted` snapshot/diff).
   - **Differ**: port `Compare` (exit → json deep-equal with `jsonIgnorePaths` recursive
     key-drop + `unorderedPaths` → `mustContain`/`mustContainStderr` normalized substring →
     `fsDelta` → `fsDeleted` → `stdoutEmpty`/`stdoutNonEmpty`). Port `DiffJSON`
     (type-aware scalar compare) + `normalizeText`. These semantics are the contract — they
     must match `conformance/differ.go` exactly.
   - **Golden loader**: read `golden/<id>/{stdout,stderr,exit,fsdelta,fsdeleted}` (+ `env`).
   - **Entry point**: a `moon test` (or `moon run`) that runs all scenarios strict and fails
     on any RED (the replacement for `TestCandidateParity` + `PKF_CONFORMANCE_STRICT=1`).
     Drop the Go-oracle-only tests (`TestOracleSelfConsistency`/`TestUpdateGolden`) — there
     is no Go oracle anymore; the goldens are the frozen ground truth.
   - **Golden regeneration** is now from the MoonBit pkf itself (a `--update` mode capturing
     `PKF_MBT_BIN` output) so future intentional changes can re-freeze. (Migration-era
     Go-differential is over; goldens now lock MoonBit's own contracted behavior.)
   - **VERIFY**: the MoonBit runner reports **41/41 PASS** against the unchanged goldens,
     matching what the Go harness reported. This is the gate that proves the port is faithful.
2. **Delete the Go pkf implementation**: `cmd/pkf/`, `internal/`, `go.mod`, `go.sum`, and
   `conformance/*.go`. Confirm nothing else imports them.
3. **CI cutover**: rewrite `conformance.yml` to build the MoonBit pkf + run the MoonBit
   conformance runner (no `setup-go`, no `go build` oracle). Rewrite `test.yml` to build the
   MoonBit pkf and run the dogfood Taskfile (`pkf run -f examples/dogfood/Taskfile.pkl ci`)
   — replacing `go install ./cmd/pkf`. Update `nix.yml` path filters (drop `go.mod`/`go.sum`/
   `cmd/**`/`internal/**`, add `pkf-mbt/**`/`flake.nix`). No `setup-go` anywhere.
4. **Taskfile.pkl cutover**: delete/rewrite the Go tasks — drop `test:go`/`test:race`/`vet`;
   `conformance` → run the MoonBit runner; `lintTaskfile`/`testWorkflow` → invoke the built
   MoonBit `pkf` binary instead of `go run ./cmd/pkf`; rewire `preflight`/`pre-commit` to the
   new task set (+ a `moon check`/`moon test -p loader` gate for the MoonBit sources).
5. **flake devShell + docs**: devShell `go`/`gopls` → the moon toolchain (from the
   moonbit-overlay already an input) + `pkl`. README: delete the `### Go`/`go install`
   section, fix the devShell note, fix the `go install` example; state pkf is a MoonBit
   binary.

### Out of scope
- Promoting `pkf-mbt/` to the repo root (no churn; paths stay `./pkf-mbt/`).
- Changing the Pkl schema, examples, or the release/flake distribution (Phase 4, done).
- Windows / Intel-macOS (already unsupported).

## Contract bar

The MoonBit conformance runner must report the **same 41/41 PASS** against the unchanged
frozen goldens that the Go `TestCandidateParity` (strict) reported — i.e. the port is
behavior-identical on the differ. After the purge, `grep -rn "\.go$"` / `go.mod` finds
nothing; `pkf-mbt.yml` + the new conformance + dogfood CI are green.

## Risks / mitigations

- **Differ fidelity** is the central risk: `DiffJSON` type-aware scalar compare,
  recursive `jsonIgnorePaths`, `normalizeText`, fsDelta/fsDeleted nil-vs-empty handling
  must match `differ.go` exactly or goldens spuriously RED/GREEN. Mitigation: port
  test-by-test against `differ_test.go`'s cases; gate on 41/41 parity with the retired Go
  harness (run both once, side by side, before deleting Go).
- **Scenario eval**: `scenarios.pkl` uses the `Conformance.pkl` schema; evaluating it via
  `@pkl` must yield the same fields the Go loader read. Mitigation: compare the MoonBit-
  evaluated scenario list against the Go `LoadScenarios` output for one run.
- **Losing the Go oracle**: goldens can no longer be regenerated from Go. Accepted — the
  migration is validated; goldens now lock MoonBit's own contracted behavior and are
  re-captured from the MoonBit pkf going forward.
- **Self-hosting the conformance runner**: it depends on `mizchi/pkl` to eval scenarios —
  the same dep pkf uses, so no new toolchain.

## Execution

Spec → plan (`docs/superpowers/plans/2026-06-24-phase5-cutover-retire-go.md`) →
subagent-driven. Order: (1) build the MoonBit conformance runner and prove 41/41 parity
WHILE the Go harness still exists (side-by-side), THEN (2) delete all Go, (3) CI cutover,
(4) Taskfile cutover, (5) devShell+docs, (6) final review. Single PR `pkf-mbt-phase5` → main
when CI is green and `grep` finds no Go.

## Success criteria

- `conformance/` is a MoonBit module reporting **41/41 PASS** strict against the unchanged
  goldens; no `*.go` remains anywhere; `go.mod`/`go.sum`/`cmd/pkf`/`internal` are gone.
- CI: conformance (MoonBit runner) + test (MoonBit dogfood) + pkf-mbt smoke + Nix all green;
  no `setup-go` in any workflow.
- `Taskfile.pkl` `preflight` runs only MoonBit/pkl tooling; `flake.nix` devShell has the moon
  toolchain, not Go; README has no `go install`.
- The release/flake distribution and the Pkl schema package are unchanged and still work.
