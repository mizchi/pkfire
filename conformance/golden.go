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
