# Phase 2a: MoonBit pkf `--json` encoder + list/graph parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Build the shared JSON encoder for the MoonBit `pkf` and bring `list --json` and `graph --json` to byte-structural parity with the Go `pkf`, turning `list-json-basic` green and adding a `graph-json-basic` scenario.

**Architecture:** A small encoder builds `moonbitlang/core/json` `Json` values (the enum `String/Array/Object/True/False/...`, already used by `parse_plan`) from the in-memory `Task`, matching Go's `listTaskJSON` field set + omitempty, and renders with `Json::stringify`. The conformance differ parses both sides and deep-compares, so JSON *formatting* is irrelevant — only structure (keys/values/omitempty) and, for ordered arrays, element order matter.

**Tech Stack:** MoonBit (native). No new deps (`moonbitlang/core/json` already imported as `@json`). Build/verify via `pkf-mbt/scripts/build-native.sh` + the conformance harness.

---

## Ground truth (Go oracle, on `examples/basic`)

`list --json` → `{"tasks":[ T... ]}`, tasks **sorted alphabetically**. Each task object `T`:
- Always: `name`(str), `visibility`(str), `cmd`(str), `shell`(str), `shellFlags`(str[]), `cache`(bool), `service`(bool), `quiet`(bool), `acceptsArgs`(bool), `inheritEnv`(bool).
- omitempty: `description` (only if set), `inputs` (only if non-empty), `outputs` (only if non-empty), `deps` (only if non-empty).
- NOT emitted: env, tools, workdir, params, services, ready*, shutdownTimeout.

`graph --json` → `{"tasks":[ T+kind... ], "edges":[ {"from":dep,"to":task} ]}`. Same `T` objects PLUS `"kind":"task"`. An edge is emitted for every (dep → task) pair. Tasks sorted alphabetically; edge order is not guaranteed (compare unordered).

JSON object key ORDER does not matter (the differ compares objects by key). Array order matters only for `tasks` (sorted) — `edges` compared unordered.

## Current MoonBit reality (`pkf-mbt/src/cmd/pkf/main.mbt`)

- `Json` enum (from builtin, already used unqualified in `parse_plan`): `Null`, `True`, `False`, `Number(Double,..)`, `String(String)`, `Array(Array[Json])`, `Object(Map[String, Json])`. Render: `Json::stringify(indent?~)`.
- `struct Task { name; cmd; shell; shell_flags; inputs; outputs; deps; env; tools; cache; workdir; inherit_env; params; accepts_args; service; services; ready_port; ready_cmd; ready_timeout_seconds; shutdown_timeout_seconds; description : String?; visibility }` — **no `quiet` field** (Go emits it; must add).
- `parse_plan` extracts each field from the parsed `Object` via `.get("…")` + match.
- After Phase 1, `list_cmd` / `graph_cmd` take `(explicit_taskfile : String?, args)`. They already parse `--all` etc. and print plain output. `println` → stdout.
- `list` plain output is declaration order; `list --json` must be **alphabetical** (sort by name).

## File structure

```
pkf-mbt/src/cmd/pkf/main.mbt   # +quiet field & parse, +json encoder, list/graph --json
conformance/scenarios.pkl      # +graph-json-basic (list-json-basic already exists)
conformance/golden/            # +graph-json-basic golden
```

---

### Task 1: Add `quiet` to the Task model

**Files:** Modify `pkf-mbt/src/cmd/pkf/main.mbt`.

- [ ] **Step 1:** Add `quiet : Bool` to `struct Task` (near `service : Bool`).
- [ ] **Step 2:** In `parse_plan`, where the task object fields are extracted, read `quiet` (Pkl emits it as a bool; default false):

```moonbit
let quiet = match obj.get("quiet") { Some(True) => true; _ => false }
```
and set it in the constructed `Task { ... quiet, ... }`. (Mirror how the existing `cache`/`service` bools are read — if they use a helper, reuse it.)

- [ ] **Step 3:** Build: `./pkf-mbt/scripts/build-native.sh` → 0 errors. (No behavior change yet; just compiles with the new field.)
- [ ] **Step 4:** Commit.
```bash
git add pkf-mbt/src/cmd/pkf/main.mbt
git commit -m "$(printf 'pkf-mbt: parse Task.quiet (needed for --json parity)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 2: JSON encoder helpers

**Files:** Modify `pkf-mbt/src/cmd/pkf/main.mbt`.

- [ ] **Step 1:** Add encoder helpers (place near `parse_plan`). Adjust syntax to compile (the `Json` constructors are already used unqualified in this file; `Map` is `@moonbitlang/core/builtin`):

```moonbit
fn jbool(b : Bool) -> Json {
  if b { True } else { False }
}

