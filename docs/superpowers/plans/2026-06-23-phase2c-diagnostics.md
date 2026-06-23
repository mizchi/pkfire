# Phase 2c: MoonBit pkf diagnostics (lint / completion / doctor / explain) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Checkbox (`- [ ]`) steps.

**Goal:** Add the `lint`, `completion`, `doctor`, and `explain` subcommands to the MoonBit `pkf`. `lint --json` and `completion` are verified by deep-equal / structural conformance against the Go oracle; `doctor` and `explain` produce environment/implementation-specific values (paths, cache stats, BLAKE3-vs-SHA256 hashes) so they are verified **structurally** (exit + key/label markers via `mustContain`), not by value deep-equal.

**Architecture:** Each is a new subcommand dispatched in `run_main` (before `other =>`), using `extract_file_flag` + `--json` where applicable. `lint` reuses the harness JSON deep-equal (with a recursive `jsonIgnorePaths` to drop the volatile abs `path` in findings); `completion` embeds the Go shell scripts verbatim; `doctor`/`explain` are gated by `mustContain` of stable structural markers.

**Tech Stack:** MoonBit (native; `pkf-mbt/scripts/build-native.sh`), Go (harness), Pkl (scenarios). Reuse Phase 2a/2b: `Json::string/array/object/boolean`, `Json::stringify`, `extract_file_flag`, `sorted_visible_tasks`, plan loading, `die`/`eprintln`.

---

## Ground truth (Go oracle)

### `lint --json` → `{"findings":[ F... ]}` (and `"fixes"` with `--fix`)
- Clean project → `{"findings":[]}` (deep-equal-able directly).
- Finding `F` (Go `lintFinding`): `{path (ABS — volatile), line, level, kind, task?, message, suggestion?, fixable?}`.
- A `local x = new Task { name="y" }` NOT listed in `tasks { … }` → a `dead-local-task` finding: `{path, line, level:"error", kind:"dead-local-task", task:"y", message:"local task \"y\" declares name \"y\" but is not included in tasks", suggestion:"remove local task \"y\" or include it in tasks { ... }"}`. When errors exist → exit 1, stderr `pkf: lint found N error(s)`.

### `completion bash|zsh|fish` → a static shell script on stdout, exit 0. (122 lines for bash.) No env-dependence. Distinct markers: bash starts `# pkf bash completion.`; each contains a `_pkf`-ish completion function and shell-specific directives.

### `doctor --json` → `{"version", "checks":[ {"level","label","message"} ]}`, exit 0.
- Labels (stable set): `pkf-path`, `pkl`, `cache`, `remote`, `taskfile`. `level` ∈ `OK`/`WARN`/`ERROR`. `message` is environment-specific (paths, cache size, version) — NOT value-contractual.

### `explain <task>` → PLAIN text (no `--json`), exit 0. Markers: `task:`, `action key: <hash>`, `cache:`, `workdir:`, `deps:`, `dependents:`, `cmd:`, `shell:`, `shell flags:`, `env (N):`, `tools (N):`, `input patterns (N):`. The `action key` hash differs Go(BLAKE3) vs MoonBit(SHA-256), and `workdir` is an abs path — both volatile.

## Current MoonBit reality
- `run_main` dispatch; Phase 2a/2b helpers present. `Plan { default_env; tasks; task_order; workflow_tests; default_shell; default_shell_flags }`. The loader reads the Taskfile source (`@fs.read_file_to_string`) — `info`'s amends scan does this; mirror it for `lint`'s source scan.
- MoonBit already computes action keys for caching (find `compute_action_key` / the canonical-form builder) — `explain` dumps that.
- Harness `jsonIgnorePaths` drops TOP-LEVEL keys only (Phase 2b) — Task 1 makes it recursive.

---

### Task 1: Recursive `jsonIgnorePaths`

**Files:** `conformance/differ.go`, test.

