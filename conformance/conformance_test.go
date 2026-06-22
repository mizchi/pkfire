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
