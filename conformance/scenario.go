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
	JSON              bool     `json:"json"`
	UnorderedPaths    []string `json:"unorderedPaths"`
	Exit              bool     `json:"exit"`
	MustContain       []string `json:"mustContain"`
	FSDelta           bool     `json:"fsDelta"`
	Env               bool     `json:"env"`
	MustContainStderr []string `json:"mustContainStderr"`
	StdoutEmpty       bool     `json:"stdoutEmpty"`
	StdoutNonEmpty    bool     `json:"stdoutNonEmpty"`
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
