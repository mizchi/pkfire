# Phase 3 — Self-Contained Pkl Evaluation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make MoonBit `pkf` evaluate `Taskfile.pkl` fully in-process (HTTP `package://`
download + glob imports), then delete the `mpkl` subprocess and its CI build, without
changing the API/JSON contract.

**Architecture:** Port the `mpkl` CLI's HTTP fetch + ZIP reader + package downloader
(currently in the non-importable `cmd/mpkl/` package of the `mizchi/pkl` mooncake) into
new modules under `pkf-mbt/src/loader/`. Wire them into the existing embedded loader
(`loader.mbt → eval_module_path/read_module_source/load_recursive`). Make the embedded
loader robust enough to be a strict superset of what the subprocess handled, then remove
the subprocess and the CI `mpkl` step.

**Tech Stack:** MoonBit (native target), `@zlib` (deflate), `@crypto` (sha256), `@fs`,
`@http`, existing `@pkl`/`@loader`. Conformance: Go differential harness in `conformance/`.

**Reference sources to port from (read-only):**
- `pkf-mbt/.mooncakes/mizchi/pkl/cmd/mpkl/fetch_native.mbt` — `fetch_uri`, `fetch_uri_bytes`, redirect loop.
- `pkf-mbt/.mooncakes/mizchi/pkl/cmd/mpkl/package_download.mbt` — ZIP reader
  (`read_u16_le`/`read_u32_le`/`find_zip_eocd`/`read_zip_entries`/`zip_entry_path_is_safe`/
  `extract_zip_to_dir`), cache-layout helpers (`package_cache_parts`/`package_cache_roots`/
  `default_package_cache_root`/`package_cache_relative`/`package_metadata_url_from_uri`/
  `extract_package_zip_url`/`extract_package_zip_sha256`), and
  `download_package_uri_to_cache`/`resolve_or_download_package_uri_to_cache`.

**Cache-layout invariant (critical):** The ported downloader MUST write into the same
cache path that `loader.mbt:read_module_source` resolves `package://` against
(`~/.cache/pkl-mbt/package-2/<host>/<path>/<name>@<version>/package/<file>`). Before
writing download.mbt, read `loader.mbt:145-210` and reuse its exact path derivation so a
download immediately satisfies the subsequent re-resolution.

---

## Task 1: Port HTTP fetch with redirects → `loader/fetch.mbt`

**Files:**
- Create: `pkf-mbt/src/loader/fetch.mbt`
- Reference: `pkf-mbt/.mooncakes/mizchi/pkl/cmd/mpkl/fetch_native.mbt`
- Test: add a `loader/fetch_wbtest.mbt` (whitebox test)

- [ ] **Step 1: Read the reference** `fetch_native.mbt` in full. It exposes
  `fetch_uri(url) -> String?` and `fetch_uri_bytes(url) -> Bytes?` with a 5-hop redirect
  loop reading the `Location` header from `@http.get`.

- [ ] **Step 2: Write a failing whitebox test** in `loader/fetch_wbtest.mbt` that starts
  a loopback HTTP server (use `@http`/socket helpers already in the dep tree; mirror how
  mpkl's own tests stand one up — search `.mooncakes/mizchi/pkl` for `*_wbtest.mbt`/
  `*_test.mbt` using a test server) serving `/a` → 302 `Location: /b`, `/b` → `200 "hello"`.
  Assert `fetch_uri("http://127.0.0.1:PORT/a") == Some("hello")`. If no in-process test
  server primitive exists, instead unit-test the redirect-resolution helper (relative→
  absolute Location join) in isolation and cover the network path in Task 3's fixture.

- [ ] **Step 3: Run it, verify it fails** (`cd pkf-mbt && moon test -p loader`). Expected:
  FAIL (functions undefined).

- [ ] **Step 4: Port the implementation** into `fetch.mbt`. Keep function names
  `fetch_uri`/`fetch_uri_bytes`. Adapt: module-private (no `pub` unless loader.mbt needs
  it cross-file — same package, so plain `fn`/`async fn` is fine), and any error type
  becomes a returned `?`/`None` exactly as the reference does (no new suberror).

- [ ] **Step 5: Run the test, verify it passes.** `moon test -p loader`.

- [ ] **Step 6: Native build smoke.** `bash pkf-mbt/scripts/build-native.sh` → 0 errors.