fn jstr_array(xs : Array[String]) -> Json {
  let arr : Array[Json] = []
  for x in xs {
    arr.push(String(x))
  }
  Array(arr)
}

// Build the Go-compatible task JSON object. with_kind adds "kind":"task"
// (used by `graph --json`).
fn task_to_json(t : Task, with_kind : Bool) -> Json {
  let o : Map[String, Json] = Map::new()
  o["name"] = String(t.name)
  match t.description {
    Some(d) => o["description"] = String(d)
    None => ()
  }
  o["visibility"] = String(t.visibility)
  o["cmd"] = String(t.cmd)
  o["shell"] = String(t.shell)
  o["shellFlags"] = jstr_array(t.shell_flags)
  if t.inputs.length() > 0 {
    o["inputs"] = jstr_array(t.inputs)
  }
  if t.outputs.length() > 0 {
    o["outputs"] = jstr_array(t.outputs)
  }
  if t.deps.length() > 0 {
    o["deps"] = jstr_array(t.deps)
  }
  o["cache"] = jbool(t.cache)
  o["service"] = jbool(t.service)
  o["quiet"] = jbool(t.quiet)
  o["acceptsArgs"] = jbool(t.accepts_args)
  o["inheritEnv"] = jbool(t.inherit_env)
  if with_kind {
    o["kind"] = String("task")
  }
  Object(o)
}

// Visible tasks (exclude visibility=="internal" unless include_all), sorted
// by name — the order `list --json` / `graph --json` emit.
fn sorted_visible_tasks(plan : Plan, include_all : Bool) -> Array[Task] {
  let names : Array[String] = []
  for name in plan.task_order {
    match plan.tasks.get(name) {
      Some(t) =>
        if include_all || t.visibility != "internal" {
          names.push(name)
        }
      None => ()
    }
  }
  names.sort()
  let out : Array[Task] = []
  for n in names {
    match plan.tasks.get(n) {
      Some(t) => out.push(t)
      None => ()
    }
  }
  out
}
```
(Confirm `Map::new()`, `Array::push`, `Array::sort`, `Map::get` names against the toolchain; mirror existing usage in the file. `plan.task_order` / `plan.tasks` are the existing `Plan` fields.)

- [ ] **Step 2:** Build: `./pkf-mbt/scripts/build-native.sh` → 0 errors (helpers unused-but-compile is fine; MoonBit may warn — acceptable).
- [ ] **Step 3:** Commit.
```bash
git add pkf-mbt/src/cmd/pkf/main.mbt
git commit -m "$(printf 'pkf-mbt: JSON encoder helpers for task objects (Go shape)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 3: `list --json`

**Files:** Modify `pkf-mbt/src/cmd/pkf/main.mbt`. Scenario `list-json-basic` already exists.

- [ ] **Step 1:** In `list_cmd`, detect a `--json` flag in its args (alongside the existing `--all`/`-v` handling). When `--json` is set: load the plan, build `{"tasks":[ task_to_json(t, false) for t in sorted_visible_tasks(plan, all) ]}`, and `println` the rendered string. Sketch:

```moonbit
if json_flag {
  let arr : Array[Json] = []
  for t in sorted_visible_tasks(plan, all_flag) {
    arr.push(task_to_json(t, false))
  }
  let root : Map[String, Json] = Map::new()
  root["tasks"] = Array(arr)
  println(Object(root).stringify())
  return 0
}
// else: existing plain list output
```
(Thread it so `--json` short-circuits before the plain rendering. Keep plain output unchanged.)

- [ ] **Step 2:** Build + verify the row goes green:
```
cd <repo> && go build -o /tmp/pkf-go ./cmd/pkf && ./pkf-mbt/scripts/build-native.sh
cd conformance
MBT="$(cd .. && pwd)/pkf-mbt/_build/native/release/build/src/cmd/pkf/pkf.exe"
PKF_GO_BIN=/tmp/pkf-go go test ./...                                  # oracle gate stays green
PKF_GO_BIN=/tmp/pkf-go PKF_MBT_BIN="$MBT" go test -run TestCandidateParity -v
```
Expected: `list-json-basic` flips to **PASS** (deep-equal vs the Go golden). All prior rows still PASS. If it's RED, read the diff the ledger prints (e.g. a missing/extra key) and fix the encoder.

