package orchestrator_test

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mizchi/pkfire/internal/cache"
	"github.com/mizchi/pkfire/internal/config"
	"github.com/mizchi/pkfire/internal/orchestrator"
	"github.com/mizchi/pkfire/internal/runner"
)

func newOrch(t *testing.T) (*orchestrator.Orchestrator, string, *bytes.Buffer) {
	t.Helper()
	root := t.TempDir()
	cas := t.TempDir()
	var stdout, stderr, log bytes.Buffer
	r := runner.New(runner.Options{Stdout: &stdout, Stderr: &stderr, Workdir: root})
	o := orchestrator.New(cache.New(cas), r, &log)
	return o, root, &log
}

func basePlan(root, name string, t *config.Task) *orchestrator.Plan {
	return &orchestrator.Plan{
		Order:      []string{name},
		Tasks:      map[string]*config.Task{name: t},
		Defaults:   &config.Defaults{Shell: "bash"},
		Root:       root,
		ConfigHash: []byte("config-v1"),
	}
}

func TestExecuteCachesOutput(t *testing.T) {
	o, root, log := newOrch(t)

	first := basePlan(root, "build", &config.Task{
		Cmd:     "mkdir -p bin && printf BIN > bin/app",
		Shell:   "bash",
		Outputs: []string{"bin"},
		Cache:   true,
	})
	if _, err := o.Execute(context.Background(), first); err != nil {
		t.Fatalf("first Execute: %v", err)
	}
	if !strings.Contains(log.String(), "ran ") {
		t.Errorf("expected first run to log `ran`, got %q", log.String())
	}

	// Wipe outputs to ensure restore actually replaces them.
	if err := os.RemoveAll(filepath.Join(root, "bin")); err != nil {
		t.Fatal(err)
	}

	log.Reset()
	second := basePlan(root, "build", &config.Task{
		Cmd:     "echo SHOULD-NOT-RUN",
		Shell:   "bash",
		Outputs: []string{"bin"},
		Cache:   true,
	})
	// Note: Cmd differs but Outputs is the same. Cache key includes Cmd, so
	// this must be a *miss* — verify by checking content is "echo SHOULD-NOT-RUN" output.
	results, err := o.Execute(context.Background(), second)
	if err != nil {
		t.Fatalf("second Execute: %v", err)
	}
	if results[0].Outcome != orchestrator.OutcomeRan {
		t.Errorf("changing cmd should miss cache, got %v", results[0].Outcome)
	}

	// Now run an identical plan again — that should hit.
	log.Reset()
	if err := os.RemoveAll(filepath.Join(root, "bin")); err != nil {
		t.Fatal(err)
	}
	third := basePlan(root, "build", &config.Task{
		Cmd:     "mkdir -p bin && printf BIN > bin/app",
		Shell:   "bash",
		Outputs: []string{"bin"},
		Cache:   true,
	})
	results, err = o.Execute(context.Background(), third)
	if err != nil {
		t.Fatalf("third Execute: %v", err)
	}
	if results[0].Outcome != orchestrator.OutcomeHit {
		t.Errorf("identical plan should hit cache, got %v", results[0].Outcome)
	}
	got, err := os.ReadFile(filepath.Join(root, "bin/app"))
	if err != nil {
		t.Fatalf("restored file missing: %v", err)
	}
	if string(got) != "BIN" {
		t.Errorf("restored content = %q", got)
	}
}

func TestExecuteSkipsCacheWhenDisabled(t *testing.T) {
	o, root, log := newOrch(t)
	plan := basePlan(root, "phony", &config.Task{
		Cmd:   "true",
		Shell: "bash",
		Cache: false,
	})
	results, err := o.Execute(context.Background(), plan)
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if results[0].Outcome != orchestrator.OutcomeUncached {
		t.Errorf("expected OutcomeUncached, got %v", results[0].Outcome)
	}
	if !strings.Contains(log.String(), "ran (uncached)") {
		t.Errorf("log = %q", log.String())
	}
}

func TestComputeKeyIsStableAcrossCalls(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "src.go"), []byte("package x"), 0o644); err != nil {
		t.Fatal(err)
	}
	task := &config.Task{
		Cmd:    "go build",
		Shell:  "bash",
		Inputs: []string{"src.go"},
		Env:    map[string]string{"A": "1"},
	}
	defaults := &config.Defaults{Shell: "bash"}
	a, err := orchestrator.ComputeKey(task, defaults, root, []byte("c"))
	if err != nil {
		t.Fatalf("ComputeKey: %v", err)
	}
	b, err := orchestrator.ComputeKey(task, defaults, root, []byte("c"))
	if err != nil {
		t.Fatalf("ComputeKey: %v", err)
	}
	if a != b {
		t.Fatal("ComputeKey not stable across calls")
	}
}
