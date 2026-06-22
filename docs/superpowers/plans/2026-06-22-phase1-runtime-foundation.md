# Phase 1: MoonBit pkf runtime-foundation parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Close the MoonBit `pkf` runtime-foundation gaps so its process contract matches the Go `pkf`: errors and unknown input go to **stderr with exit 1**, `version`/`--version`/`-v` and `help`/`--help`/`-h`/no-args behave like Go (exit 0, stdout), and `Taskfile.pkl` is discovered by walking up parent directories (plus `-f`/`--file`).

**Architecture:** Each behavior is driven by a conformance scenario whose golden is captured from the Go oracle (the harness from Phase 0). MoonBit changes live in `pkf-mbt/src/cmd/pkf/` and are verified by building the candidate (`pkf-mbt/scripts/build-native.sh`) and running the harness against it. The harness is first extended (Go side) to assert stderr/stream contracts, since Phase 0 only compared stdout + exit + fs-delta.

**Tech Stack:** MoonBit (native target; FFI C stub for stderr, mirroring `stat_native.c`/`signal_native.c`), Go (harness extension), Pkl (scenarios). The `--json` encoder is explicitly **out of scope** (moved to Phase 2 with the introspection commands).

---

## Ground truth (measured from the Go oracle `/tmp/pkf-go`)

| invocation | exit | stream | content |
|---|---|---|---|
| `version` / `--version` / `-v` | 0 | stdout | version string (`dev` locally; injected at release) |
| `help` / `--help` / no-args | 0 | stdout | usage: `pkf — pkfire task runner` + command list |
| unknown subcommand (`bogus`) | 1 | **stderr** | usage block |
| `list` with no Taskfile reachable | 1 | **stderr** | `pkf: evaluate …` error |
| `list` from a subdir of a project | 0 | stdout | tasks (Taskfile found by walking up) |

## Current MoonBit reality (from `pkf-mbt/src/cmd/pkf/main.mbt`)

- `die` (lines 68-71): `println("pkf: \{message}")` then `@sys.exit(2)`. **All output to stdout; error exit is 2.**
- No `version`/`--version`/`-v`, no `help`/`--help`/`-h`. No-args prints usage but `return 2` (lines 2396-2408).
- Unknown subcommand → `die(...)` → stdout + exit 2 (line 2472).
- `locate_taskfile` (lines 1522-1530): checks **only** `./Taskfile.pkl`, else `die`. No `-f`/`--file`, no upward walk.
- FFI pattern (line 507-508): `#borrow(path)` + `extern "C" fn stat_mode_ffi(path : Bytes) -> Int = "mizchi_pkf_stat_mode"`, C stub in `stat_native.c` (`#include <moonbit.h>`). Native stubs registered in `moon.pkg` `"native-stub"`.
- `@sys` = `moonbitlang/x/sys` (has `exit`, `get_cli_args`); `@utf8` imported (String↔UTF-8 bytes).

> Build the candidate with `./pkf-mbt/scripts/build-native.sh`; binary at `pkf-mbt/_build/native/release/build/src/cmd/pkf/pkf.exe`. Run the harness from `conformance/` with `PKF_GO_BIN`/`PKF_MBT_BIN` set.

## File structure

```
conformance/
  Conformance.pkl        # +stderr/stream contract fields
  scenarios.pkl          # +6 Phase-1 scenarios
  differ.go              # Compare: +stderr / stdoutEmpty checks
  golden.go              # capture/load stderr too
  runner.go              # (Result already carries Stderr)
  golden/<id>/           # +stderr file per scenario
pkf-mbt/src/cmd/pkf/
  eprint_native.c        # NEW: write a byte string to stderr
  main.mbt               # die, version/help dispatch, locate_taskfile
  moon.pkg               # register eprint_native.c in native-stub
```

---

### Task 1: Harness — stderr + stream contract

**Files:**
- Modify: `conformance/Conformance.pkl`, `conformance/golden.go`, `conformance/differ.go`
- Test: `conformance/conformance_test.go` (append)

- [ ] **Step 1: Extend the Pkl contract schema.** In `conformance/Conformance.pkl`, add to `class Contract`:

```pkl
  /// Normalized substrings that must all appear in stderr.
  mustContainStderr: Listing<String> = new {}
  /// Assert stdout is empty (after trimming).
  stdoutEmpty: Boolean = false
```

