# Phase 4 — Cross-Build + Distribution Swap Design

**Date:** 2026-06-23
**Status:** Approved design (zlib approach spike-validated)
**Part of:** pkf Go→MoonBit canonical-binary migration (`2026-06-22-moonbit-pkf-main-switch-design.md`)

## Goal

Build the MoonBit `pkf` binary in CI for all four release targets and SWAP the release
distribution from the Go binary to the MoonBit binary, **without changing the
download/asset contract** that `action.yml` and consumers depend on.

## Background / current state

- **Release workflow** `.github/workflows/pkl-publish.yml` triggers on `pkfire@*` tags
  and, on a single `ubuntu-latest` runner, cross-compiles the **Go** `pkf` for four
  targets via `GOOS/GOARCH … CGO_ENABLED=0 go build`, tars each as
  `pkf-<target>.tar.gz` (+ `.sha256`) containing a binary named `pkf`, and `gh release`s
  them. Targets: `linux-amd64`, `linux-arm64`, `darwin-amd64`, `darwin-arm64` (no Windows).
- **`action.yml`** maps `RUNNER_OS-RUNNER_ARCH` → `<os>-<arch>` and downloads
  `releases/download/<tag>/pkf-<plat>.tar.gz`, extracting a `pkf` binary onto PATH. **This
  asset-name + inner-binary-name contract must be preserved exactly.**
- **MoonBit native build is host-only** (MoonBit→C→host `cc`); it does **not**
  cross-compile. So cross-targeting requires a **GitHub runner matrix**, one runner per
  OS/arch — not env-driven cross-compilation.
- The MoonBit native backend names its output `pkf.exe` on **all** platforms.

## Locked decisions

1. **zlib: use `mizchi/zlib`'s pure-MoonBit implementation, dropping the native C-FFI
   variant** — so the binary has **zero system-zlib dependency** (no `zlib1g-dev`, no nix
   `CPATH`, no `-lz`), and each runner only needs `moon` + a C compiler.
   **Spike-validated (2026-06-23):** switching `pkf-mbt/src/cmd/pkf/moon.pkg` import
   `mizchi/zlib/native` → `mizchi/zlib` and removing its `link.native.cc-link-flags = -lz`
   makes `moon build --target native --release` succeed with **no zlib env**; the resulting
   binary links only `libSystem`/libc (no `libz`), and the conformance ledger stays
   **41/41 strict-green** (the pure gzip/deflate round-trips the cache; cache contract is
   behaviour-only, not byte-identical to Go). The loader package already used the pure
   variant since Phase 3.
2. **flake.nix: build the MoonBit `pkf` from source** via `moon build` inside a Nix
   derivation (replacing the `buildGoModule` derivation), keeping the `makeWrapper`
   `postInstall` so the bundled `pkl` CLI stays on PATH.
3. **Replace the Go build in `pkl-publish.yml` with the MoonBit runner matrix.** Asset
   names, inner binary name (`pkf`), tag trigger, and `.sha256` sidecars are unchanged.
   The Go `cmd/pkf` source is **retained** until Phase 5 (cutover/retire).

## Scope

### In scope
1. **Drop the native zlib FFI** (the spike): `cmd/pkf` imports pure `mizchi/zlib`, remove
   the `-lz` link block. Simplify `pkf-mbt/scripts/build-native.sh` to a plain
   `moon build --target native --release` (drop the `cc -lz` probe + nix `CPATH/LIBRARY_PATH`
   fallback). Remove the `zlib1g-dev` apt step from `.github/workflows/pkf-mbt.yml`.
2. **Cross-build runner matrix** — rewrite `pkl-publish.yml`'s build to a matrix:
   `linux-amd64`→`ubuntu-latest`, `linux-arm64`→`ubuntu-24.04-arm`, `darwin-amd64`→`macos-13`,
   `darwin-arm64`→`macos-14`. Each runner: install moon, `moon build --target native
   --release`, `mv …/pkf.exe pkf`, `tar -czf pkf-<target>.tar.gz pkf`, compute `.sha256`,
   `actions/upload-artifact`. A final `release` job downloads all artifacts and `gh release`s
   them under the **identical** asset names. Preserve the `version`/`-X main.version` intent
   (pass the tag version into the binary if the MoonBit `pkf` supports a version string;
   otherwise document the gap — the MoonBit `pkf_version()` is currently a constant).
3. **flake.nix** — replace `buildGoModule` with a `moon`-source-build derivation producing
   `bin/pkf` (rename from `pkf.exe`), keeping the `pkl`-on-PATH wrapper and `meta.platforms`.
4. **Validation** — the produced asset names exactly match `action.yml`'s URL template; a
   built binary runs (`pkf --version`, `pkf list`) on its target; conformance stays
   41/41; `scripts/check-version-consistency.sh` still passes.

### Out of scope (Phase 5)
- Deleting the Go `cmd/pkf`, `internal/`, `flake.nix` devShell Go bits, and the Go side of
  the conformance harness. Final canonical flip + docs/README cutover.
- Windows target (never shipped).
- Fully-static libc (the binary links libc dynamically; acceptable — libc is universal).

## Contract bar

The release must publish, for each of the four targets, an asset named exactly
`pkf-<os>-<arch>.tar.gz` (+ `.sha256`) whose single extracted binary is named `pkf` and
runs on that platform. `action.yml` is unchanged and must resolve+download+exec the
MoonBit binary identically to the Go one. Behavioural parity is the existing conformance
ledger (41/41 strict).

## Risks / mitigations

- **MoonBit version string**: Go bakes `-X main.version`. The MoonBit `pkf_version()` is a
  constant (`0.0.1`). Phase 4 should thread the release tag into the MoonBit version output
  (build-time injection or a generated source) so `pkf --version` matches the tag; if not
  trivially supported, document and defer to Phase 5 (low risk — version string only).
- **`ubuntu-24.04-arm` / `macos-13` runner availability**: GitHub-hosted arm64 Linux
  runners are free for public repos (pkfire is public); `macos-13` is the last Intel image.
  If an image is unavailable, fall back (e.g. cross via QEMU or drop a niche target) — the
  plan must verify each runner actually builds.
- **glibc baseline**: a linux binary built on ubuntu-24.04 won't run on much older glibc
  (the Go static binary had no such floor). Acceptable for the supported matrix; note it.
- **Performance**: pure-MoonBit deflate is slower than C zlib for large cache tarballs.
  Acceptable for task-output caching; conformance covers correctness.

## Execution

Spec → plan (`docs/superpowers/plans/2026-06-23-phase4-cross-build-distribution.md`) →
subagent-driven execution. Task 1 (zlib drop + build simplification) is spike-validated and
lands first; Tasks 2–3 (CI matrix, flake) follow with per-task verification; Task 4
validates the end-to-end asset contract. Single PR `pkf-mbt-phase4` → main when CI is green
and a matrix dry-run produces correctly-named assets.

## Success criteria

- `pkl-publish.yml` builds the MoonBit `pkf` on a 4-runner matrix and would publish
  `pkf-{linux,darwin}-{amd64,arm64}.tar.gz` (+ `.sha256`), each containing a `pkf` binary
  with **no system-zlib dependency**.
- `build-native.sh` is a plain `moon build` (no zlib env); `pkf-mbt.yml` has no zlib install.
- `flake.nix` packages the MoonBit `pkf` from source with `pkl` on PATH.
- `action.yml` unchanged; asset names byte-match its URL template; conformance 41/41.
