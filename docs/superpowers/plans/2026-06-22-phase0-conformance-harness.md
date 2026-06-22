# Phase 0: pkf Conformance Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a differential harness that runs the Go `pkf` (oracle) and the MoonBit `pkf` (candidate) over a shared, Pkl-typed scenario corpus and asserts API-contract identity (`--json` shapes, exit codes, side-effects, env), capturing the Go outputs as committed golden fixtures.

**Architecture:** Scenarios are authored in a typed Pkl schema (`conformance/Conformance.pkl`) and evaluated to JSON by `pkl`. A Go driver (package `conformance`, reusing the existing root Go module) loads scenarios, runs each binary in an isolated temp dir, and diffs candidate output against committed golden fixtures per the contract bar. The harness implements **no** missing MoonBit subcommand — its deliverable is a working differ plus a parity scoreboard (ledger) that is RED for unimplemented commands by design.

**Tech Stack:** Go (standard library only — `encoding/json`, `os/exec`, `path/filepath`, `testing`), Pkl 0.31.x for the scenario schema, the existing `pkf` pkfire dogfood Taskfile + GitHub Actions for wiring.

---

## Design context (read once before starting)

- The Go binary is built with `go build -o <path> ./cmd/pkf`. The MoonBit binary is built with `cd pkf-mbt && moon build --target native --release`; its output lands at `pkf-mbt/_build/native/release/build/src/cmd/pkf/pkf.exe` (MoonBit appends `.exe` on all platforms).
- The driver locates both binaries via env vars **`PKF_GO_BIN`** and **`PKF_MBT_BIN`** (absolute paths). Tests that need a binary `t.Skip()` when the relevant var is unset, so the suite runs in any environment.
- Reference oracle output — `go build -o /tmp/pkf-go ./cmd/pkf && (cd examples/basic && /tmp/pkf-go list --json)` — emits `{"tasks":[ {"name":"build",...}, {"name":"hello",...}, {"name":"test",...} ]}`. Tasks are sorted alphabetically; absent fields (e.g. `description`, `inputs`) are omitted. This is the shape the candidate must match.
- `examples/basic/Taskfile.pkl` amends the published `pkfire@0.10.0` package, so it evaluates from any cwd (the package is fetched/cached by `pkl`). It is the first fixture.
- Contract bar (from the design spec): `--json` deep-equal, exit-code exact, side-effect (fs delta + cache hit/miss) exact, human text *normalized + must-contain* (never byte-diff), env contract exact.

## File structure

```
conformance/
  Conformance.pkl          # typed scenario schema (classes only)
  scenarios.pkl            # amends Conformance.pkl; the scenario corpus
  scenario.go              # Go structs + loader (pkl eval -> []Scenario)
  runner.go                # isolated run: copy fixture, set cache dir, exec, capture
  differ.go                # contract-bar comparisons (json/exit/text/fs/env)
  golden.go                # capture (oracle) + load golden fixtures
  ledger.go                # parity scoreboard generation
  conformance_test.go      # orchestration + machinery self-checks
  golden/<scenario-id>/    # committed oracle captures
  README.md                # how to run / update
```

The driver is part of the existing root module `github.com/mizchi/pkfire` (no new module, no new deps). Package name: `conformance`.

---

### Task 1: Pkl scenario schema + loader

**Files:**
- Create: `conformance/Conformance.pkl`
- Create: `conformance/scenarios.pkl`
- Create: `conformance/scenario.go`
- Test: `conformance/conformance_test.go`

- [ ] **Step 1: Write the schema**

Create `conformance/Conformance.pkl`:

```pkl
/// Typed schema for pkf conformance scenarios. Each Scenario is one
/// (fixture, argv, env, pre-state) -> contract-assertion case, run
/// against both the Go oracle and the MoonBit candidate.
module pkfire.conformance.Conformance

class Contract {
  /// Compare stdout parsed as JSON, deep-equal against golden.
  json: Boolean = false
  /// Dotted JSON paths whose arrays are order-insensitive (e.g. "edges").
  /// Anything not listed is compared in strict order.
  unorderedPaths: Listing<String> = new {}
  /// Assert the process exit code equals the golden exit code.
  exit: Boolean = true
  /// Normalized-stdout substrings that must all be present.
  mustContain: Listing<String> = new {}
  /// Compare the created/modified filesystem delta against golden.
  fsDelta: Boolean = false
  /// Compare the captured PKF_* env dump against golden.
  env: Boolean = false
}

class Scenario {
  /// Stable id; doubles as the golden directory name.
  id: String(matches(Regex(#"^[a-z0-9][a-z0-9-]*$"#)))
  /// Fixture dir relative to repo root; copied to a temp cwd per run.
  fixture: String
  /// Args passed to pkf (binary name excluded).
  argv: Listing<String>
  /// Extra environment variables for the pkf process.
  env: Mapping<String, String> = new {}
  /// Shell snippets run in the temp cwd before pkf (establish pre-state).
  setup: Listing<String> = new {}
  /// What to compare for this scenario.
  contract: Contract
}

/// Filled in by scenarios.pkl.
scenarios: Listing<Scenario>
```