- [ ] **Step 2: Capture stderr in goldens.** In `conformance/golden.go`: add `Stderr []byte` to `Golden`; in `CaptureGolden`, after the exit file, write `res.Stderr` to a `stderr` file; in `LoadGolden`, read it tolerantly:

```go
	// in CaptureGolden, after writing exit (before the fsdelta block):
	if err := os.WriteFile(filepath.Join(dir, "stderr"), res.Stderr, 0o644); err != nil {
		return err
	}
	// in LoadGolden, after reading exit:
	if raw, err := os.ReadFile(filepath.Join(dir, "stderr")); err == nil {
		g.Stderr = raw
	}
```

- [ ] **Step 3: Extend `Compare`.** In `conformance/differ.go`, before `return ""`:

```go
	for _, sub := range s.Contract.MustContainStderr {
		if !containsNormalized(got.Stderr, sub) {
			return fmt.Sprintf("mustContainStderr: %q not found in normalized stderr", sub)
		}
	}
	if s.Contract.StdoutEmpty && len(normalizeText(string(got.Stdout))) != 0 {
		return fmt.Sprintf("stdoutEmpty: expected empty stdout, got %q", got.Stdout)
	}
```

Add the struct fields to `Contract` in `scenario.go`: `MustContainStderr []string` (json:"mustContainStderr") and `StdoutEmpty bool` (json:"stdoutEmpty").

- [ ] **Step 4: Write the failing test.** Append to `conformance_test.go`:

```go
func TestCompareStderrContract(t *testing.T) {
	s := Scenario{Contract: Contract{Exit: true, MustContainStderr: []string{"usage"}, StdoutEmpty: true}}
	want := Golden{Exit: 1, Stderr: []byte("pkf: usage: ...\n")}
	got := Result{Exit: 1, Stderr: []byte("pkf:   usage:  ...\n"), Stdout: nil}
	if d := Compare(s, want, got); d != "" {
		t.Errorf("expected match, got: %s", d)
	}
	got.Stdout = []byte("leaked")
	if Compare(s, want, got) == "" {
		t.Error("expected stdoutEmpty violation")
	}
}
```

- [ ] **Step 5: Run.** `cd conformance && go test -run 'TestCompareStderrContract|TestOracleSelfConsistency' -v` (build oracle first). Expected: PASS; `TestUpdateGolden -update` regenerates goldens incl. the new `stderr` file for the existing scenario.

- [ ] **Step 6: Regenerate goldens + commit.**
```bash
go build -o /tmp/pkf-go ./cmd/pkf
cd conformance && PKF_GO_BIN=/tmp/pkf-go go test -run TestUpdateGolden -update
git add conformance/ && git commit -m "conformance: stderr + stdoutEmpty stream contract"
```

---

### Task 2: MoonBit — stderr FFI primitive

**Files:**
- Create: `pkf-mbt/src/cmd/pkf/eprint_native.c`
- Modify: `pkf-mbt/src/cmd/pkf/moon.pkg` (register the stub), `pkf-mbt/src/cmd/pkf/main.mbt` (extern + helper)

- [ ] **Step 1: C stub.** Create `pkf-mbt/src/cmd/pkf/eprint_native.c` mirroring `stat_native.c`'s moonbit-bytes access:

```c
#include <moonbit.h>
#include <stdio.h>

// Write a UTF-8 byte string to stderr (no trailing newline added).
void mizchi_pkf_eprint(moonbit_bytes_t s) {
  int32_t len = Moonbit_array_length(s);
  fwrite((const char *)s, 1, (size_t)len, stderr);
}
```

(Confirm the length macro/name against `stat_native.c` — use whatever that file uses to read a `moonbit_bytes_t` length; adjust if the accessor differs.)

- [ ] **Step 2: Register the stub.** In `pkf-mbt/src/cmd/pkf/moon.pkg`, add `eprint_native.c` to the `"native-stub"` list:

```
"native-stub": [ "stat_native.c", "signal_native.c", "eprint_native.c" ],
```

- [ ] **Step 3: Extern + helper in `main.mbt`.** Near the other externs (line ~507), add:

```moonbit
#borrow(s)
extern "C" fn eprint_ffi(s : Bytes) -> Unit = "mizchi_pkf_eprint"

/// Write a line to stderr (mirrors `println` but to fd 2).
fn eprintln(message : String) -> Unit {
  eprint_ffi(@utf8.encode(message + "\n"))
}
```

(Use the same String→Bytes conversion the codebase already uses for `stat_mode_ffi`; if it is not `@utf8.encode`, mirror that call.)

- [ ] **Step 4: Build + smoke.** `./pkf-mbt/scripts/build-native.sh`. Then a temporary smoke: call `eprintln("hello-stderr")` from an early point, build, run `pkf-mbt/.../pkf.exe version 2>/tmp/e; cat /tmp/e` to confirm it lands on stderr. Remove the temporary call.

- [ ] **Step 5: Commit.**
```bash
git add pkf-mbt/src/cmd/pkf/eprint_native.c pkf-mbt/src/cmd/pkf/moon.pkg pkf-mbt/src/cmd/pkf/main.mbt
git commit -m "pkf-mbt: stderr FFI primitive (eprintln)"
```

---

### Task 3: MoonBit — `die` to stderr + exit 1

**Files:** Modify `pkf-mbt/src/cmd/pkf/main.mbt`; add scenario.

- [ ] **Step 1: Add the failing scenario.** In `conformance/scenarios.pkl`, append:

```pkl
  new {
    id = "no-taskfile-error"
    fixture = "examples/empty-dir"
    argv { "list" }
    contract = new {
      exit = true
      stdoutEmpty = true
      mustContainStderr { "pkf:" }
    }
  }
```

Create the fixture dir `examples/empty-dir/` with a single `.gitkeep` file (a directory with no `Taskfile.pkl`). Capture its golden from the oracle: `cd conformance && PKF_GO_BIN=/tmp/pkf-go go test -run TestUpdateGolden -update` (Go exits 1, error on stderr, stdout empty). Confirm `TestOracleSelfConsistency` passes for it.

- [ ] **Step 2: Change `die`.** In `main.mbt` lines 68-71:

```moonbit
fn die(message : String) -> Unit {
  eprintln("pkf: \{message}")
  @sys.exit(1)
}
```

- [ ] **Step 3: Build + verify candidate.** `./pkf-mbt/scripts/build-native.sh`, then run the harness candidate path; the `no-taskfile-error` row must go from RED to PASS (exit 1, stderr has `pkf:`, stdout empty). Note: other scenarios that previously relied on error-on-stdout must be re-checked — there are none yet.

- [ ] **Step 4: Commit.**
```bash
git add pkf-mbt/src/cmd/pkf/main.mbt conformance/scenarios.pkl conformance/golden/ examples/empty-dir/
git commit -m "pkf-mbt: die() writes to stderr and exits 1 (Go parity)"
```

---

### Task 4: MoonBit — `version` / `--version` / `-v`

**Files:** Modify `main.mbt`; add scenario.

- [ ] **Step 1: Add the failing scenario.** In `conformance/scenarios.pkl`:

```pkl
  new {
    id = "version"
    fixture = "examples/basic"
    argv { "version" }
    contract = new {
      exit = true
      mustContain { "" }  // replaced below
    }
  }
```

The version string differs between binaries (Go prints the injected version; MoonBit prints its own), so do **not** byte-match. Assert exit 0 and non-empty stdout instead. Implement this by leaving `mustContain` empty and adding a dedicated test rather than a golden text match — simplest: set `contract { exit = true }` and rely on the candidate producing exit 0 with the same exit as the golden (0). To also assert non-empty stdout, add a `stdoutNonEmpty` contract field (mirror `stdoutEmpty`): in `Conformance.pkl` add `stdoutNonEmpty: Boolean = false`; in `differ.go` `Compare`, add:

```go
	if s.Contract.StdoutNonEmpty && len(normalizeText(string(got.Stdout))) == 0 {
		return "stdoutNonEmpty: expected non-empty stdout"
	}
```

and `StdoutNonEmpty bool` to the Go `Contract`. Then the scenario is:

```pkl
  new {
    id = "version"
    fixture = "examples/basic"
    argv { "version" }
    contract = new { exit = true; stdoutNonEmpty = true }
  }
```

Capture golden (oracle exits 0, prints version). Confirm oracle self-consistency.

