# Phase 2d: MoonBit pkf mutation subcommands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox (`- [ ]`) steps.

**Goal:** Add the mutation subcommands `init`, `format`, `migrate`, `hooks`, `clean`, `cache`, `pkl-cache` to the MoonBit `pkf`. `init`/`format`/`migrate`/`hooks`/`clean` mutate the filesystem and are verified by `fs-delta` (a recursive deletion-tracking extension is added for `clean`). `cache`/`pkl-cache` touch state outside the work dir / are environment-specific, so they are verified **structurally** (markers + exit).

**Architecture:** New dispatch arms in `run_main` (before `other =>`), reusing `extract_file_flag`, plan loading, `die`, `println`, `eprintln`, embedded-template + `@process`/`@fs` patterns. The harness `Result`/`Golden`/`Compare` gain deletion tracking so `clean`'s removed outputs appear in fs-delta.

**Tech Stack:** MoonBit (native; `pkf-mbt/scripts/build-native.sh`), Go (harness), Pkl. The conformance differ compares JSON/exit/fs-delta/stderr per scenario contract.

---

## Ground truth (Go oracle)
- `init` (empty dir) → writes a fixed-template `Taskfile.pkl`, stdout `wrote Taskfile.pkl` + next-steps, exit 0. fs-delta created = `["Taskfile.pkl"]`.
- `format` → wraps `pkl format -w <taskfile>`; reformats in place. fs-delta = `["Taskfile.pkl"]` on an unformatted file, `[]` on an already-formatted one. exit 0.
- `migrate --to=<ver> [-f FILE] [--dry-run] [--skip-verify]` → rewrites the `amends "...pkfire@<old>#..."` line to `<ver>`; verifies via pkl eval unless `--skip-verify`. fs-delta = `["Taskfile.pkl"]` (modified). `--dry-run` prints the new line, NO write (fs-delta `[]`).
- `hooks install|uninstall|list [-f FILE] [--force]` → manages `.git/hooks/<event>` shims for tasks named `pre-commit`/`pre-push`/`commit-msg`/…; needs a git repo. install fs-delta created = the `.git/hooks/<event>` files.
- `clean` → removes each task's declared `outputs`. fs-delta DELETED = the removed output files. exit 0.
- `cache <stats|prune|rm|clear>` → CAS management in `$PKFIRE_CACHE_DIR`/default (OUTSIDE the work dir). `stats` prints dir/entries/size/mtime (env-specific → structural). `prune`/`rm`/`clear` delete entries (outside work dir).
- `pkl-cache warm [-f FILE] [PATH...]` → pre-evaluates Pkl into `~/.pkl/cache` (outside work dir). exit 0.

## Current MoonBit reality
- `run_main` dispatch; Phase 2a–2c helpers present. Embedded-string pattern (completion scripts) for `init`'s template. `@process.collect_stdout`/`collect_stderr` to shell out (format → `pkl format`; pkl-cache → `pkl eval`). `@fs` for file create/delete. The amends scan (`info`) already locates the amends line — reuse for `migrate`.
- Harness `Result { Stdout; Stderr; Exit; WorkDir; FSDelta []string }`, `DeltaPaths(before, after)` returns created/modified paths. `Golden` stores `fsdelta`. `Compare` checks `FSDelta` when `Contract.FSDelta`.

---

### Task 1: Harness deletion tracking

**Files:** `conformance/runner.go`, `conformance/golden.go`, `conformance/differ.go`, test.

- [ ] **Step 1:** Add `DeletedPaths(before, after map[string]string) []string` to `runner.go` (paths present in `before` but absent in `after`, sorted). Add `FSDeleted []string` to `Result`; in `Run`, set `FSDeleted: DeletedPaths(before, after)` alongside `FSDelta`.
- [ ] **Step 2:** In `golden.go`, add `FSDeleted []string` to `Golden`; `CaptureGolden` writes `fsdeleted` (when non-nil) via `MarshalDelta`; `LoadGolden` reads it tolerantly.
- [ ] **Step 3:** In `differ.go` `Compare`, inside the `if s.Contract.FSDelta {` block, ALSO compare deleted:
```go
		if d := DiffJSON(MarshalDelta(want.FSDeleted), MarshalDelta(got.FSDeleted), nil); d != "" {
			return "fsDeleted: " + d
		}
```
- [ ] **Step 4:** Test (append to conformance_test.go):
```go
func TestDeletedPaths(t *testing.T) {
	before := map[string]string{"a.txt": "h1", "b.txt": "h2"}
	after := map[string]string{"a.txt": "h1"}
	got := DeletedPaths(before, after)
	if len(got) != 1 || got[0] != "b.txt" {
		t.Errorf("deleted = %v, want [b.txt]", got)
	}
}
```
- [ ] **Step 5:** `cd conformance && go test -run 'TestDeletedPaths|TestFSDelta|TestOracleSelfConsistency' -v` (build oracle) PASS; gofmt/vet clean.
- [ ] **Step 6:** Commit `conformance/` — `conformance: track deleted paths in fs-delta (for clean)`.