- [ ] **Step 3:** Commit.
```bash
git add pkf-mbt/src/cmd/pkf/main.mbt
git commit -m "$(printf 'pkf-mbt: list --json (Go-parity task JSON)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

### Task 4: `graph --json`

**Files:** Modify `pkf-mbt/src/cmd/pkf/main.mbt`; add scenario `conformance/scenarios.pkl` + golden.

- [ ] **Step 1:** Add the scenario. In `conformance/scenarios.pkl`:

```pkl
  new {
    id = "graph-json-basic"
    fixture = "examples/basic"
    argv { "graph"; "--json" }
    contract = new {
      json = true
      unorderedPaths { "edges" }
    }
  }
```

- [ ] **Step 2:** Capture golden + oracle self-consistency.
```
cd <repo> && go build -o /tmp/pkf-go ./cmd/pkf
cd conformance && PKF_GO_BIN=/tmp/pkf-go go test -run TestUpdateGolden -update
PKF_GO_BIN=/tmp/pkf-go go test -run TestOracleSelfConsistency -v       # graph-json-basic PASS
```

- [ ] **Step 3:** Implement `graph --json` in `graph_cmd`. When `--json` is set: build tasks (sorted, `with_kind=true`) and edges:

```moonbit
if json_flag {
  let tasks_arr : Array[Json] = []
  let visible = sorted_visible_tasks(plan, all_flag)
  for t in visible {
    tasks_arr.push(task_to_json(t, true))
  }
  let edges_arr : Array[Json] = []
  for t in visible {
    for dep in t.deps {
      let e : Map[String, Json] = Map::new()
      e["from"] = String(dep)
      e["to"] = String(t.name)
      edges_arr.push(Object(e))
    }
  }
  let root : Map[String, Json] = Map::new()
  root["tasks"] = Array(tasks_arr)
  root["edges"] = Array(edges_arr)
  println(Object(root).stringify())
  return 0
}
// else: existing plain graph output
```
(Go emits an edge `from=dep, to=task` for each dependency. If the golden shows the opposite direction, flip — but the captured oracle has `{"from":"build","to":"test"}` where `build` is a dep of `test`, matching `from=dep,to=task`.)

- [ ] **Step 4:** Build + verify.
```
cd <repo> && ./pkf-mbt/scripts/build-native.sh
cd conformance && MBT="$(cd .. && pwd)/pkf-mbt/_build/native/release/build/src/cmd/pkf/pkf.exe"
PKF_GO_BIN=/tmp/pkf-go PKF_MBT_BIN="$MBT" go test -run TestCandidateParity -v
```
Expected: `graph-json-basic` PASS and `list-json-basic` PASS; all foundation rows still PASS. Run `go vet ./conformance/...` + `gofmt -l conformance/` (clean).

- [ ] **Step 5:** Commit.
```bash
git add pkf-mbt/src/cmd/pkf/main.mbt conformance/scenarios.pkl conformance/golden/
git commit -m "$(printf 'pkf-mbt: graph --json (tasks + edges, Go parity)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>')"
```

---

## Self-review

**Spec coverage:** encoder (Task 2) + `quiet` (Task 1) + `list --json` (Task 3, turns `list-json-basic` green) + `graph --json` (Task 4, new `graph-json-basic`). Matches the Phase 2a scope (introspection `--json` for the two commands that already exist). `describe`/`info` (new subcommands) are Phase 2b; diagnostics Phase 2c; mutation Phase 2d. `affected` has no `--json` in Go — out of scope.

**Placeholder scan:** MoonBit stdlib specifics (`Map::new`, `Array::sort`, the exact bool-parse helper) are flagged "mirror existing usage / confirm against the compiler" — each task is gated by a concrete conformance scenario. No blank TODOs.

**Type consistency:** `task_to_json(t, with_kind)`, `jbool`, `jstr_array`, `sorted_visible_tasks(plan, include_all)` are used consistently by Tasks 3–4. `Task.quiet` added in Task 1 is consumed by the encoder in Task 2.

**Scope:** encoder + two existing commands' `--json`. No new subcommands, no diagnostics/mutation.

## Carry to Phase 2b

`describe` and `info` are NEW subcommands (not in MoonBit's 6). Phase 2b adds them with plain + `--json` forms (`describe --json <task>` → small object `{name, description?, visibility, cache, cmd}`; `info --json` → `{taskfile, schemaVersion, amends, defaults, tasks}`), reusing this encoder.