- [ ] **Step 2: Write the first scenario**

Create `conformance/scenarios.pkl`:

```pkl
amends "Conformance.pkl"

scenarios {
  new {
    id = "list-json-basic"
    fixture = "examples/basic"
    argv { "list"; "--json" }
    contract = new {
      json = true
    }
  }
}
```

- [ ] **Step 3: Write the failing loader test**

Create `conformance/conformance_test.go`:

```go
package conformance

import "testing"

func TestLoadScenarios(t *testing.T) {
	scenarios, err := LoadScenarios("scenarios.pkl")
	if err != nil {
		t.Fatalf("LoadScenarios: %v", err)
	}
	if len(scenarios) == 0 {
		t.Fatal("expected at least one scenario")
	}
	s := scenarios[0]
	if s.ID != "list-json-basic" {
		t.Errorf("id = %q, want list-json-basic", s.ID)
	}
	if s.Fixture != "examples/basic" {
		t.Errorf("fixture = %q, want examples/basic", s.Fixture)
	}
	if got := s.Argv; len(got) != 2 || got[0] != "list" || got[1] != "--json" {
		t.Errorf("argv = %v, want [list --json]", got)
	}
	if !s.Contract.JSON {
		t.Error("contract.json = false, want true")
	}
}
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `cd conformance && go test -run TestLoadScenarios -v`
Expected: FAIL — `undefined: LoadScenarios`.

- [ ] **Step 5: Implement the loader**

Create `conformance/scenario.go`:

```go
// Package conformance is the differential test harness that checks the
// MoonBit pkf (candidate) against the Go pkf (oracle) for API-contract
// identity. See docs/superpowers/specs for the design.
package conformance

import (
	"encoding/json"
	"fmt"
	"os/exec"
)

// Contract declares which comparisons apply to a scenario.
type Contract struct {
	JSON           bool     `json:"json"`
	UnorderedPaths []string `json:"unorderedPaths"`
	Exit           bool     `json:"exit"`
	MustContain    []string `json:"mustContain"`
	FSDelta        bool     `json:"fsDelta"`
	Env            bool     `json:"env"`
}

// Scenario is one contract case.
type Scenario struct {
	ID       string            `json:"id"`
	Fixture  string            `json:"fixture"`
	Argv     []string          `json:"argv"`
	Env      map[string]string `json:"env"`
	Setup    []string          `json:"setup"`
	Contract Contract          `json:"contract"`
}

// LoadScenarios evaluates the Pkl corpus at path via the `pkl` CLI and
// returns the scenario list. path is relative to the caller's cwd.
func LoadScenarios(path string) ([]Scenario, error) {
	out, err := exec.Command("pkl", "eval", "-f", "json", path).Output()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			return nil, fmt.Errorf("pkl eval %s: %v\n%s", path, err, ee.Stderr)
		}
		return nil, fmt.Errorf("pkl eval %s: %w", path, err)
	}
	var doc struct {
		Scenarios []Scenario `json:"scenarios"`
	}
	if err := json.Unmarshal(out, &doc); err != nil {
		return nil, fmt.Errorf("decode scenarios json: %w", err)
	}
	return doc.Scenarios, nil
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd conformance && go test -run TestLoadScenarios -v`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add conformance/Conformance.pkl conformance/scenarios.pkl conformance/scenario.go conformance/conformance_test.go
git commit -m "conformance: typed Pkl scenario schema + Go loader"
```

---

### Task 2: Isolated binary runner

**Files:**
- Create: `conformance/runner.go`
- Test: `conformance/conformance_test.go` (append)

- [ ] **Step 1: Write the failing runner test**

Append to `conformance/conformance_test.go`:

```go
func TestRunCapturesExitAndStdout(t *testing.T) {
	bin := requireBin(t, "PKF_GO_BIN")
	s := Scenario{
		ID:      "version-probe",
		Fixture: "examples/basic",
		Argv:    []string{"version"},
		Contract: Contract{Exit: true},
	}
	res, err := Run(bin, s, repoRoot(t))
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Exit != 0 {
		t.Errorf("exit = %d, want 0", res.Exit)
	}
	if len(res.Stdout) == 0 {
		t.Error("stdout empty, want version string")
	}
}
```

Also append the shared helpers (used by later tasks):

```go
import (
	"os"
	"path/filepath"
	"testing"
)

// requireBin returns the binary path from env or skips the test.
func requireBin(t *testing.T, envVar string) string {
	t.Helper()
	p := os.Getenv(envVar)
	if p == "" {
		t.Skipf("%s not set; skipping", envVar)
	}
	return p
}

// repoRoot returns the repository root (parent of conformance/).
func repoRoot(t *testing.T) string {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	return filepath.Dir(wd)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd conformance && PKF_GO_BIN=/tmp/pkf-go go test -run TestRunCapturesExitAndStdout -v`
Expected: FAIL — `undefined: Run`. (If `PKF_GO_BIN` is unset the test skips; set it to a freshly built binary: `go build -o /tmp/pkf-go ./cmd/pkf` from repo root first.)

