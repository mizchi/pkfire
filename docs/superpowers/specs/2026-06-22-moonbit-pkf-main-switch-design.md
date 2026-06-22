# Switch the canonical `pkf` binary from Go to MoonBit

**Date:** 2026-06-22
**Status:** Design approved — Phase 0 ready for planning
**Scope:** Multi-phase migration. This document holds the overall design plus
the detailed design of the first sub-project (Phase 0). Each later phase gets
its own spec → plan → implementation cycle.

## Goal

Make the MoonBit implementation (`pkf-mbt/`) the **sole** shipped `pkf` binary,
replacing the Go implementation (`cmd/pkf/`), **without changing the user-facing
API contract**. The Go binary stays canonical until MoonBit reaches full
contract parity; the switch is the last step.

## Non-goals

- Rewriting the Pkl schema (`pkl/Taskfile.pkl`). The schema is the contract and
  stays fixed.
- Changing CLI surface, flag names, `--json` shapes, exit codes, or the
  `PKF_*` / `PKFIRE_*` environment contract.
- Byte-for-byte parity of human-readable text output (see Contract bar below).
- Cross-binary cache interop with Go (see Cache decision below).

## Locked decisions

| Question | Decision |
|---|---|
| End state | MoonBit is the **single** `pkf`; close the full parity gap first, then flip. |
| Contract bar | **Behavioral + JSON identity.** `--json` output shapes, exit codes, env contract, Pkl schema, and side-effects (cache hit/miss behavior, output files, hook installs, init/format/migrate writes) must match exactly. Human-readable text must be *semantically equivalent* — minor wording, spacing, and color differences are allowed. |
| Cache format | **Behavior-only contract.** MoonBit keeps its native format (SHA-256 + tar.gz). hit/miss correctness, restore correctness, and the action-key *canonical string* must match Go; the final hash value and archive codec are internal. Do **not** block on BLAKE3 / zstd landing in MoonBit. Go-populated cache entries are not reused (separate namespace / regenerate on switch). |
| Pkl evaluation | **Fully self-contained, single binary.** Drop the `mpkl` subprocess fallback; bring the HTTP `package://` downloader and glob import in-process. The shipped artifact is one `pkf` executable with no `mpkl` runtime dependency. |
| `go install` channel | **Dropped.** `go install github.com/mizchi/pkfire/cmd/pkf@latest` has no MoonBit equivalent. Acquisition moves to release-asset download + Nix. This is an accepted change to the *acquisition channel* only; the CLI/JSON/schema contract is still preserved. |
| Strategy | **Oracle-driven incremental parity** (Strategy A) + crystallize Go outputs into frozen golden fixtures so the contract survives Go's removal. |

## Current-state summary (why this is multi-phase)

Findings from exploration of `cmd/pkf` (Go) and `pkf-mbt/` (MoonBit):

- **Go**: ~18 subcommands, `--json` on list/graph/info/describe/doctor/lint,
  4-target cross-build in `.github/workflows/pkl-publish.yml`, distributed via
  release assets, `go install`, Nix flake (`buildGoModule`), and the
  `mizchi/pkfire@v0` GitHub Action (downloads release asset).
- **MoonBit**: 6 subcommands implemented (`run`, `list`, `graph`, `affected`,
  `up`, `watch`); **no `--json` anywhere**; **zero tests** (`_test.mbt` count =
  0); cache format diverges (SHA-256 + tar.gz vs BLAKE3 + tar.zst); Pkl HTTP /
  glob imports shell out to `mpkl`; builds only on native runners (no 4-target
  matrix); version `0.0.1`, self-described "experimental rewrite".

The gap (12 missing subcommands, `--json` everywhere, self-contained Pkl,
distribution swap, tests) is too large for a single spec, hence the phase
decomposition.

> Caveat: the per-line MoonBit findings (stderr routing, exit codes, directory
> walk) came from a read-only Explore pass and are treated as leads. Each is
> re-verified against the running binary inside the phase that depends on it,
> via the Phase 0 harness rather than by re-reading source.

## Phase decomposition

Each phase is an independent sub-project (own spec → plan → implementation).

- **Phase 0 — Conformance harness + contract crystallization** *(detailed below)*.
  The verification engine. Produces a failing parity scoreboard that later
  phases turn green. Implements no missing command.
- **Phase 1 — Runtime foundation gaps.** Error→stderr routing, exit-code
  reconciliation to the contract, Taskfile upward-directory discovery,
  `version` / `help`, and the shared `--json` encoder infrastructure.
- **Phase 2 — Missing subcommands to parity** (harness-gated). Introspection
  (`list`/`graph`/`describe`/`info`/`affected` `--json` + formats); diagnostics
  (`doctor`, `lint`, `explain`, `completion`); mutation (`init`, `format`,
  `hooks`, `clean`, `migrate`, `cache`, `pkl-cache`). Verify `run`/`up`/`watch`
  parity and add their `--json`/flags.
- **Phase 3 — Self-contained Pkl evaluation.** In-process HTTP `package://`
  downloader + glob import; remove the `mpkl` subprocess and its CI build step.
- **Phase 4 — Distribution swap.** Build linux/darwin × amd64/arm64 via a native
  runner matrix; switch `pkl-publish.yml`, `flake.nix` (off `buildGoModule`),
  and confirm `action.yml` asset names (`pkf-<os>-<arch>.tar.gz`) are unchanged.
- **Phase 5 — Tests + cutover.** Port/expand the test suite, wire CI gates, flip
  the canonical binary, update docs/install instructions, retire (freeze) the Go
  tree.

