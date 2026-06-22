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