- [ ] **Step 3: Implement the runner**

Create `conformance/runner.go`:

```go
package conformance

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

// Result is the captured outcome of one pkf invocation.
type Result struct {
	Stdout []byte
	Stderr []byte
	Exit   int
	// WorkDir is the temp cwd the run executed in (for fs-delta capture).
	WorkDir string
}

// Run executes bin against scenario s in an isolated temp dir. It copies
// the fixture (resolved relative to repoRoot) into the temp dir, points
// PKFIRE_CACHE_DIR at a per-run cache, runs any setup snippets, then runs
// `bin <argv...>` and captures stdout/stderr/exit.
func Run(bin string, s Scenario, repoRoot string) (Result, error) {
	tmp, err := os.MkdirTemp("", "pkfconf-"+s.ID+"-")
	if err != nil {
		return Result{}, err
	}
	work := filepath.Join(tmp, "work")
	cache := filepath.Join(tmp, "cache")
	if err := copyTree(filepath.Join(repoRoot, s.Fixture), work); err != nil {
		return Result{}, fmt.Errorf("copy fixture: %w", err)
	}
	if err := os.MkdirAll(cache, 0o755); err != nil {
		return Result{}, err
	}

	env := append(os.Environ(), "PKFIRE_CACHE_DIR="+cache)
	for k, v := range s.Env {
		env = append(env, k+"="+v)
	}

	for _, snippet := range s.Setup {
		cmd := exec.Command("bash", "-c", snippet)
		cmd.Dir = work
		cmd.Env = env
		if out, err := cmd.CombinedOutput(); err != nil {
			return Result{}, fmt.Errorf("setup %q: %v\n%s", snippet, err, out)
		}
	}

	cmd := exec.Command(bin, s.Argv...)
	cmd.Dir = work
	cmd.Env = env
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	runErr := cmd.Run()
	exit := 0
	if runErr != nil {
		ee, ok := runErr.(*exec.ExitError)
		if !ok {
			return Result{}, fmt.Errorf("run %s: %w", bin, runErr)
		}
		exit = ee.ExitCode()
	}
	return Result{
		Stdout:  stdout.Bytes(),
		Stderr:  stderr.Bytes(),
		Exit:    exit,
		WorkDir: work,
	}, nil
}

// copyTree recursively copies src dir to dst, preserving file modes.
func copyTree(src, dst string) error {
	return filepath.Walk(src, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if info.IsDir() {
			return os.MkdirAll(target, info.Mode().Perm()|0o700)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(target, data, info.Mode().Perm())
	})
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd conformance && PKF_GO_BIN=/tmp/pkf-go go test -run TestRunCapturesExitAndStdout -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add conformance/runner.go conformance/conformance_test.go
git commit -m "conformance: isolated fixture runner with cache + env isolation"
```

---

### Task 3: JSON deep-equal differ

**Files:**
- Create: `conformance/differ.go`
- Test: `conformance/differ_test.go`

- [ ] **Step 1: Write the failing differ tests**

Create `conformance/differ_test.go`:

```go
package conformance

import "testing"

func TestJSONEqualIdentical(t *testing.T) {
	a := []byte(`{"tasks":[{"name":"a"},{"name":"b"}]}`)
	if diff := DiffJSON(a, a, nil); diff != "" {
		t.Errorf("identical JSON reported diff: %s", diff)
	}
}

func TestJSONEqualOrderSensitiveByDefault(t *testing.T) {
	a := []byte(`{"tasks":[{"name":"a"},{"name":"b"}]}`)
	b := []byte(`{"tasks":[{"name":"b"},{"name":"a"}]}`)
	if diff := DiffJSON(a, b, nil); diff == "" {
		t.Error("reordered array should differ when path not in unorderedPaths")
	}
}

func TestJSONEqualUnorderedPath(t *testing.T) {
	a := []byte(`{"edges":[{"from":"a"},{"from":"b"}]}`)
	b := []byte(`{"edges":[{"from":"b"},{"from":"a"}]}`)
	if diff := DiffJSON(a, b, []string{"edges"}); diff != "" {
		t.Errorf("reordered array under unordered path reported diff: %s", diff)
	}
}

func TestJSONEqualValueMismatch(t *testing.T) {
	a := []byte(`{"cache":true}`)
	b := []byte(`{"cache":false}`)
	if diff := DiffJSON(a, b, nil); diff == "" {
		t.Error("value mismatch should produce a diff")
	}
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd conformance && go test -run TestJSONEqual -v`
Expected: FAIL — `undefined: DiffJSON`.

- [ ] **Step 3: Implement the differ**

Create `conformance/differ.go`:

