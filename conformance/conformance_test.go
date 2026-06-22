package conformance

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
