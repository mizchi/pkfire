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