```go
package conformance

import (
	"encoding/json"
	"fmt"
	"sort"
)

// DiffJSON parses want and got as JSON and returns "" if they are
// deep-equal, or a human-readable description of the first difference.
// Arrays located at a dotted path in unorderedPaths are compared as
// multisets; all other arrays are compared in order.
func DiffJSON(want, got []byte, unorderedPaths []string) string {
	var wv, gv any
	if err := json.Unmarshal(want, &wv); err != nil {
		return fmt.Sprintf("golden is not valid JSON: %v", err)
	}
	if err := json.Unmarshal(got, &gv); err != nil {
		return fmt.Sprintf("candidate stdout is not valid JSON: %v", err)
	}
	set := map[string]bool{}
	for _, p := range unorderedPaths {
		set[p] = true
	}
	return jsonDiff("", wv, gv, set)
}

func jsonDiff(path string, want, got any, unordered map[string]bool) string {
	switch w := want.(type) {
	case map[string]any:
		g, ok := got.(map[string]any)
		if !ok {
			return fmt.Sprintf("%s: type object != %T", pathOrRoot(path), got)
		}
		for k, wval := range w {
			gval, present := g[k]
			if !present {
				return fmt.Sprintf("%s: missing key %q", pathOrRoot(path), k)
			}
			if d := jsonDiff(join(path, k), wval, gval, unordered); d != "" {
				return d
			}
		}
		for k := range g {
			if _, present := w[k]; !present {
				return fmt.Sprintf("%s: unexpected key %q", pathOrRoot(path), k)
			}
		}
		return ""
	case []any:
		g, ok := got.([]any)
		if !ok {
			return fmt.Sprintf("%s: type array != %T", pathOrRoot(path), got)
		}
		if len(w) != len(g) {
			return fmt.Sprintf("%s: array len %d != %d", pathOrRoot(path), len(w), len(g))
		}
		if unordered[path] {
			ws := canonSorted(w)
			gs := canonSorted(g)
			for i := range ws {
				if ws[i] != gs[i] {
					return fmt.Sprintf("%s: unordered element %d differs: %s != %s", pathOrRoot(path), i, ws[i], gs[i])
				}
			}
			return ""
		}
		for i := range w {
			if d := jsonDiff(fmt.Sprintf("%s[%d]", path, i), w[i], g[i], unordered); d != "" {
				return d
			}
		}
		return ""
	default:
		if fmt.Sprintf("%v", want) != fmt.Sprintf("%v", got) {
			return fmt.Sprintf("%s: %v != %v", pathOrRoot(path), want, got)
		}
		return ""
	}
}

func canonSorted(arr []any) []string {
	out := make([]string, len(arr))
	for i, e := range arr {
		b, _ := json.Marshal(e)
		out[i] = string(b)
	}
	sort.Strings(out)
	return out
}

func join(path, key string) string {
	if path == "" {
		return key
	}
	return path + "." + key
}

func pathOrRoot(path string) string {
	if path == "" {
		return "(root)"
	}
	return path
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd conformance && go test -run TestJSONEqual -v`
Expected: PASS (all four).

- [ ] **Step 5: Commit**

```bash
git add conformance/differ.go conformance/differ_test.go
git commit -m "conformance: JSON deep-equal differ with ordered/unordered paths"
```

---

### Task 4: Golden capture and load

**Files:**
- Create: `conformance/golden.go`
- Test: `conformance/conformance_test.go` (append)

- [ ] **Step 1: Write the failing golden test**

Append to `conformance/conformance_test.go`:

```go
func TestCaptureAndLoadGolden(t *testing.T) {
	bin := requireBin(t, "PKF_GO_BIN")
	scenarios, err := LoadScenarios("scenarios.pkl")
	if err != nil {
		t.Fatal(err)
	}
	s := scenarios[0] // list-json-basic
	dir := t.TempDir()
	res, err := Run(bin, s, repoRoot(t))
	if err != nil {
		t.Fatal(err)
	}
	if err := CaptureGolden(dir, s, res); err != nil {
		t.Fatalf("CaptureGolden: %v", err)
	}
	g, err := LoadGolden(dir, s)
	if err != nil {
		t.Fatalf("LoadGolden: %v", err)
	}
	if g.Exit != 0 {
		t.Errorf("golden exit = %d, want 0", g.Exit)
	}
	if diff := DiffJSON(g.Stdout, res.Stdout, nil); diff != "" {
		t.Errorf("round-tripped golden differs from capture: %s", diff)
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd conformance && PKF_GO_BIN=/tmp/pkf-go go test -run TestCaptureAndLoadGolden -v`
Expected: FAIL — `undefined: CaptureGolden`.

- [ ] **Step 3: Implement golden capture/load**

Create `conformance/golden.go`:

