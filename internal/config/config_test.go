package config_test

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/mizchi/pkfire/internal/config"
)

// requirePkl skips the test when the `pkl` CLI is not on PATH; pkl-go
// uses it transparently for evaluation.
func requirePkl(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("pkl"); err != nil {
		t.Skip("pkl CLI not on PATH; skipping integration test")
	}
}

func TestLoadBasicExample(t *testing.T) {
	requirePkl(t)
	path, err := filepath.Abs("../../examples/basic/Taskfile.pkl")
	if err != nil {
		t.Fatalf("abs: %v", err)
	}
	tf, err := config.Load(context.Background(), path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := len(tf.Tasks); got != 3 {
		t.Fatalf("expected 3 tasks, got %d", got)
	}
	build, ok := tf.Tasks["build"]
	if !ok {
		t.Fatal("missing task: build")
	}
	if build.Cmd != "go build -o bin/app ./cmd/app" {
		t.Errorf("build.Cmd = %q", build.Cmd)
	}
	if !build.Cache {
		t.Error("build.Cache default should be true")
	}
	test := tf.Tasks["test"]
	if len(test.Deps) != 1 || test.Deps[0] != "build" {
		t.Errorf("test.Deps = %v", test.Deps)
	}
	if tf.Defaults.Shell != "bash" {
		t.Errorf("defaults.Shell = %q", tf.Defaults.Shell)
	}
}

func TestLoadPreservesTaskOrderAndVisibility(t *testing.T) {
	requirePkl(t)
	repoRoot, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	taskfile := filepath.Join(dir, "Taskfile.pkl")
	body := `amends "` + filepath.ToSlash(filepath.Join(repoRoot, "pkl/Taskfile.pkl")) + `"

local z = new Task { name = "z"; cmd = "echo z"; visibility = "internal" }
local a = new Task { name = "a"; cmd = "echo a" }
tasks { z; a }
`
	if err := os.WriteFile(taskfile, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	tf, err := config.Load(context.Background(), taskfile)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(tf.TaskOrder) != 2 || tf.TaskOrder[0] != "z" || tf.TaskOrder[1] != "a" {
		t.Fatalf("TaskOrder = %v, want [z a]", tf.TaskOrder)
	}
	if got := tf.Tasks["z"].Visibility; got != "internal" {
		t.Fatalf("z.Visibility = %q, want internal", got)
	}
	if got := tf.Tasks["a"].Visibility; got != "public" {
		t.Fatalf("a.Visibility = %q, want public", got)
	}
}