---

### Task 2: `init`

**Files:** `pkf-mbt/src/cmd/pkf/main.mbt`, scenarios, goldens.
- [ ] **Step 1:** Capture the Go template: `(cd /tmp/empty && /tmp/pkf-go init && cat Taskfile.pkl)`. Embed it verbatim as a MoonBit raw-string fn `init_template() -> String`.
- [ ] **Step 2:** Dispatch `"init" => { ... }`: if `Taskfile.pkl` exists → Go's behavior (error unless `--force`? check `init -h`); else write the template + print `wrote Taskfile.pkl` + next-steps, exit 0.
- [ ] **Step 3:** Scenario:
```pkl
  new { id = "init-writes"; fixture = "examples/empty-dir"; argv { "init" }; contract = new { exit = true; fsDelta = true; mustContain { "wrote Taskfile.pkl" } } }
```
Capture golden + oracle self-consistency (fs-delta created = `["Taskfile.pkl"]`; the `.gitkeep` is in `before`). Build candidate; verify `init-writes` PASS + diff the candidate's `Taskfile.pkl` vs Go's to confirm byte-identical template. Commit.

---

### Task 3: `format`

**Files:** `pkf-mbt/src/cmd/pkf/main.mbt`, fixture, scenarios, goldens.
- [ ] **Step 1:** Dispatch `"format" => { ... }`: `extract_file_flag`; shell `pkl format -w <taskfile>` (mirror how the codebase runs subprocesses); exit per pkl. (Confirm Go's exact invocation in `cmdFormat`.)
- [ ] **Step 2:** Fixture `examples/unformatted/Taskfile.pkl` — a VALID but unformatted Taskfile (e.g. odd spacing) that `pkl format` will rewrite. Scenario:
```pkl
  new { id = "format-rewrites"; fixture = "examples/unformatted"; argv { "format" }; contract = new { exit = true; fsDelta = true } }
```
Capture golden (fs-delta = `["Taskfile.pkl"]`); both Go and MoonBit shell to the same `pkl format`, so the result is identical. Build + verify PASS. Commit.

---

### Task 4: `migrate`

**Files:** `pkf-mbt/src/cmd/pkf/main.mbt`, fixture, scenarios, goldens.
- [ ] **Step 1:** Dispatch `"migrate" => { ... }`: parse `--to=<ver>`, `-f`, `--dry-run`, `--skip-verify`. Rewrite the `amends` line's `pkfire@<old>` to `<ver>` (reuse the amends-locate logic). `--dry-run` → print new line, no write. Else write + (unless `--skip-verify`) verify via pkl eval. Match Go's stdout/exit.
- [ ] **Step 2:** Fixture `examples/migrate-src/Taskfile.pkl` (amends `pkfire@0.10.0`). Scenarios:
```pkl
  new { id = "migrate-rewrites"; fixture = "examples/migrate-src"; argv { "migrate"; "--to=0.11.0"; "--skip-verify" }; contract = new { exit = true; fsDelta = true } }
  new { id = "migrate-dry-run"; fixture = "examples/migrate-src"; argv { "migrate"; "--to=0.11.0"; "--dry-run" }; contract = new { exit = true; mustContain { "0.11.0" } } }
```
(`--skip-verify` avoids needing the 0.11.0 package available; `migrate-dry-run` makes no fs change.) Capture goldens; build + verify both PASS + diff the rewritten file vs Go. Commit.

---

### Task 5: `hooks`

**Files:** `pkf-mbt/src/cmd/pkf/main.mbt`, fixture, scenarios, goldens.
- [ ] **Step 1:** Dispatch `"hooks" => { ... }`: subcommands `install`/`uninstall`/`list`. `install` writes `.git/hooks/<event>` shims for tasks named like git events (`pre-commit`, `pre-push`, `commit-msg`, …); `--force` overwrites. Match Go's shim content + stdout. (Read Go's `cmdHooks`.)
- [ ] **Step 2:** Fixture `examples/hooks-tf/Taskfile.pkl` with tasks named `pre-commit` + `pre-push`. Scenario (setup runs `git init` so `.git` is in `before`, and only the shims are in the delta):
```pkl
  new {
    id = "hooks-install"
    fixture = "examples/hooks-tf"
    argv { "hooks"; "install" }
    setup { "git init -q" }
    contract = new { exit = true; fsDelta = true; mustContain { "pre-commit" } }
  }
```
Capture golden (fs-delta created = the `.git/hooks/pre-commit`, `.git/hooks/pre-push` shims); confirm oracle self-consistency. Build + verify PASS + diff a shim vs Go. Commit. (Note: CI has `git`; the runner's env must allow `git init` — it does.)

---

### Task 6: `clean`

**Files:** `pkf-mbt/src/cmd/pkf/main.mbt`, scenarios, goldens.
- [ ] **Step 1:** Dispatch `"clean" => { ... }`: for each task's declared `outputs` (glob-expand), remove the matching files. Match Go's stdout/exit (read `cmdClean`).
- [ ] **Step 2:** Scenario (uses the `examples/cat-io` fixture's `copy` task with output `out.txt`; setup pre-creates `out.txt`, then clean removes it → fs-delta DELETED = `["out.txt"]`):
```pkl
  new {
    id = "clean-removes-outputs"
    fixture = "examples/cat-io"
    argv { "clean" }
    setup { "printf hi > src.txt"; "printf out > out.txt" }
    contract = new { exit = true; fsDelta = true }
  }
```
Capture golden (`fsdeleted` = `["out.txt"]`, `fsdelta` created/modified = `[]`); confirm oracle self-consistency. Build + verify `clean-removes-outputs` PASS (the deletion-tracking from Task 1 catches it). Commit.

---

### Task 7: `cache` (structural)

**Files:** `pkf-mbt/src/cmd/pkf/main.mbt`, scenarios, goldens.
- [ ] **Step 1:** Dispatch `"cache" => { ... }`: subcommands `stats`/`prune`/`rm`/`clear`. `stats` prints cache dir + entry count + size (env-specific). `prune`/`rm`/`clear` delete entries from the cache dir (outside work dir). Match Go's structure/stdout shape; messages are env-specific.
- [ ] **Step 2:** Scenario (structural — cache dir is outside the work dir + env-specific, so assert markers + exit):
```pkl
  new {
    id = "cache-stats-structural"
    fixture = "examples/basic"
    argv { "cache"; "stats" }
    contract = new { exit = true; stdoutNonEmpty = true; mustContain { "cache" } }
  }
```
(Use a marker that appears in both Go and MoonBit `cache stats` output — verify and adjust.) Build + verify PASS. Commit. (Note in the commit that cache is structurally verified.)

---

### Task 8: `pkl-cache` (structural)

**Files:** `pkf-mbt/src/cmd/pkf/main.mbt`, scenarios, goldens.
- [ ] **Step 1:** Dispatch `"pkl-cache" => { ... }`: `warm [-f FILE] [PATH...]` pre-evaluates the Taskfile (shell `pkl eval` / reuse the loader) to populate the Pkl package cache. exit 0 on success. Match Go's stdout shape.
- [ ] **Step 2:** Scenario (structural — populates `~/.pkl/cache` outside the work dir):
```pkl
  new {
    id = "pkl-cache-warm-structural"
    fixture = "examples/basic"
    argv { "pkl-cache"; "warm" }
    contract = new { exit = true }
  }
```
(If Go's `pkl-cache warm` prints a marker, add `mustContain`.) Build + verify PASS. Commit.

---

## Self-review
**Spec coverage:** init/format/migrate/hooks/clean (fs-delta, clean via Task 1's deletion tracking) + cache/pkl-cache (structural). Matches the agreed Phase 2d scope (all 7; clean gets deletion tracking; cache/pkl-cache structural because their side-effects are outside the work dir + env-specific).

**Placeholder scan:** Go-exact templates/shim-content/stdout are captured+matched from oracle goldens; subprocess/fs MoonBit APIs are flagged "mirror existing usage". Each command is gated by a scenario.

**Risk:** init/format/migrate/hooks content parity is achieved by embedding Go's template / shelling to the same `pkl format` / mirroring Go's rewrite+shim — fs-delta confirms the right PATHS change but not byte-content (the differ doesn't hash-compare created-file content), so each task DIFFS the produced file vs Go manually as a guard. cache/pkl-cache are structural (markers + exit), an agreed limitation.

## Carry to Phase 3
Self-contained Pkl evaluation: bring the HTTP `package://` downloader + glob import in-process; drop the `mpkl` subprocess fallback so the shipped artifact is a single self-contained binary.