- [ ] **Step 7: Commit.** `git add pkf-mbt/src/loader/fetch.mbt pkf-mbt/src/loader/fetch_wbtest.mbt`
  then `git commit -m "pkf-mbt phase3: port in-process HTTP fetch with redirects"`.

---

## Task 2: Port the ZIP reader → `loader/zip.mbt`

**Files:**
- Create: `pkf-mbt/src/loader/zip.mbt`
- Reference: `pkf-mbt/.mooncakes/mizchi/pkl/cmd/mpkl/package_download.mbt:346-490` (ZIP region)
- Test: `pkf-mbt/src/loader/zip_wbtest.mbt`

- [ ] **Step 1: Read** the ZIP region of `package_download.mbt`: `ZipEntry` struct,
  `bytes_slice`/`read_u16_le`/`read_u32_le`/`find_zip_eocd`/`read_zip_entries`
  (stored=0 + deflate=8 via `@zlib.deflate_decompress`, rejects zip64),
  `zip_entry_path_is_safe`, `extract_zip_to_dir`.

- [ ] **Step 2: Write a failing whitebox test** `zip_wbtest.mbt`:
  build a minimal ZIP in-memory with two entries — `"dir/a.txt"` = `"A"` (stored) and a
  deflate entry `@zlib.deflate_compress(b"BBBB")` for `"b.txt"`. Assert `read_zip_entries`
  returns both with correct paths/contents, and that `zip_entry_path_is_safe("../evil")`
  is `false`. (If hand-building a stored+deflate ZIP byte layout is too fiddly, generate
  the fixture bytes once with a script and embed them as a `b"..."` literal — record the
  generator command in a comment.)

- [ ] **Step 3: Run it, verify it fails.** `moon test -p loader`.

- [ ] **Step 4: Port** the ZIP reader into `zip.mbt`. Convert the reference's bare
  `raise` / `package_download_error` into the loader's error style — raise
  `LoaderError(msg)` (the suberror already declared in `loader.mbt:23`) so failures join
  the existing loader error path. Keep `extract_zip_to_dir(data, package_dir)` signature.

- [ ] **Step 5: Run the test, verify it passes.**

- [ ] **Step 6: Native build smoke.** `bash pkf-mbt/scripts/build-native.sh`.

- [ ] **Step 7: Commit.** `pkf-mbt phase3: port in-process ZIP reader/extractor`.

---

## Task 3: Port the package downloader → `loader/download.mbt`

