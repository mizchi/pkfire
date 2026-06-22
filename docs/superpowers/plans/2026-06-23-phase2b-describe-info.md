# Phase 2b: MoonBit pkf `describe` + `info` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).

**Goal:** Add the `describe` and `info` introspection subcommands (plain + `--json`) to the MoonBit `pkf`, at structural parity with Go, reusing the Phase 2a encoder. Add a harness `jsonIgnorePaths` so `info --json`'s volatile absolute `taskfile` path can be excluded from comparison.

**Architecture:** `describe`/`info` are NEW subcommands (MoonBit has 8 of Go's ~18). Both take `-f`/`--file` (via the existing `extract_file_flag`) and `--json`. `info --json`'s `tasks` array reuses `task_to_json(t, false)`; `describe --json` needs a distinct encoder (different field set + omitempty bools). Verified by conformance scenarios (goldens from the Go oracle).

**Tech Stack:** MoonBit (native; build via `pkf-mbt/scripts/build-native.sh`), Go (harness), Pkl (scenarios/fixtures).

---

## Ground truth (Go oracle)

### `describe --json <task>` — `{...}` (only set fields; **bools omitempty**)
Fields (Go `printDescribeJSON`):
- `name` (always), `description` (if set), `visibility` (always), `service` (omit if false), `workdir` (if set), `params` (if any), `acceptsArgs` (omit if false), `inputs` (if non-empty), `outputs` (if non-empty), `cache` (always), `deps` (if non-empty), `services` (if non-empty), `cmd` (always), `env` (if non-empty), `tools` (if non-empty), `specRef` (if set).
- `params[]` = `{name, type (default "string" if empty), default?, choices?, description?}`.
- Note: unlike `list --json`, `describe` OMITS `service`/`acceptsArgs` when false, and has NO `shell`/`shellFlags`/`quiet`/`inheritEnv`.
- Unknown task → exit 1, stderr `pkf: unknown task: "<name>" (try ...)`.

### `info --json` — `{taskfile, schemaVersion?, amends?, defaults?, tasks, workflowTests?}`
- `taskfile` = ABSOLUTE path (volatile — must be ignored in conformance).
- `schemaVersion` = e.g. `pkfire@0.10.0` (extracted from amends; omit if none).
- `amends` = the amends URI string (omit if none).
- `defaults` = `{shell, shellFlags, env?}` (omit if no defaults).
- `tasks` = array of the SAME objects as `list --json` (`task_to_json(t, false)`), default public-only, `--all` includes internal. Sorted alphabetically.
- `workflowTests` = `[{name, changed?, tasks?, direct?}]` (omit if none). examples/basic has none.

## Current MoonBit reality

- Phase 2a encoder in `pkf-mbt/src/cmd/pkf/main.mbt`: `task_to_json(t, with_kind)`, `jbool`, `jstr_array`, `sorted_visible_tasks(plan, include_all)`, `lex_cmp`; `Json::string/array/object/boolean` factory methods; `Json::stringify`.
- `struct Param { name; ptype; choices; default : String? }` — **no `description`** (Go param has one; add it).
- `parse_plan` does NOT capture the amends URI / schema version (info must scan the Taskfile source).
- Dispatch in `run_main` matches `args[0]`; new arms go before `other =>`. `extract_file_flag(args)` pulls leading `-f`/`--file`. `eprintln` → stderr; `die` → stderr + exit 1.
- `Plan { default_env; tasks; task_order; workflow_tests : Array[WorkflowTest] }`, `WorkflowTest { name; changed; tasks; direct }`.

---

### Task 1: Harness `jsonIgnorePaths`

**Files:** `conformance/Conformance.pkl`, `conformance/scenario.go`, `conformance/differ.go`, test.

- [ ] **Step 1:** In `Conformance.pkl` `class Contract`, add:
```pkl
  /// Top-level JSON keys to delete from BOTH sides before deep-compare
  /// (for volatile values like absolute paths).
  jsonIgnorePaths: Listing<String> = new {}
```
- [ ] **Step 2:** In `scenario.go` `Contract`, add `JsonIgnorePaths []string` json:"jsonIgnorePaths"`.
- [ ] **Step 3:** In `differ.go`, change `Compare`'s JSON branch to strip ignored top-level keys before `DiffJSON`. Add a helper:
```go
func stripJSONKeys(raw []byte, keys []string) []byte {
	if len(keys) == 0 {
		return raw
	}
	var v any
	if err := json.Unmarshal(raw, &v); err != nil {
		return raw // let DiffJSON surface the parse error
	}
	if m, ok := v.(map[string]any); ok {
		for _, k := range keys {
			delete(m, k)
		}
	}
	out, err := json.Marshal(v)
	if err != nil {
		return raw
	}
	return out
}
```
and in `Compare`'s `if s.Contract.JSON {` block:
```go
		w := stripJSONKeys(want.Stdout, s.Contract.JsonIgnorePaths)
		g := stripJSONKeys(got.Stdout, s.Contract.JsonIgnorePaths)
		if d := DiffJSON(w, g, s.Contract.UnorderedPaths); d != "" {
			return "json: " + d
		}
```
(Add `import "encoding/json"` if not already in differ.go.)
- [ ] **Step 4:** Failing test in `conformance_test.go`:
```go
func TestCompareJSONIgnorePaths(t *testing.T) {
	s := Scenario{Contract: Contract{JSON: true, JsonIgnorePaths: []string{"taskfile"}}}
	want := Golden{Stdout: []byte(`{"taskfile":"/tmp/a/Taskfile.pkl","schemaVersion":"pkfire@0.10.0"}`)}
	got := Result{Stdout: []byte(`{"taskfile":"/tmp/DIFFERENT/Taskfile.pkl","schemaVersion":"pkfire@0.10.0"}`)}
	if d := Compare(s, want, got); d != "" {
		t.Errorf("ignored path should not cause diff: %s", d)
	}
	got.Stdout = []byte(`{"taskfile":"/x","schemaVersion":"pkfire@0.11.0"}`)
	if Compare(s, want, got) == "" {
		t.Error("non-ignored field mismatch should diff")
	}
}
```
- [ ] **Step 5:** `cd conformance && go test -run 'TestCompareJSONIgnorePaths|TestOracleSelfConsistency' -v` (build oracle first) → PASS. `gofmt -w conformance/`; `go vet ./conformance/...` clean.
- [ ] **Step 6:** Commit `conformance/` — `pkf-mbt-conformance? no:` `git commit -m "$(printf 'conformance: jsonIgnorePaths contract (ignore volatile JSON keys)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"`

---

### Task 2: `describe` subcommand

**Files:** `pkf-mbt/src/cmd/pkf/main.mbt`, `conformance/scenarios.pkl`, fixture, goldens.

- [ ] **Step 1: Param.description.** Add `description : String?` to `struct Param` and parse it in `parse_plan` (read `"description"` from the param object → `String?`, like other optional strings).
- [ ] **Step 2: Rich fixture.** Create `examples/describe-rich/Taskfile.pkl` (amends like basic) with one task exercising the describe fields:
```pkl
local deploy = new Task {
  name = "deploy"
  description = "ship it"
  cmd = "echo deploy $ENV"
  workdir = "sub"
  acceptsArgs = true
  inputs { "src/**" }
  outputs { "dist/**" }
  env { ["ENV"] = "prod" }
  params {
    new { name = "region"; type = "enum"; choices { "us"; "eu" }; default = "us"; description = "target region" }
  }
}
local base = new Task { name = "base"; cmd = "echo base" }
local app = new Task { name = "app"; cmd = "echo app"; deps { base } }
tasks { deploy; base; app }
```
Confirm it evaluates with the oracle: `(cd examples/describe-rich && /tmp/pkf-go describe --json deploy)`.
- [ ] **Step 3: Scenarios.** In `conformance/scenarios.pkl`:
```pkl
  new { id = "describe-json-rich"; fixture = "examples/describe-rich"; argv { "describe"; "--json"; "deploy" }; contract = new { json = true } }
  new { id = "describe-json-deps"; fixture = "examples/describe-rich"; argv { "describe"; "--json"; "app" }; contract = new { json = true } }
  new { id = "describe-unknown"; fixture = "examples/basic"; argv { "describe"; "nope" }; contract = new { exit = true; stdoutEmpty = true; mustContainStderr { "unknown task" } } }
```
Capture goldens + oracle self-consistency. READ `conformance/golden/describe-json-rich/stdout` to learn the exact contract (param shape, omitempty bools, env map).
- [ ] **Step 4: Implement.** In `run_main`, add a `"describe" => { ... }` arm (before `other =>`): `extract_file_flag`, then expect a `--json` flag + exactly one task name in the remaining args. Load plan, look up the task; if missing → `die("unknown task: \"\{name}\" (try \`pkf list --all\`)")` (exit 1, stderr). Add a `describe_to_json(t : Task) -> Json` encoder matching the Go field set (bools omitempty: `service`/`acceptsArgs` only when true; `cache` always; `params`/`env`/`tools`/`inputs`/`outputs`/`deps`/`services`/`workdir`/`description`/`specRef` when present). For `--json`: `println(describe_to_json(t).stringify())`. For plain: a readable summary (semantic only — not byte-matched). Build + iterate to PASS.
  - params encoder: array of `{name, type, default?, choices?, description?}` (type defaults "string" if `ptype==""`). env/tools as Json objects from the Map. Mirror Phase 2a factory-method style.
- [ ] **Step 5: Verify.** Candidate ledger: `describe-json-rich`, `describe-json-deps`, `describe-unknown` PASS; all prior rows PASS; oracle gate green; vet/gofmt clean.
- [ ] **Step 6: Commit** `pkf-mbt/src/cmd/pkf/main.mbt conformance/ examples/describe-rich/` — `... -m "pkf-mbt: describe subcommand (plain + --json, Go parity)\n\nCo-Authored-By: ..."`.

---

### Task 3: `info` subcommand

**Files:** `pkf-mbt/src/cmd/pkf/main.mbt`, `conformance/scenarios.pkl`, goldens.

- [ ] **Step 1: amends/schema scan.** Add a helper that reads the located Taskfile source (`@fs.read_file_to_string` or the existing read API — mirror how the loader reads files) and extracts the `amends "<URI>"` line's URI, plus the schema version (the `pkfire@<version>` substring before `#`). Return `(amends : String?, schema_version : String?)`. Use string ops (find `amends "`, then the closing `"`; for version find `pkfire@` … next `#` or `"`).
- [ ] **Step 2: Scenario.** In `conformance/scenarios.pkl`:
```pkl
  new {
    id = "info-json-basic"
    fixture = "examples/basic"
    argv { "info"; "--json" }
    contract = new { json = true; jsonIgnorePaths { "taskfile" } }
  }
```
Capture golden + oracle self-consistency. (The `taskfile` abs path is ignored; everything else must match.)
- [ ] **Step 3: Implement.** In `run_main`, add `"info" => { ... }`: `extract_file_flag`, `--json`, `--all`, reject positional args. Build the snapshot JSON:
```moonbit
let root : Map[String, Json] = Map::new()
root["taskfile"] = Json::string(absolute_taskfile_path)   // abs path (ignored by harness)
match schema_version { Some(v) => root["schemaVersion"] = Json::string(v); None => () }
match amends { Some(a) => root["amends"] = Json::string(a); None => () }
// defaults (omit if none): { shell, shellFlags, env? }
// tasks: Json::array of task_to_json(t, false) for sorted_visible_tasks(plan, all)
// workflowTests (omit if empty): [{name, changed?, tasks?, direct?}]
println(Json::object(root).stringify())
```
For the absolute taskfile path: resolve the located Taskfile to absolute (mirror how Phase 1's discovery/`repo_root` got an absolute dir; combine with cwd if needed). The harness ignores it, so exactness doesn't matter — but it must be a string. `defaults`: build from `plan.default_env` + the default shell/shellFlags (check whether the Plan carries defaults; Go's defaults come from `tf.Defaults`. If MoonBit's Plan only has `default_env`, emit `{shell:"bash", shellFlags:["-c"], env?}` — but VERIFY against the oracle golden: the basic golden `defaults` is `{shell:"bash", shellFlags:["-c"]}`. If MoonBit lacks the defaults' shell/shellFlags, hardcoding the schema defaults matches basic; for a Taskfile overriding defaults it would diverge — note this as a follow-up if MoonBit doesn't parse top-level defaults). Plain form: a readable summary.
- [ ] **Step 4: Verify.** Candidate ledger: `info-json-basic` PASS (taskfile ignored, rest deep-equal); all prior rows PASS; oracle gate green; vet/gofmt clean.
- [ ] **Step 5: Commit.**

---

## Self-review

**Spec coverage:** describe (Task 2) + info (Task 3), both plain + `--json`, reusing the Phase 2a encoder for info's tasks; harness gains `jsonIgnorePaths` (Task 1) for info's volatile `taskfile`. Param gains `description`. Matches Phase 2b scope (the two remaining introspection subcommands). diagnostics → 2c, mutation → 2d.

**Placeholder scan:** the amends/path/defaults MoonBit APIs are flagged "mirror existing usage / verify against the oracle golden"; each command is gated by a concrete scenario. The rich fixture + describe-unknown lock the omitempty-bool and error-path edges the basic fixture misses.

**Type consistency:** `describe_to_json(t)`, the info snapshot builder, `Param.description`, and the reused `task_to_json`/`sorted_visible_tasks`/`extract_file_flag` are consistent. `jsonIgnorePaths` flows Conformance.pkl → scenario.go Contract → Compare.

**Risk:** info's `defaults` and `taskfile`-absolutization depend on what MoonBit's `Plan` carries — if top-level Pkl `defaults` (custom shell) aren't parsed, info diverges for a Taskfile that overrides defaults (examples/basic uses the schema defaults, so the scenario passes). Flag for a follow-up if the oracle golden reveals a gap.
