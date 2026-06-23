package conformance

import (
	"flag"
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

func TestRunCapturesExitAndStdout(t *testing.T) {
	bin := requireBin(t, "PKF_GO_BIN")
	s := Scenario{
		ID:       "version-probe",
		Fixture:  "examples/basic",
		Argv:     []string{"version"},
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

func TestDeletedPaths(t *testing.T) {
	before := map[string]string{"a.txt": "h1", "b.txt": "h2"}
	after := map[string]string{"a.txt": "h1"}
	got := DeletedPaths(before, after)
	if len(got) != 1 || got[0] != "b.txt" {
		t.Errorf("deleted = %v, want [b.txt]", got)
	}
}

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

func TestCompareStdoutNonEmpty(t *testing.T) {
	s := Scenario{Contract: Contract{Exit: true, StdoutNonEmpty: true}}
	want := Golden{Exit: 0}
	if Compare(s, want, Result{Exit: 0, Stdout: []byte("v1.2.3\n")}) != "" {
		t.Error("non-empty stdout should satisfy stdoutNonEmpty")
	}
	if Compare(s, want, Result{Exit: 0, Stdout: []byte("   \n")}) == "" {
		t.Error("whitespace-only stdout should violate stdoutNonEmpty")
	}
}

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