## Phase 0 — detailed design

### Purpose

A differential harness that runs the Go `pkf` (oracle) and the MoonBit `pkf`
(candidate) over a shared scenario corpus and asserts contract-bar identity.
The Go outputs are captured as committed golden fixtures so the contract is
frozen and survives Go's eventual removal.

### Components / units

1. **Scenario corpus** — declarative scenarios, each
   `(Taskfile dir, argv, env, pre-state) → contract assertions`. Built on
   `examples/` plus added edge cases. Owns one clear job: enumerate the
   contract surface as runnable cases.
2. **Oracle runner** — runs the Go binary on every scenario, captures
   stdout/stderr/exit/fs-delta, writes golden fixtures under
   `conformance/golden/`. Goldens are committed (frozen source of truth).
3. **Candidate runner** — runs the MoonBit binary on the same scenarios with an
   isolated cache dir and working copy.
4. **Differ** — compares candidate vs golden per the contract bar (rules below).
5. **Coverage ledger** — a generated report (`conformance/LEDGER.md` or `--json`)
   of command/flag → scenario presence + pass/fail. This is the parity
   scoreboard later phases drive to green.

### Architecture & data flow

```
Conformance.pkl (typed scenarios)
        │  pkl eval -f json
        ▼
  scenario list ──► oracle runner (PKF_GO_BIN) ──► conformance/golden/<id>/...
        │                                              (committed)
        └────────► candidate runner (PKF_MBT_BIN) ──► temp capture
                                                          │
                       golden + candidate ──► differ ──► pass/fail + ledger
```

- The harness driver is a **Go program** under `conformance/` (reuses the
  existing Go module and toolchain; same language as the oracle). It locates
  both binaries via `PKF_GO_BIN` and `PKF_MBT_BIN` (built by the caller / CI),
  reads scenarios, runs them in isolated temp dirs, and diffs.
- Scenarios are authored in a **typed Pkl schema** `conformance/Conformance.pkl`
  (`argv`, `env`, `setup`, `assertions`), matching the repo's "define the
  contract with types" convention. The driver consumes them via
  `pkl eval -f json`.
- Wired as a pkfire task `conformance` (in the dogfood Taskfile) and a CI job
  that builds both binaries, then runs oracle-capture (or verifies committed
  goldens are current) and the candidate diff.

### Differ rules (contract bar)

- **`--json` invocations:** parse both sides as JSON, deep-equal. Arrays that Go
  emits unordered are compared order-insensitively; object keys are compared
  exactly. This is the primary, strict gate.
- **Exit codes:** exact integer match.
- **Side-effects:** snapshot the working tree + cache dir before/after; compare
  the fs delta (files created/modified by `init`, `format`, `hooks`, `clean`,
  `migrate`, and cached outputs). Cache hit/miss is asserted behaviorally (e.g.
  second run is a hit; `--no-cache` is a miss).
- **Human-readable text:** normalize (`--color never`, collapse whitespace,
  strip trailing space) then assert *semantic* expectations declared in the
  scenario (must-contain / must-match lines), **not** a byte diff against Go.
- **Env contract:** a probe Taskfile writes `PKF_*` / param env vars to a file;
  the differ asserts the candidate-produced env file matches the golden.

### File layout

```
conformance/
  Conformance.pkl          # typed scenario schema
  scenarios/*.pkl          # scenario instances (amend Conformance.pkl)
  golden/<scenario-id>/    # committed oracle captures (stdout/exit/env/fs)
  driver/                  # Go differ + runners
  LEDGER.md                # generated parity scoreboard
```

### Testing (TDD)

The harness is tooling, built test-first:

1. Red: one scenario — `list --json` on `examples/basic` — with no differ yet.
2. Green: implement scenario load → oracle capture → candidate run → JSON
   deep-equal, end-to-end for that one scenario.
3. Refactor, then expand the corpus command-by-command.

### Expected Phase 0 outcome

The corpus runs and most MoonBit scenarios are **RED** — that failing scoreboard
is the deliverable. It makes the parity backlog explicit and gives Phases 1–2
their Red tests. Phase 0 implements **no** missing subcommand.

### Risks / open items for Phase 0

- **Oracle availability in CI during transition:** CI must build both the Go and
  MoonBit binaries. Acceptable while Go remains in-tree (removed only in Phase
  5). The committed goldens let the harness run against MoonBit alone afterward.
- **Unordered JSON:** identify which Go `--json` arrays are order-significant vs
  not; encode per-field comparison policy in the scenario schema.
- **Side-effect isolation:** every scenario runs in a fresh temp dir with an
  isolated `PKFIRE_CACHE_DIR` to keep runs hermetic and parallelizable.
- **Golden drift:** goldens are regenerated by an explicit `conformance --update`
  path; CI fails if committed goldens are stale relative to the Go binary.

## Downstream contract notes (carried into later phases)

- `action.yml` asset names (`pkf-{linux,darwin}-{amd64,arm64}.tar.gz`, each
  extracting a single `pkf`) must stay identical so `mizchi/pkfire@v0` consumers
  are unaffected (Phase 4).
- `flake.nix` must build the MoonBit binary (no longer `buildGoModule`); options
  are a `moon`-based derivation or fetching the release asset (Phase 4).
- `pkf version` output format is contractual (Phase 1).
- The Pkl schema version / release-tag machinery (`pkfire@<ver>`, v-tags) is
  unaffected by the binary swap (Phase 4/5).