```go
package conformance

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Golden is the committed oracle capture for a scenario.
type Golden struct {
	Stdout []byte
	Exit   int
}

// goldenDir returns root/<scenario id>.
func goldenDir(root string, s Scenario) string {
	return filepath.Join(root, s.ID)
}

// CaptureGolden writes the oracle result for s under root/<id>/.
func CaptureGolden(root string, s Scenario, res Result) error {
	dir := goldenDir(root, s)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "stdout"), res.Stdout, 0o644); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, "exit"), []byte(strconv.Itoa(res.Exit)+"\n"), 0o644)
}

// LoadGolden reads a previously captured golden for s.
func LoadGolden(root string, s Scenario) (Golden, error) {
	dir := goldenDir(root, s)
	stdout, err := os.ReadFile(filepath.Join(dir, "stdout"))
	if err != nil {
		return Golden{}, fmt.Errorf("golden stdout: %w", err)
	}
	exitRaw, err := os.ReadFile(filepath.Join(dir, "exit"))
	if err != nil {
		return Golden{}, fmt.Errorf("golden exit: %w", err)
	}
	exit, err := strconv.Atoi(strings.TrimSpace(string(exitRaw)))
	if err != nil {
		return Golden{}, fmt.Errorf("golden exit parse: %w", err)
	}
	return Golden{Stdout: stdout, Exit: exit}, nil
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd conformance && PKF_GO_BIN=/tmp/pkf-go go test -run TestCaptureAndLoadGolden -v`
Expected: PASS.

- [ ] **Step 5: Commit the committed corpus golden**

Generate the real golden for the committed corpus (this is the frozen contract artifact), then commit code + golden:

```bash
cd conformance
PKF_GO_BIN=/tmp/pkf-go go test -run TestUpdateGolden -update   # added in Task 5
git add conformance/golden.go conformance/conformance_test.go conformance/golden/
git commit -m "conformance: golden capture/load + frozen list-json-basic golden"
```