**Files:**
- Create: `pkf-mbt/src/loader/download.mbt`
- Reference: `pkf-mbt/.mooncakes/mizchi/pkl/cmd/mpkl/package_download.mbt` (cache + download region)
- Modify: reuse `loader.mbt` cache-path helpers (do NOT duplicate path logic — extract a
  shared helper if loader.mbt's resolver is currently private/inline).
- Test: `pkf-mbt/src/loader/download_wbtest.mbt`

- [ ] **Step 1: Read** `loader.mbt:145-234` (how it parses `package://` → cache fs path)
  AND the mpkl cache/download helpers. Confirm the exact cache root + relative layout.
  The downloader must populate precisely the path loader.mbt will then read.

- [ ] **Step 2: Write a failing whitebox test** `download_wbtest.mbt`: stand up a loopback
  server serving canned package metadata JSON (`{"packageZipUrl":"http://127.0.0.1:PORT/p.zip",
  "packageZipChecksums":{"sha256":"<hash of fixture zip>"}}`) and the fixture zip bytes
  from Task 2. Point the cache root at a temp dir (add a test-only override of
  `default_package_cache_root`, e.g. honoring an env var the test sets — verify mpkl's
  helper already reads such an env; if so reuse it). Call
  `download_package_uri_to_cache("package://127.0.0.1:PORT/pkg@1.0.0")` and assert the
  cache dir now contains the extracted files at the layout loader.mbt resolves, and that a
  wrong `sha256` makes it fail.

- [ ] **Step 3: Run it, verify it fails.**

- [ ] **Step 4: Port** `download_package_uri_to_cache` + `package_metadata_url_from_uri` +
  `extract_package_zip_url` + `extract_package_zip_sha256` + cache-parts helpers into
  `download.mbt`. Calls into `fetch.mbt` (Task 1) and `zip.mbt` (Task 2). On failure raise
  `LoaderError` (not `println`+return-false as mpkl does — the loader caller wants a raise).

- [ ] **Step 5: Run the test, verify it passes.**

- [ ] **Step 6: Native build smoke.**

- [ ] **Step 7: Commit.** `pkf-mbt phase3: port in-process package:// downloader`.

---

## Task 4: Wire the downloader into `read_module_source`

**Files:**
- Modify: `pkf-mbt/src/loader/loader.mbt:214-235` (`read_module_source`)

- [ ] **Step 1: Write a failing whitebox test** (extend `download_wbtest.mbt` or a new
  `loader_wbtest.mbt`): with the loopback fixture + temp cache from Task 3 but cache
  **empty**, call `read_module_source("package://127.0.0.1:PORT/pkg@1.0.0#/Mod.pkl")` and
  assert it returns the module text (i.e. it downloaded-then-read). Also assert an
  `http://`/`https://` module URL now fetches instead of raising.

- [ ] **Step 2: Run it, verify it fails** (currently raises `LoaderError("does not fetch
  HTTP modules")`).

- [ ] **Step 3: Implement.** In `read_module_source`:
  - Replace the `https://`/`http://` raise (`loader.mbt:218-222`) with `fetch_uri(path)` →
    `Some(s) => s` / `None => raise LoaderError("failed to fetch module \{path}")`.
  - For `package://`: try the existing cache resolution; on cache-miss (`@fs` read fails /
    file absent) call `download_package_uri_to_cache(uri)` once, then re-resolve. If still
    absent, raise the same `could not read module` error as today.

- [ ] **Step 4: Run the test, verify it passes.**

- [ ] **Step 5: Native build smoke + full `moon test -p loader`.**

- [ ] **Step 6: Commit.** `pkf-mbt phase3: fetch+download package:// in read_module_source`.

---

## Task 5: Implement glob imports in `load_recursive`

**Files:**
- Modify: `pkf-mbt/src/loader/loader.mbt:267-275` (the `if decl.is_glob { continue }` block)
- Reference Go semantics: `internal/config` + how pkl-go expands `import*`.
- Test: `pkf-mbt/src/loader/glob_wbtest.mbt` + a fixture dir under `pkf-mbt/test/`

- [ ] **Step 1: Determine glob semantics.** Read how `@pkl.parse_source` exposes
  `decl.is_glob`/`decl.uri`, and check the Go oracle's output for a glob import to learn
  the exact member shape pkl produces (a Mapping keyed by resolved module URI). Write that
  expectation down in the test.

- [ ] **Step 2: Write a failing whitebox test:** a fixture module `globbed.pkl` that does
  `import* "sub/*.pkl"` over two fixture files; eval via `eval_module_path` and assert the
  resulting JSON mapping has both modules' keyed values, matching the documented pkl shape.

- [ ] **Step 3: Run it, verify it fails** (glob currently skipped → key absent).

- [ ] **Step 4: Implement glob expansion:** resolve `decl.uri`'s glob against the module's
  base dir (local dir, or the cached package dir for `package://...` globs) using the
  filesystem walk already present (`expand_glob`/`glob_match` live in
  `pkf-mbt/src/cmd/pkf/main.mbt` — if not reachable from `loader`, port the minimal matcher
  into `loader/glob.mbt`). Load each matched module via `load_recursive`, and register the
  glob binding in the session so `session.eval_path` produces the keyed mapping. Match the
  pkl member shape captured in Step 1.

- [ ] **Step 5: Run the test, verify it passes.**

- [ ] **Step 6: Native build smoke.**

- [ ] **Step 7: Commit.** `pkf-mbt phase3: expand glob imports in embedded loader`.

---

## Task 6: Robustness + remove the subprocess

**Files:**
- Modify: `pkf-mbt/src/cmd/pkf/main.mbt:1853-1913` (`eval_taskfile`, delete
  `eval_taskfile_via_subprocess`)
- Modify: `pkf-mbt/src/loader/loader.mbt` and/or `@pkl` plan parsing for the `direct` crash
- Test: a fixture Taskfile whose `workflowTests` omit `direct`

- [ ] **Step 1: Reproduce the `direct` crash.** Create a schema-legal Taskfile whose
  `workflowTests` entry omits `direct`. Run `pkf info -f <it>` (built native). Confirm it
  currently dies (`Cannot find property 'direct'`) when forced through the embedded loader.
  Write a whitebox/CLI test capturing the expected success output (parity with Go).

- [ ] **Step 2: Fix** the parser to treat `direct` as optional (default empty), per memory
  Phase 2b deferral #3. Re-run → passes.

- [ ] **Step 3: Remove the subprocess.** In `main.mbt`: delete `eval_taskfile_via_subprocess`
  and the `mpkl eval` call; `eval_taskfile` now only calls `@loader.eval_module_path` and,
  on `LoaderError`, dies with a clean message + exit 1 (matching Go's contract for an
  unevaluable Taskfile — verify against the Go oracle's stderr/exit for the same bad input).
  Remove any now-unused `@process` import.

- [ ] **Step 4: Verify no behavioral regression.** Build native; run the existing
  conformance ledger locally (`PKF_MBT_BIN=<native> PKF_GO_BIN=<go> PKF_CONFORMANCE_STRICT=1
  go test ./conformance/...`). Must stay green — the embedded loader now serves every
  scenario with no subprocess.

- [ ] **Step 5: Commit.** `pkf-mbt phase3: optional workflowTests.direct + drop mpkl subprocess`.

---

## Task 7: CI cleanup + conformance scenarios for package:// and glob

**Files:**
- Modify: `.github/workflows/pkf-mbt.yml` (remove the `mpkl` clone/build/PATH step, ~50-64)
- Modify: `conformance/scenarios.pkl` (+ `Conformance.pkl` if a new field is needed)
- Create: fixture package + glob Taskfiles under `examples/` and committed cache seed under
  `conformance/fixtures/` (or the harness's fixture dir)
- Modify: `conformance/runner.go`/harness setup to pre-seed both caches offline

- [ ] **Step 1: Add the glob conformance scenario.** Reuse the Task 5 glob fixture as an
  `examples/glob-import/` Taskfile; add a `scenarios.pkl` entry asserting `list --json`
  (or `info --json`) parity between Go and MoonBit. Pre-seed nothing (glob is local files).
  Capture goldens, run oracle self-consistency + candidate parity green.

- [ ] **Step 2: Add the package:// conformance scenario, offline.** Commit a fixture
  package (metadata + extracted files) and seed BOTH caches in harness setup: pkl-go's
  cache (`~/.pkl` / `PKL_CACHE_DIR`) and pkl-mbt's (`~/.cache/pkl-mbt` / its env override)
  pointed at temp dirs populated from the committed fixture, so neither binary networks.
  Add a Taskfile `amends` that fixture package; scenario asserts JSON parity. The candidate
  must resolve from cache with **no subprocess**.

- [ ] **Step 3: Remove the CI `mpkl` build step** from `pkf-mbt.yml`. The native build no
  longer needs `mpkl` on PATH. Keep the conformance + smoke jobs.

- [ ] **Step 4: Verify** `grep -rn 'mpkl' pkf-mbt/src .github/workflows` shows no runtime/
  build dependency (matches in `.mooncakes/` vendored dep and docs are fine).

- [ ] **Step 5: Run full local gate:** native build, `moon test -p loader`,
  `PKF_CONFORMANCE_STRICT=1 go test ./conformance/...`. All green.

- [ ] **Step 6: Commit.** `pkf-mbt phase3: package:// + glob conformance, drop CI mpkl build`.

---

## Task 8: Final review + PR

- [ ] **Step 1:** Dispatch a final code-quality + spec-compliance review over the whole
  branch diff (spec §Scope + §Success criteria as the checklist).
- [ ] **Step 2:** Fix any findings (fresh subagent).
- [ ] **Step 3:** Push `pkf-mbt-phase3`, open PR → main with summary + test plan; wait for
  macOS + ubuntu CI green before reporting back.

---

## Self-review notes

- **Spec coverage:** Tasks 1–3 = port downloader; Task 4 = wire HTTP/package://; Task 5 =
  glob; Task 6 = robustness + drop subprocess; Task 7 = CI + conformance; Task 8 = review.
  Covers every In-scope bullet of the spec.
- **Cache-layout invariant** is called out explicitly in Tasks 1-pre and 3 — the single
  highest-risk integration point (a mismatch silently re-downloads or fails to resolve).
- **Offline determinism** (spec testing strategy) is enforced in Tasks 1/3 (loopback
  fixtures) and Task 7 Step 2 (pre-seeded caches).
- **Type consistency:** all ported failures funnel into the existing `LoaderError`
  (`loader.mbt:23`); `fetch_uri`/`fetch_uri_bytes`/`extract_zip_to_dir`/
  `download_package_uri_to_cache` keep their reference signatures.