- [ ] **Step 1:** Change `stripJSONKeys` (Phase 2b) to delete the named keys at ANY depth (recurse into objects + array elements):
```go
func stripJSONKeys(raw []byte, keys []string) []byte {
	if len(keys) == 0 {
		return raw
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return raw
	}
	set := map[string]bool{}
	for _, k := range keys {
		set[k] = true
	}
	var walk func(any) any
	walk = func(n any) any {
		switch t := n.(type) {
		case map[string]any:
			for k := range t {
				if set[k] {
					delete(t, k)
				} else {
					t[k] = walk(t[k])
				}
			}
			return t
		case []any:
			for i := range t {
				t[i] = walk(t[i])
			}
			return t
		}
		return n
	}
	walk(v)
	out, err := json.Marshal(v)
	if err != nil {
		return raw
	}
	return out
}
```
- [ ] **Step 2:** Test (append to conformance_test.go):
```go
func TestStripJSONKeysRecursive(t *testing.T) {
	s := Scenario{Contract: Contract{JSON: true, JsonIgnorePaths: []string{"path"}}}
	want := Golden{Stdout: []byte(`{"findings":[{"path":"/tmp/a","line":3,"kind":"x"}]}`)}
	got := Result{Stdout: []byte(`{"findings":[{"path":"/tmp/DIFF","line":3,"kind":"x"}]}`)}
	if d := Compare(s, want, got); d != "" {
		t.Errorf("nested path should be ignored: %s", d)
	}
	got.Stdout = []byte(`{"findings":[{"path":"/x","line":9,"kind":"x"}]}`)
	if Compare(s, want, got) == "" {
		t.Error("nested non-ignored mismatch (line) should diff")
	}
}
```
- [ ] **Step 3:** `cd conformance && go test -run 'TestStripJSONKeysRecursive|TestCompareJSONIgnorePaths|TestOracleSelfConsistency' -v` (build oracle first) PASS; `gofmt -w`; vet clean.
- [ ] **Step 4:** Commit `conformance/` — `conformance: recursive jsonIgnorePaths (drop keys at any depth)`.

---

### Task 2: `completion bash|zsh|fish`

**Files:** `pkf-mbt/src/cmd/pkf/main.mbt`, `conformance/scenarios.pkl`, goldens.

- [ ] **Step 1:** Capture the three Go scripts: `(/tmp/pkf-go completion bash)`, `zsh`, `fish`. Embed each verbatim as a MoonBit multi-line string constant (`fn completion_bash() -> String { #|... }` etc. — use the `#|` raw-line form; escape nothing). 
- [ ] **Step 2:** Dispatch: `"completion" => { ... }` — the next arg is the shell (`bash`/`zsh`/`fish`); print the matching script, exit 0; unknown/missing shell → `die("usage: pkf completion <bash|zsh|fish>")` (exit 1).
- [ ] **Step 3:** Scenarios (structural — the differ has no exact-text mode; assert distinctive markers + exit 0):
```pkl
  new { id = "completion-bash"; fixture = "examples/basic"; argv { "completion"; "bash" }; contract = new { exit = true; stdoutNonEmpty = true; mustContain { "pkf bash completion" } } }
  new { id = "completion-zsh"; fixture = "examples/basic"; argv { "completion"; "zsh" }; contract = new { exit = true; stdoutNonEmpty = true; mustContain { "#compdef" } } }
  new { id = "completion-fish"; fixture = "examples/basic"; argv { "completion"; "fish" }; contract = new { exit = true; stdoutNonEmpty = true; mustContain { "complete -c pkf" } } }
```
(Verify the exact marker strings against the captured scripts; adjust mustContain to a line that actually appears in each.)
- [ ] **Step 4:** Capture goldens + oracle self-consistency; build candidate; the three rows PASS + all prior PASS. Commit.

---

### Task 3: `lint` (deep-equal via recursive ignore)

**Files:** `pkf-mbt/src/cmd/pkf/main.mbt`, fixture, scenarios, goldens.