- [ ] **Step 2: Implement.** In `run_main`'s subcommand match (main.mbt ~2410), add arms BEFORE the `other =>` catch-all. Since `version`/`--version`/`-v` are the first token, handle them in the match on `args[0]`:

```moonbit
    "version" | "--version" | "-v" => {
      println(pkf_version())
      0
    }
```

Add a `pkf_version()` returning a version constant (e.g. `"0.0.1"` to match `moon.mod.json`, or a build-stamped value):

```moonbit
fn pkf_version() -> String {
  "0.0.1"
}
```

- [ ] **Step 3: Build + verify.** Rebuild candidate; `version` row PASS (exit 0, non-empty stdout).

- [ ] **Step 4: Commit.**
```bash
git add conformance/ pkf-mbt/src/cmd/pkf/main.mbt conformance/golden/
git commit -m "pkf-mbt: version / --version / -v (Go parity: stdout, exit 0)"
```

---

### Task 5: MoonBit — `help` / no-args (exit 0, stdout) + unknown subcommand (stderr, exit 1)

**Files:** Modify `main.mbt`; add scenarios.

- [ ] **Step 1: Add scenarios.** In `conformance/scenarios.pkl`:

```pkl
  new {
    id = "help"
    fixture = "examples/basic"
    argv { "help" }
    contract = new { exit = true; stdoutNonEmpty = true; mustContain { "run" } }
  }
  new {
    id = "no-args"
    fixture = "examples/basic"
    argv {}
    contract = new { exit = true; stdoutNonEmpty = true }
  }
  new {
    id = "unknown-subcommand"
    fixture = "examples/basic"
    argv { "bogus" }
    contract = new { exit = true; stdoutEmpty = true; mustContainStderr { "run" } }
  }
```

Capture goldens (Go: help/no-args → exit 0 stdout usage; bogus → exit 1 stderr usage). Note Go's usage text contains the word `run` (a listed command) — used as the semantic anchor. Confirm oracle self-consistency.

- [ ] **Step 2: Implement.** In `run_main` (main.mbt ~2396):
  - Change the no-args branch to print the usage block and `return 0` (was `return 2`).
  - Factor the usage block into `fn usage_text() -> String { ... }` (reuse the existing literal) so help and no-args share it.
  - Add match arms: `"help" | "--help" | "-h" => { println(usage_text()); 0 }`.
  - Change the `other =>` catch-all to print usage to **stderr** and exit 1:

```moonbit
    other => {
      eprintln("pkf: unknown subcommand `\{other}`")
      eprintln(usage_text())
      1
    }
```

(Drop the old `die(... "only run is supported")`. Returning 1 from `run_main` propagates to `@sys.exit` in `main`.)

- [ ] **Step 3: Build + verify.** Candidate rows `help`, `no-args`, `unknown-subcommand` PASS.

- [ ] **Step 4: Commit.**
```bash
git add conformance/ pkf-mbt/src/cmd/pkf/main.mbt conformance/golden/
git commit -m "pkf-mbt: help/no-args exit 0 stdout; unknown subcommand stderr exit 1"
```

---

### Task 6: MoonBit — Taskfile upward discovery + `-f`/`--file`

**Files:** Modify `main.mbt`; add scenario.

- [ ] **Step 1: Add scenario.** In `conformance/scenarios.pkl`:

```pkl
  new {
    id = "list-from-subdir"
    fixture = "examples/basic"
    argv { "list" }
    env { ["PKF_CONFORMANCE_SUBDIR"] = "sub" }   // see runner note
    setup { "mkdir -p sub" }
    contract = new { exit = true; mustContain { "hello" } }
  }
```

Runner note: the harness runs pkf in the fixture's copied root. To exercise *subdir discovery* the run must `cd` into `sub/` first. Add support in `conformance/runner.go`: if scenario env has `PKF_CONFORMANCE_SUBDIR`, set the command's `Dir` to `work/<subdir>` instead of `work`. (Add `cmd.Dir = filepath.Join(work, sub)` when the var is present; document it.) Capture golden from the oracle (Go lists tasks from the subdir). Confirm oracle self-consistency.

