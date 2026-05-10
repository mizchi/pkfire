package orchestrator_test

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/mizchi/pkfire/internal/cache"
	"github.com/mizchi/pkfire/internal/config"
	"github.com/mizchi/pkfire/internal/orchestrator"
	"github.com/mizchi/pkfire/internal/runner"
)

func newOrch(t *testing.T) (*orchestrator.Orchestrator, string, *bytes.Buffer, *bytes.Buffer) {
	t.Helper()
	root := t.TempDir()
	cas := t.TempDir()
	var stdout, stderr bytes.Buffer
	r := runner.New(runner.Options{Workdir: root})
	o := orchestrator.New(cache.New(cas), r, &stdout, &stderr, orchestrator.Options{Parallelism: 1})
	return o, root, &stdout, &stderr
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
	o, root, _, stderr := newOrch(t)

	first := basePlan(root, "build", &config.Task{
		Cmd:     "mkdir -p bin && printf BIN > bin/app",
		Shell:   "bash",
		Outputs: []string{"bin"},
		Cache:   true,
	})
	if _, err := o.Execute(context.Background(), first); err != nil {
		t.Fatalf("first Execute: %v", err)
	}
	if !strings.Contains(stderr.String(), "ran ") {
		t.Errorf("expected first run to log `ran`, got %q", stderr.String())
	}

	if err := os.RemoveAll(filepath.Join(root, "bin")); err != nil {
		t.Fatal(err)
	}
	stderr.Reset()

	second := basePlan(root, "build", &config.Task{
		Cmd:     "echo SHOULD-NOT-RUN",
		Shell:   "bash",
		Outputs: []string{"bin"},
		Cache:   true,
	})
	results, err := o.Execute(context.Background(), second)
	if err != nil {
		t.Fatalf("second Execute: %v", err)
	}
	if results[0].Outcome != orchestrator.OutcomeRan {
		t.Errorf("changing cmd should miss cache, got %v", results[0].Outcome)
	}

	if err := os.RemoveAll(filepath.Join(root, "bin")); err != nil {
		t.Fatal(err)
	}
	stderr.Reset()
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
	o, root, _, stderr := newOrch(t)
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
	if !strings.Contains(stderr.String(), "ran (uncached)") {
		t.Errorf("stderr = %q", stderr.String())
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

func TestExecuteRespectsDependencyOrderInParallel(t *testing.T) {
	root := t.TempDir()
	cas := t.TempDir()
	var stdout, stderr bytes.Buffer
	r := runner.New(runner.Options{Workdir: root})
	o := orchestrator.New(cache.New(cas), r, &stdout, &stderr, orchestrator.Options{Parallelism: 4})

	// `build` writes a marker file; `test` asserts it exists. With proper dep
	// ordering this passes; without it `test` would race ahead and fail.
	plan := &orchestrator.Plan{
		Order: []string{"build", "test"},
		Tasks: map[string]*config.Task{
			"build": {
				Cmd:     "sleep 0.05 && printf BIN > bin",
				Shell:   "bash",
				Outputs: []string{"bin"},
				Cache:   true,
			},
			"test": {
				Cmd:   "test -f bin && cat bin",
				Shell: "bash",
				Deps:  []string{"build"},
				Cache: false,
			},
		},
		Defaults:   &config.Defaults{Shell: "bash"},
		Root:       root,
		ConfigHash: []byte("c"),
	}
	results, err := o.Execute(context.Background(), plan)
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if got := strings.TrimSpace(stdout.String()); got != "BIN" {
		t.Errorf("stdout = %q, want BIN", got)
	}
	if results[0].Name != "build" || results[1].Name != "test" {
		t.Errorf("results out of order: %+v", results)
	}
}

func TestExecuteRunsIndependentTasksConcurrently(t *testing.T) {
	root := t.TempDir()
	cas := t.TempDir()
	var stdout, stderr bytes.Buffer
	r := runner.New(runner.Options{Workdir: root})
	o := orchestrator.New(cache.New(cas), r, &stdout, &stderr, orchestrator.Options{Parallelism: 4})

	const slowMs = 200
	mkSlow := func() *config.Task {
		return &config.Task{
			Cmd:   "sleep 0.2",
			Shell: "bash",
			Cache: false,
		}
	}
	plan := &orchestrator.Plan{
		Order: []string{"a", "b", "c", "d"},
		Tasks: map[string]*config.Task{
			"a": mkSlow(), "b": mkSlow(), "c": mkSlow(), "d": mkSlow(),
		},
		Defaults: &config.Defaults{Shell: "bash"},
		Root:     root,
	}
	start := time.Now()
	if _, err := o.Execute(context.Background(), plan); err != nil {
		t.Fatalf("Execute: %v", err)
	}
	elapsed := time.Since(start)
	// Serial would be ~800ms; we tolerate up to ~600ms to account for CI.
	if elapsed > time.Duration(slowMs*3)*time.Millisecond {
		t.Errorf("4 independent 200ms tasks took %v with parallelism=4 (expected ≪ serial)", elapsed)
	}
}

func TestExecuteSkipsDownstreamWhenDepFails(t *testing.T) {
	root := t.TempDir()
	cas := t.TempDir()
	var stdout, stderr bytes.Buffer
	r := runner.New(runner.Options{Workdir: root})
	o := orchestrator.New(cache.New(cas), r, &stdout, &stderr, orchestrator.Options{Parallelism: 4})

	plan := &orchestrator.Plan{
		Order: []string{"setup", "step", "after"},
		Tasks: map[string]*config.Task{
			"setup": {Cmd: "exit 1", Shell: "bash", Cache: false},
			"step":  {Cmd: "echo step-ran", Shell: "bash", Deps: []string{"setup"}, Cache: false},
			"after": {Cmd: "echo after-ran", Shell: "bash", Deps: []string{"step"}, Cache: false},
		},
		Defaults: &config.Defaults{Shell: "bash"},
		Root:     root,
	}
	_, err := o.Execute(context.Background(), plan)
	if err == nil {
		t.Fatal("expected error from failing setup")
	}
	if strings.Contains(stdout.String(), "step-ran") || strings.Contains(stdout.String(), "after-ran") {
		t.Errorf("downstream tasks should not have produced output, stdout=%q", stdout.String())
	}
}