- [ ] **Step 1: dead-local detection.** Read the Taskfile source; scan for `local <id> = new Task { … name = "<name>" … }` declarations (capture the source line number) and their `name`. A declaration whose `name` is NOT a key in the rendered `plan.tasks` is a `dead-local-task`. (Use string scanning over lines; find `local ` … `new Task`; within the block find `name = "<x>"`. Keep it simple and robust enough for the fixtures.)
- [ ] **Step 2: finding JSON.** `{path: <abs taskfile path>, line, level:"error", kind:"dead-local-task", task:<name>, message:"local task \"<name>\" declares name \"<name>\" but is not included in tasks", suggestion:"remove local task \"<name>\" or include it in tasks { ... }"}`. `lint --json` → `{"findings":[...]}` (empty `[]` when none). When any finding has `level=="error"` → after printing JSON, exit 1 and `eprintln("pkf: lint found N error")` (match Go's stderr/exit; verify the exact text from the oracle).
- [ ] **Step 3: fixture + scenarios.** Create `examples/lint-dead/Taskfile.pkl` (amends like basic) with a listed task + an unlisted `local orphan = new Task { name="orphan"; cmd="echo y" }`. Scenarios:
```pkl
  new { id = "lint-clean"; fixture = "examples/basic"; argv { "lint"; "--json" }; contract = new { json = true } }
  new { id = "lint-dead"; fixture = "examples/lint-dead"; argv { "lint"; "--json" }; contract = new { json = true; exit = true; jsonIgnorePaths { "path" } } }
```
Capture goldens (READ `lint-dead/stdout` for the exact message/suggestion/line + `exit`=1) + oracle self-consistency. Implement to match. (`lint-clean` is `{"findings":[]}` exit 0; `lint-dead` is one finding exit 1 with the abs `path` ignored.)
- [ ] **Step 4:** Build + verify both rows PASS + all prior PASS; commit.

---

### Task 4: `doctor --json` (structural)

**Files:** `pkf-mbt/src/cmd/pkf/main.mbt`, scenarios, goldens.

- [ ] **Step 1: checks.** Implement the check set producing `{version, checks:[{level,label,message}]}`:
  - `pkl`: locate `pkl` on PATH + its `--version`; OK if found.
  - `cache`: the cache dir (PKFIRE_CACHE_DIR or default) + size/entries; OK.
  - `remote`: `PKFIRE_REMOTE_CACHE` set or not; OK.
  - `taskfile`: the located Taskfile + task count + amends; OK (or ERROR if missing).
  - `pkf-path`: best-effort (the running binary vs PATH `pkf`); pick a sensible level. (Messages are NOT value-contractual — only labels/structure are checked.)
  Emit `version` (the `pkf_version()` constant). `--json` renders the object; plain renders a readable table.
- [ ] **Step 2: scenario (structural).**
```pkl
  new {
    id = "doctor-structural"
    fixture = "examples/basic"
    argv { "doctor"; "--json" }
    contract = new {
      exit = true
      mustContain { "checks"; "level"; "label"; "pkl"; "cache"; "remote"; "taskfile" }
    }
  }
```
(`json=false` — do NOT deep-equal; assert the labels + structure markers appear in stdout and exit 0. Capture the golden for `exit`.)
- [ ] **Step 3:** Build + verify the row PASS (the candidate's `doctor --json` contains those labels) + all prior PASS; commit. (Note in the commit that doctor is structurally verified, not value-equal, by design.)

---

### Task 5: `explain <task>` (structural)

**Files:** `pkf-mbt/src/cmd/pkf/main.mbt`, scenarios, goldens.

- [ ] **Step 1: dump.** `explain <task>` prints the task's action-key surface in plain text: `task:`, `action key:` (the computed key — reuse the existing action-key function), `cache:`, `workdir:`, `deps:`, `dependents:`, `cmd:`, `shell:`, `shell flags:`, `env (N):`, `tools (N):`, `input patterns (N):`. Unknown task → `die("unknown task: ...")` exit 1. (`-f`/`--file` via `extract_file_flag`; one positional task name.)
- [ ] **Step 2: scenario (structural).**
```pkl
  new {
    id = "explain-structural"
    fixture = "examples/basic"
    argv { "explain"; "build" }
    contract = new {
      exit = true
      mustContain { "task:"; "action key:"; "cmd:"; "shell:"; "input patterns" }
    }
  }
```
(The hash + abs workdir are volatile, so assert the structural markers, not values.)
- [ ] **Step 3:** Build + verify the row PASS + all prior PASS; commit.

---

## Self-review

**Spec coverage:** lint (Task 3, deep-equal + recursive ignore from Task 1), completion (Task 2, embedded scripts, structural marker), doctor (Task 4, structural), explain (Task 5, structural). Matches the agreed Phase 2c scope (lint+completion deep-equal/embedded; doctor+explain structural because their values are environment/impl-divergent).

**Placeholder scan:** the MoonBit source-scan (lint), check logic (doctor), and action-key reuse (explain) are flagged "mirror existing usage / capture+match the oracle golden"; each is gated by a concrete scenario. The exact completion marker strings + lint message/exit are to be confirmed against captured oracle output.

**Risk:** doctor/explain conformance is intentionally structural (mustContain), not value-equal — it confirms the command runs, exits right, and emits the right shape/labels, but not message/hash parity (impossible across env + Go/MoonBit hash algorithms). lint's only volatile field (`path`) is dropped via the recursive ignore; line/level/kind/task/message/suggestion ARE compared.

## Carry to Phase 2d
mutation subcommands: init, format, hooks, clean, migrate, cache, pkl-cache (each with side-effects — fs-delta scenarios).
