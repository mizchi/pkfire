# Phase 3 — Self-Contained Pkl Evaluation (drop mpkl) Design

**Date:** 2026-06-23
**Status:** Approved design
**Part of:** pkf Go→MoonBit canonical-binary migration (see `2026-06-22-moonbit-pkf-main-switch-design.md`)

## Goal

Make the MoonBit `pkf` binary evaluate `Taskfile.pkl` **fully in-process**, removing the
external `mpkl` subprocess and its CI build step, so `pkf` ships as a single
self-contained native binary. **The API contract (JSON output, exit codes, side
effects) does not change** — this is a packaging/runtime change, verified against the
Go oracle by the existing conformance harness.

## Background

The MoonBit pkf already has an embedded Pkl loader
(`pkf-mbt/src/loader/loader.mbt` → `eval_module_path`) that resolves local files and
**already-cached** `package://` URIs. It falls back to spawning `mpkl eval -f json`
(`eval_taskfile_via_subprocess` in `main.mbt:1901`) in exactly these cases:

1. **HTTP `package://` imports that are not yet cached** — `read_module_source` raises
   `LoaderError("embedded loader does not fetch HTTP modules …")` (`loader.mbt:218`).
2. **Glob imports** (`import* "…"`) — `load_recursive` skips them with
   `if decl.is_glob { continue }` (`loader.mbt:269`).

The reference implementations for the missing pieces already exist in the `mpkl` CLI
(`pkf-mbt/.mooncakes/mizchi/pkl/cmd/mpkl/`), but live in a `main` package and are not
importable. **Decision (locked): port them into pkfire** under
`pkf-mbt/src/loader/`, keeping everything in one repo with no cross-repo release cycle.

The Go oracle (`internal/config/config.go` → `pkl.NewEvaluator` from Apple's pkl-go)
resolves HTTP packages and globs internally with no subprocess. That is the contract
reference Phase 3 must match.

## Scope

### In scope

1. **Port the package downloader into `pkf-mbt/src/loader/`** as new modules:
   - `fetch.mbt` — HTTP(S) GET with redirect following (5-hop limit), string + bytes
     variants. Ported from `cmd/mpkl/fetch_native.mbt`.
   - `zip.mbt` — ustar-free ZIP reader: EOCD scan, central-directory parse, stored +
     deflate (`@zlib.deflate_decompress`) entries, path-safety check, extract-to-dir.
     Ported from `cmd/mpkl/package_download.mbt` (`read_zip_entries`, `extract_zip_to_dir`).
   - `download.mbt` — `download_package_uri_to_cache(uri)`: fetch metadata JSON →
     read `packageZipUrl` + `packageZipChecksums.sha256` → fetch zip → verify sha256 →
     extract into the cache dir → write the metadata file. Ported from
     `cmd/mpkl/package_download.mbt`. **The cache layout (`~/.cache/pkl-mbt/package-2/…`)
     must be byte-identical to what `loader.mbt` already resolves package:// against**,
     so a download followed by re-resolution Just Works.

2. **Wire the downloader into `read_module_source`** (`loader.mbt`): on a `package://`
   cache miss, call `download_package_uri_to_cache` then re-resolve from cache; remove
   the `https://`/`http://` hard `LoaderError` and fetch instead.

3. **Implement glob imports** in `load_recursive`: replace `if decl.is_glob { continue }`
   with expansion that resolves the glob against the module's directory (local or cached
   package dir), loads each matched module recursively, and registers the glob result in
   the session — matching pkl-go's `import*` semantics for the shapes our Taskfiles use.

4. **Embedded-loader robustness (prerequisite for dropping the subprocess).** Once the
   subprocess is gone, every Taskfile that previously fell back must succeed (or fail
   with the same contract error as Go) on the embedded loader alone. Specifically:
   - Fix the latent `direct`-property crash on `workflowTests` that omit `direct`
     (memory: Phase 2b deferral #3) so a schema-legal Taskfile does not panic.
   - Remove the `EvalError`-only fallback gap: there is no subprocess to fall back to,
     so an unsupported construct must surface as a clean error matching Go's exit/stderr
     contract, never a silent wrong answer.

5. **Remove the subprocess.** Delete `eval_taskfile_via_subprocess` and the
   `mpkl eval` invocation; `eval_taskfile` uses the embedded loader only. Remove the
   `mpkl` clone/build/PATH step from `.github/workflows/pkf-mbt.yml` (lines ~50–64).
   `pkf` no longer depends on an `mpkl` binary at runtime or build time.

### Out of scope (deferred, unchanged from prior phases)

- BLAKE3/zstd cache (cache stays SHA-256 + tar.gz, behavior-only contract).
- `--module-path` overlays, project-file `amends`, dependency-alias rewriting
  (not used by our Taskfiles; if a Taskfile needs them, it errors cleanly — it does not
  silently diverge).
- Cross-build matrix + distribution swap (Phase 4) and final cutover (Phase 5).

## Contract bar

Unchanged: **behavioral + JSON identity.** A Taskfile that `amends` an HTTP
`package://` and one that uses a glob import must produce **byte-identical evaluated
JSON** (after the harness's existing volatile-path normalization) between the Go oracle
and the MoonBit candidate, with the candidate spawning **no subprocess**.

## Testing strategy

Two layers, both **offline-deterministic in CI** (no live registry fetch):

1. **MoonBit unit tests (`moon test`)** for the ported primitives:
   - `zip.mbt`: build a known archive (stored + deflate entries via `@zlib`), round-trip
     through `read_zip_entries`/`extract_zip_to_dir`, assert contents + path-safety
     rejection of `../` entries.
   - `download.mbt`: drive `download_package_uri_to_cache` against a **local fixture
     HTTP server** (loopback) serving canned metadata + zip; assert the cache dir is
     populated at the exact layout `loader.mbt` resolves, and sha256-mismatch fails.
   - `fetch.mbt`: redirect-following against the same loopback fixture.

2. **Conformance scenarios** (Go oracle vs MoonBit candidate), added to
   `conformance/scenarios.pkl`:
   - A `package://` **amends** scenario and a **glob import** scenario. Both caches
     (pkl-go's and pkl-mbt's) are **pre-seeded from committed fixtures** in the harness
     setup so neither binary hits the network; the assertion is JSON-output parity, and
     the candidate must resolve from cache **without** the (now-removed) subprocess.
   - The oracle self-consistency gate (`TestOracleSelfConsistency`) and the candidate
     ledger (`TestCandidateParity`, strict) must stay green.

## Execution

Spec → plan (`docs/superpowers/plans/2026-06-23-phase3-self-contained-pkl.md`) →
subagent-driven execution, fresh subagent per task with spec + code-quality review, as
in Phases 0–2d. Single PR `pkf-mbt-phase3` → main when the ledger is green and no
`mpkl` reference remains.

## Success criteria

- `pkf run/list/info <task>` evaluates Taskfiles that use HTTP `package://` amends and
  glob imports with **zero subprocess**, producing JSON identical to Go.
- `grep -r mpkl pkf-mbt/ .github/` returns no runtime/build dependency (only history/docs).
- Conformance ledger strict-green including the two new scenarios; new `moon test` units
  green; macOS + ubuntu CI green.