- [ ] **Step 2: Implement discovery.** Replace `locate_taskfile` (main.mbt 1522-1530) so it: (a) honors a `-f`/`--file` override parsed as a global flag; (b) otherwise walks up from cwd to the filesystem root, returning the first dir containing `Taskfile.pkl`; (c) `die`s if none found. Also set the working/repo root to the directory containing the found Taskfile (the run/cache code uses `repo_root`; point it at the Taskfile's dir, not cwd):

```moonbit
fn locate_taskfile(explicit : String?) -> String {
  match explicit {
    Some(p) => if @fs.path_exists(p) { p } else { die("Taskfile not found: \{p}"); panic() }
    None => {
      let mut dir = @fs.getcwd()  // confirm the cwd API in mizchi/x/fs or @sys
      while true {
        let candidate = dir + "/Taskfile.pkl"
        if @fs.path_exists(candidate) { return candidate }
        let parent = parent_dir(dir)
        if parent == dir { break }   // reached root
        dir = parent
      }
      die("Taskfile.pkl not found in current or any parent directory")
      panic()
    }
  }
}
```

Parse `-f`/`--file` as a global pre-pass over argv in `run_main` before the subcommand match, threading the value into the load path. Confirm the exact cwd / path APIs (`@fs`, `@xfs`, or `@sys`) against the existing code that already does fs ops; implement `parent_dir` with string ops on `/`.

- [ ] **Step 3: Build + verify.** Candidate `list-from-subdir` PASS. Re-run the WHOLE candidate ledger to confirm no regression on earlier Phase-1 rows.

- [ ] **Step 4: Commit.**
```bash
git add conformance/ pkf-mbt/src/cmd/pkf/main.mbt conformance/golden/
git commit -m "pkf-mbt: Taskfile upward discovery + -f/--file (Go parity)"
```

---

### Task 7: Ledger checkpoint

**Files:** none (verification).

- [ ] **Step 1: Full candidate ledger.** Build oracle + candidate, run `TestCandidateParity`, and record `conformance/LEDGER.md`. Expected: all six Phase-1 scenarios (`no-taskfile-error`, `version`, `help`, `no-args`, `unknown-subcommand`, `list-from-subdir`) PASS; `list-json-basic` remains RED (its `--json` is Phase 2). Confirm `TestOracleSelfConsistency` (CI hard gate) is green and `go vet` / `gofmt -l` clean on `conformance/`.

- [ ] **Step 2: Note the residual.** The ledger should clearly show `list-json-basic` RED as the one remaining Phase-0 scenario, now joined by the green foundation rows — the parity scoreboard moving in the right direction. No commit needed (LEDGER.md is gitignored).

---

## Self-review

**Spec coverage (vs design doc Phase 1):** error→stderr + exit-code reconciliation → Tasks 2,3,5; `version`/`help` → Tasks 4,5; Taskfile upward discovery + `-f`/`--file` → Task 6. The `--json` encoder infrastructure is **deliberately deferred to Phase 2** (documented in the spec note below) — it belongs with the introspection `--json` commands and would otherwise bloat this phase. The harness gains the stderr/stream contract it was missing (Task 1).

**Placeholder scan:** MoonBit stdlib specifics that require compiler confirmation (the `moonbit_bytes_t` length accessor, the String→Bytes call, the cwd API) are flagged inline with the existing-pattern to mirror, not left blank. Each MoonBit task is gated by a concrete conformance scenario = an executable acceptance test.

**Type consistency:** Go `Contract` gains `MustContainStderr []string`, `StdoutEmpty bool`, `StdoutNonEmpty bool`; `Golden` gains `Stderr []byte` — used consistently across differ/golden/scenario. MoonBit adds `eprintln`, `pkf_version`, `usage_text`, `parent_dir`, and reworks `die`/`locate_taskfile`/`run_main` dispatch.

**Scope:** One subsystem (MoonBit runtime foundation + the harness extension that verifies it). No `--json` output, no missing introspection/diagnostic/mutation subcommands (Phase 2).

## Design note (carried to Phase 2)

Phase 2 will: build the shared `--json` encoder (construct `moonbitlang/core/json` `Json` values from `Task`/`Plan`/`Param`/`WorkflowTest` to match Go's exact field names + omitempty), then bring `list`/`graph`/`describe`/`info`/`affected` `--json` and the diagnostic/mutation subcommands to parity — turning `list-json-basic` and its successors green.