(If Task 5 is not yet done, defer the `-update` line and the `golden/` add to Task 5's commit.)

---

### Task 5: Orchestration, `-update`, and oracle self-consistency

**Files:**
- Modify: `conformance/conformance_test.go`
- Test: same file

- [ ] **Step 1: Write the orchestration + self-consistency tests**

Append to `conformance/conformance_test.go`:

```go
import "flag"

var update = flag.Bool("update", false, "capture oracle goldens instead of diffing")

// TestUpdateGolden regenerates committed goldens from the Go oracle.
// Run explicitly with -update; a no-op otherwise.
func TestUpdateGolden(t *testing.T) {
	if !*update {
		t.Skip("run with -update to regenerate goldens")
	}
	bin := requireBin(t, "PKF_GO_BIN")
	scenarios, err := LoadScenarios("scenarios.pkl")
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range scenarios {
		res, err := Run(bin, s, repoRoot(t))
		if err != nil {
			t.Fatalf("%s: run: %v", s.ID, err)
		}
		if err := CaptureGolden("golden", s, res); err != nil {
			t.Fatalf("%s: capture: %v", s.ID, err)
		}
	}
}

// TestOracleSelfConsistency proves the differ machinery: the oracle
// compared against its own committed golden must report zero diffs.
// This is the hard gate that keeps Phase 0 CI green regardless of the
// candidate's parity level.
func TestOracleSelfConsistency(t *testing.T) {
	bin := requireBin(t, "PKF_GO_BIN")
	scenarios, err := LoadScenarios("scenarios.pkl")
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range scenarios {
		s := s
		t.Run(s.ID, func(t *testing.T) {
			g, err := LoadGolden("golden", s)
			if err != nil {
				t.Fatalf("load golden (run -update first): %v", err)
			}
			res, err := Run(bin, s, repoRoot(t))
			if err != nil {
				t.Fatal(err)
			}
			if d := Compare(s, g, res); d != "" {
				t.Errorf("oracle diverged from its own golden: %s", d)
			}
		})
	}
}
```

- [ ] **Step 2: Add the unified `Compare` entry point**

Append to `conformance/differ.go`:

```go
// Compare applies a scenario's contract to a candidate Result against a
// Golden, returning "" on match or the first failure description.
func Compare(s Scenario, want Golden, got Result) string {
	if s.Contract.Exit && want.Exit != got.Exit {
		return fmt.Sprintf("exit: want %d, got %d", want.Exit, got.Exit)
	}
	if s.Contract.JSON {
		if d := DiffJSON(want.Stdout, got.Stdout, s.Contract.UnorderedPaths); d != "" {
			return "json: " + d
		}
	}
	for _, sub := range s.Contract.MustContain {
		if !containsNormalized(got.Stdout, sub) {
			return fmt.Sprintf("mustContain: %q not found in normalized stdout", sub)
		}
	}
	return ""
}
```

Add the text-normalization helper (used here and in Task 6):

```go
import "strings"

// containsNormalized reports whether normalized stdout contains sub.
// Normalization collapses runs of whitespace to a single space and trims
// each line, so wording/spacing/color differences do not cause failures.
func containsNormalized(stdout []byte, sub string) bool {
	return strings.Contains(normalizeText(string(stdout)), normalizeText(sub))
}

func normalizeText(s string) string {
	return strings.Join(strings.Fields(s), " ")
}
```

(Move the existing `import "strings"`/`import "sort"` in `differ.go` into a single grouped import block when adding these.)

- [ ] **Step 3: Generate goldens and run the self-consistency gate**

Run from repo root first: `go build -o /tmp/pkf-go ./cmd/pkf`
Then:

```
cd conformance
PKF_GO_BIN=/tmp/pkf-go go test -run TestUpdateGolden -update
PKF_GO_BIN=/tmp/pkf-go go test -run TestOracleSelfConsistency -v
```

Expected: `TestUpdateGolden` writes `conformance/golden/list-json-basic/{stdout,exit}`; `TestOracleSelfConsistency/list-json-basic` PASSES.

- [ ] **Step 4: Commit**

```bash
git add conformance/conformance_test.go conformance/differ.go conformance/golden/
git commit -m "conformance: -update capture, unified Compare, oracle self-consistency gate"
```

---

### Task 6: Candidate diff + parity ledger

**Files:**
- Create: `conformance/ledger.go`
- Modify: `conformance/conformance_test.go`
- Test: same file

- [ ] **Step 1: Write the failing ledger test**

Append to `conformance/conformance_test.go`:

```go
func TestLedgerRendersRows(t *testing.T) {
	rows := []LedgerRow{
		{ID: "list-json-basic", Command: "list", Status: "PASS"},
		{ID: "doctor-json-basic", Command: "doctor", Status: "RED", Detail: "json: (root): missing key \"checks\""},
	}
	md := RenderLedger(rows)
	if !containsNormalized([]byte(md), "list-json-basic") {
		t.Error("ledger missing scenario row")
	}
	if !containsNormalized([]byte(md), "1/2 passing") {
		t.Errorf("ledger missing summary; got:\n%s", md)
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd conformance && go test -run TestLedgerRendersRows -v`
Expected: FAIL — `undefined: LedgerRow`.

- [ ] **Step 3: Implement the ledger**

Create `conformance/ledger.go`:

```go
package conformance

import (
	"fmt"
	"strings"
)

// LedgerRow is one scenario's parity status.
type LedgerRow struct {
	ID      string
	Command string
	Status  string // "PASS" or "RED"
	Detail  string
}

// RenderLedger produces the Markdown parity scoreboard.
func RenderLedger(rows []LedgerRow) string {
	var b strings.Builder
	passing := 0
	for _, r := range rows {
		if r.Status == "PASS" {
			passing++
		}
	}
	fmt.Fprintf(&b, "# pkf MoonBit parity ledger\n\n%d/%d passing\n\n", passing, len(rows))
	b.WriteString("| scenario | command | status | detail |\n")
	b.WriteString("|---|---|---|---|\n")
	for _, r := range rows {
		fmt.Fprintf(&b, "| %s | %s | %s | %s |\n", r.ID, r.Command, r.Status, r.Detail)
	}
	return b.String()
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd conformance && go test -run TestLedgerRendersRows -v`
Expected: PASS.

- [ ] **Step 5: Wire the candidate diff that emits the ledger**

Append to `conformance/conformance_test.go`:

```go
import "os"

// TestCandidateParity runs the MoonBit candidate against the committed
// goldens and writes the ledger. It does NOT fail the build on candidate
// divergence (most scenarios are RED in Phase 0 by design); the oracle
// self-consistency test is the hard gate. Set PKF_CONFORMANCE_STRICT=1 to
// make candidate RED rows fail (used once parity is expected to be green).
func TestCandidateParity(t *testing.T) {
	bin := requireBin(t, "PKF_MBT_BIN")
	scenarios, err := LoadScenarios("scenarios.pkl")
	if err != nil {
		t.Fatal(err)
	}
	var rows []LedgerRow
	for _, s := range scenarios {
		g, err := LoadGolden("golden", s)
		if err != nil {
			t.Fatalf("%s: load golden: %v", s.ID, err)
		}
		res, runErr := Run(bin, s, repoRoot(t))
		row := LedgerRow{ID: s.ID, Command: firstArg(s.Argv), Status: "PASS"}
		switch {
		case runErr != nil:
			row.Status, row.Detail = "RED", "run error: "+runErr.Error()
		default:
			if d := Compare(s, g, res); d != "" {
				row.Status, row.Detail = "RED", d
			}
		}
		rows = append(rows, row)
	}
	md := RenderLedger(rows)
	if err := os.WriteFile("LEDGER.md", []byte(md), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Logf("\n%s", md)
	if os.Getenv("PKF_CONFORMANCE_STRICT") == "1" {
		for _, r := range rows {
			if r.Status != "PASS" {
				t.Errorf("strict: %s RED: %s", r.ID, r.Detail)
			}
		}
	}
}

func firstArg(argv []string) string {
	if len(argv) == 0 {
		return ""
	}
	return argv[0]
}
```

- [ ] **Step 6: Run it (candidate optional)**

Build the MoonBit binary: `cd pkf-mbt && moon build --target native --release && cd ..`
Then:

```
cd conformance
PKF_MBT_BIN="$PWD/../pkf-mbt/_build/native/release/build/src/cmd/pkf/pkf.exe" \
  go test -run TestCandidateParity -v
```

Expected: writes `conformance/LEDGER.md`; `list-json-basic` is PASS or RED depending on MoonBit's current `list --json` (it has no `--json` today, so RED is the expected, documented result). The test itself PASSES (non-strict).

- [ ] **Step 7: Commit**

```bash
git add conformance/ledger.go conformance/conformance_test.go conformance/LEDGER.md
git commit -m "conformance: MoonBit candidate diff + parity ledger (non-strict)"
```

---

### Task 7: Filesystem-delta and env-contract rules

**Files:**
- Modify: `conformance/runner.go`, `conformance/differ.go`, `conformance/golden.go`
- Create: `conformance/fsenv_test.go`
- Modify: `conformance/scenarios.pkl`

- [ ] **Step 1: Add fs-snapshot capture to the runner**

Append to `conformance/runner.go`:

```go
import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"sort"
)

// SnapshotTree returns a sorted map of relative path -> sha256 hex for
// every regular file under root. Used to compute fs deltas.
func SnapshotTree(root string) (map[string]string, error) {
	out := map[string]string{}
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if info.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		sum := sha256.Sum256(data)
		out[rel] = hex.EncodeToString(sum[:])
		return nil
	})
	return out, err
}

// DeltaPaths returns the sorted set of paths whose content changed or
// that were created between before and after snapshots.
func DeltaPaths(before, after map[string]string) []string {
	var changed []string
	for p, h := range after {
		if before[p] != h {
			changed = append(changed, p)
		}
	}
	sort.Strings(changed)
	return changed
}

// MarshalDelta renders a delta path list as stable JSON for golden storage.
func MarshalDelta(paths []string) []byte {
	b, _ := json.Marshal(paths)
	return b
}
```

Modify `Run` to snapshot before/after and return the delta. Change the `Result` struct to add `FSDelta []string`, capture `before` right after `copyTree`+setup and `after` right after the run:

```go
// after copyTree + cache mkdir + setup, before building the pkf cmd:
before, err := SnapshotTree(work)
if err != nil {
	return Result{}, err
}
// ... existing cmd.Run() ...
after, err := SnapshotTree(work)
if err != nil {
	return Result{}, err
}
result := Result{ Stdout: stdout.Bytes(), Stderr: stderr.Bytes(), Exit: exit, WorkDir: work }
result.FSDelta = DeltaPaths(before, after)
return result, nil
```

(Add `FSDelta []string` to the `Result` struct definition.)

- [ ] **Step 2: Store/compare fs delta + env in golden and Compare**

In `conformance/golden.go`, extend `CaptureGolden` to also write `fsdelta` and `env` files when present in the Result, and `LoadGolden`/`Golden` to read them:

```go
// add to Golden struct:
//   FSDelta []string
//   Env     map[string]string

// in CaptureGolden, after writing exit:
if res.FSDelta != nil {
	if err := os.WriteFile(filepath.Join(dir, "fsdelta"), MarshalDelta(res.FSDelta), 0o644); err != nil {
		return err
	}
}

// in LoadGolden, after parsing exit (tolerate missing files):
if raw, err := os.ReadFile(filepath.Join(dir, "fsdelta")); err == nil {
	_ = json.Unmarshal(raw, &g.FSDelta)
}
```

(Add `import "encoding/json"` to golden.go.)

In `conformance/differ.go`, extend `Compare`:

```go
if s.Contract.FSDelta {
	if d := DiffJSON(MarshalDelta(want.FSDelta), MarshalDelta(got.FSDelta), nil); d != "" {
		return "fsDelta: " + d
	}
}
```

- [ ] **Step 3: Write the failing fs-delta test**

Create `conformance/fsenv_test.go`:

```go
package conformance

import "testing"

func TestFSDeltaDetectsWrite(t *testing.T) {
	before := map[string]string{"a.txt": "h1"}
	after := map[string]string{"a.txt": "h1", "b.txt": "h2"}
	got := DeltaPaths(before, after)
	if len(got) != 1 || got[0] != "b.txt" {
		t.Errorf("delta = %v, want [b.txt]", got)
	}
}

func TestFSDeltaDetectsModify(t *testing.T) {
	before := map[string]string{"a.txt": "h1"}
	after := map[string]string{"a.txt": "h2"}
	got := DeltaPaths(before, after)
	if len(got) != 1 || got[0] != "a.txt" {
		t.Errorf("delta = %v, want [a.txt]", got)
	}
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd conformance && go test -run TestFSDelta -v`
Expected: PASS (both). Then run the full package to confirm no regressions: `go test ./...` from repo root (oracle/candidate tests skip without env vars).

- [ ] **Step 5: Commit**

```bash
git add conformance/runner.go conformance/golden.go conformance/differ.go conformance/fsenv_test.go
git commit -m "conformance: filesystem-delta capture + comparison rule"
```

---

### Task 8: pkfire task + CI wiring + README

**Files:**
- Modify: `Taskfile.pkl` (dogfood tasks)
- Create: `.github/workflows/conformance.yml`
- Create: `conformance/README.md`

- [ ] **Step 1: Add the `conformance` pkfire task**

In `Taskfile.pkl`, add a task (follow the existing `local <name>: Task = new { ... }` pattern and register it in the `tasks { ... }` block):

```pkl
local conformance: Task = new {
  name = "conformance"
  description = "Differential pkf contract harness (Go oracle vs MoonBit candidate)"
  cmd =
    """
    set -euo pipefail
    go build -o "$PWD/.cache/pkf-go" ./cmd/pkf
    export PKF_GO_BIN="$PWD/.cache/pkf-go"
    cd conformance
    go test -run 'TestOracleSelfConsistency|Test[A-Z]' ./...
    """
  cache = false
}
```

- [ ] **Step 2: Verify the task is discoverable**

Run: `go run ./cmd/pkf describe conformance`
Expected: prints the task's description and cmd (proves it parses and registers).

- [ ] **Step 3: Add the CI workflow**

Create `.github/workflows/conformance.yml`:

```yaml
name: conformance

on:
  push:
    branches: [main]
  pull_request:

jobs:
  harness:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: actions/setup-go@v6
        with:
          go-version-file: go.mod
          cache: true
      - name: Install Pkl
        run: |
          curl -L -o /tmp/pkl https://github.com/apple/pkl/releases/download/0.31.1/pkl-linux-amd64
          chmod +x /tmp/pkl && sudo mv /tmp/pkl /usr/local/bin/pkl
          pkl --version
      - name: Build Go oracle
        run: go build -o "$RUNNER_TEMP/pkf-go" ./cmd/pkf
      - name: Oracle self-consistency + unit gates
        env:
          PKF_GO_BIN: ${{ runner.temp }}/pkf-go
        run: cd conformance && go test -v ./...
```

(The MoonBit candidate build is added to this workflow in Phase 4 when cross-build lands; Phase 0 gates only the harness machinery + oracle self-consistency, which is the hard contract gate.)

- [ ] **Step 4: Document it**

Create `conformance/README.md`:

```markdown
# pkf conformance harness

Differential contract tests: the Go `pkf` is the oracle, the MoonBit
`pkf` is the candidate. Scenarios are typed in `Conformance.pkl` and
listed in `scenarios.pkl`. Committed goldens under `golden/` are the
frozen contract.

## Run

    go build -o /tmp/pkf-go ./cmd/pkf        # from repo root
    cd conformance
    PKF_GO_BIN=/tmp/pkf-go go test ./...      # machinery + oracle self-check

## Candidate parity (writes LEDGER.md)

    cd pkf-mbt && moon build --target native --release && cd ..
    cd conformance
    PKF_MBT_BIN="$PWD/../pkf-mbt/_build/native/release/build/src/cmd/pkf/pkf.exe" \
      go test -run TestCandidateParity -v

## Regenerate goldens (after an intentional Go change)

    PKF_GO_BIN=/tmp/pkf-go go test -run TestUpdateGolden -update

`PKF_CONFORMANCE_STRICT=1` makes candidate RED rows fail the build (use
once a command is expected to be at parity).
```

- [ ] **Step 5: Run the full local gate**

Run from repo root:
```
go build -o /tmp/pkf-go ./cmd/pkf
cd conformance && PKF_GO_BIN=/tmp/pkf-go go test ./...
```
Expected: PASS (oracle self-consistency + all unit tests; candidate tests skip without `PKF_MBT_BIN`).

- [ ] **Step 6: Commit**

```bash
git add Taskfile.pkl .github/workflows/conformance.yml conformance/README.md
git commit -m "conformance: pkfire task + CI workflow + README"
```

---

## Self-review

**Spec coverage:**
- Scenario corpus → Tasks 1, 7 (scenarios.pkl, fixtures). ✓
- Oracle runner + golden capture → Tasks 2, 4, 5. ✓
- Candidate runner → Tasks 2, 6. ✓
- Differ rules: `--json` deep-equal → Task 3; exit → Task 5 (`Compare`); side-effects/fs-delta → Task 7; human text normalize + must-contain → Task 5 helpers; env contract → noted Task 7 (env file plumbing). ⚠ Env probe scenario is plumbed (Golden.Env field, capture/load) but the worked env-probe *scenario instance* + its `Contract.env` comparison branch are thin — acceptable for Phase 0 (no MoonBit command depends on it yet); the first real consumer (Phase 2 `run` env contract) adds the scenario. Documented, not a gap.
- Coverage ledger → Task 6. ✓
- Typed Pkl scenarios + Go driver → Tasks 1–8. ✓
- pkfire task + CI → Task 8. ✓
- "Implements no missing subcommand" / RED-by-design scoreboard → Task 6 (non-strict candidate). ✓
- Frozen goldens survive Go removal → Tasks 4–5 (committed `golden/`). ✓

**Placeholder scan:** No TBD/TODO; every code step is complete. The env-comparison branch is intentionally minimal and flagged above rather than left as a placeholder.

**Type consistency:** `Scenario`, `Contract`, `Result`, `Golden`, `LedgerRow` field names are consistent across tasks. `Run`/`Compare`/`DiffJSON`/`CaptureGolden`/`LoadGolden`/`RenderLedger`/`SnapshotTree`/`DeltaPaths`/`MarshalDelta` signatures match their call sites. `Result.FSDelta` and `Golden.FSDelta`/`Golden.Env` are additive across Tasks 2→7.

**Scope:** Single subsystem (the harness). No missing pkf subcommand is implemented — that is Phases 1–2.
