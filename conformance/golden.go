package conformance

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Golden is the committed oracle capture for a scenario.
type Golden struct {
	Stdout  []byte
	Exit    int
	FSDelta []string
	Env     map[string]string // forward-compat; not compared yet
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
	if err := os.WriteFile(filepath.Join(dir, "exit"), []byte(strconv.Itoa(res.Exit)+"\n"), 0o644); err != nil {
		return err
	}
	if res.FSDelta != nil {
		if err := os.WriteFile(filepath.Join(dir, "fsdelta"), MarshalDelta(res.FSDelta), 0o644); err != nil {
			return err
		}
	}
	return nil
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
	g := Golden{Stdout: stdout, Exit: exit}
	if raw, err := os.ReadFile(filepath.Join(dir, "fsdelta")); err == nil {
		_ = json.Unmarshal(raw, &g.FSDelta)
	}
	return g, nil
}
