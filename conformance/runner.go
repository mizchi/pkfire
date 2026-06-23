package conformance

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
)

// Result is the captured outcome of one pkf invocation.
type Result struct {
	Stdout []byte
	Stderr []byte
	Exit   int
	// WorkDir is the temp cwd the run executed in (for fs-delta capture).
	WorkDir string
	// FSDelta is the sorted list of relative paths created or modified by the command.
	FSDelta []string
	// FSDeleted is the sorted list of relative paths removed by the command.
	FSDeleted []string
}

// Run executes bin against scenario s in an isolated temp dir. It copies
// the fixture (resolved relative to repoRoot) into the temp dir, points
// PKFIRE_CACHE_DIR at a per-run cache, runs any setup snippets, then runs
// `bin <argv...>` and captures stdout/stderr/exit.
// The temp dir is removed when Run returns; any filesystem comparison
// (fs-delta) is computed inside Run before then, so callers must not rely
// on WorkDir's contents after Run returns.
func Run(bin string, s Scenario, repoRoot string) (Result, error) {
	tmp, err := os.MkdirTemp("", "pkfconf-"+s.ID+"-")
	if err != nil {
		return Result{}, err
	}
	defer os.RemoveAll(tmp)
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

	before, err := SnapshotTree(work)
	if err != nil {
		return Result{}, err
	}

	// PKF_CONFORMANCE_SUBDIR allows a scenario to run pkf from a subdirectory
	// of the fixture root, exercising upward Taskfile discovery.
	runDir := work
	if sub, ok := s.Env["PKF_CONFORMANCE_SUBDIR"]; ok {
		runDir = filepath.Join(work, sub)
	}
	cmd := exec.Command(bin, s.Argv...)
	cmd.Dir = runDir
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

	after, err := SnapshotTree(work)
	if err != nil {
		return Result{}, err
	}
	return Result{
		Stdout:    stdout.Bytes(),
		Stderr:    stderr.Bytes(),
		Exit:      exit,
		WorkDir:   work,
		FSDelta:   DeltaPaths(before, after),
		FSDeleted: DeletedPaths(before, after),
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

// SnapshotTree returns a map of relative path -> sha256 hex for every
// regular file under root. Used to compute fs deltas.
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

// DeletedPaths returns the sorted set of paths present in before but
// absent in after (files removed by the command).
func DeletedPaths(before, after map[string]string) []string {
	var deleted []string
	for p := range before {
		if _, ok := after[p]; !ok {
			deleted = append(deleted, p)
		}
	}
	sort.Strings(deleted)
	return deleted
}

// MarshalDelta renders a delta path list as stable JSON for golden storage.
// A nil delta is normalized to an empty array so a no-change run (nil) and
// an explicit empty delta ([]string{}) compare equal rather than tripping a
// phantom null-vs-[] type mismatch.
func MarshalDelta(paths []string) []byte {
	if paths == nil {
		paths = []string{}
	}
	b, _ := json.Marshal(paths)
	return b
}
