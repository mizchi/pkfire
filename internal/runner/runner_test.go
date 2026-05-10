package runner_test

import (
	"bytes"
	"context"
	"strings"
	"testing"

	"github.com/mizchi/pkfire/internal/config"
	"github.com/mizchi/pkfire/internal/runner"
)

func TestRunSingleTaskCapturesStdout(t *testing.T) {
	var stdout, stderr bytes.Buffer
	r := runner.New(runner.Options{Stdout: &stdout, Stderr: &stderr})

	err := r.Run(context.Background(), "hello", &config.Task{
		Cmd:   "echo hello-pkfire",
		Shell: "bash",
	}, nil)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if got := strings.TrimSpace(stdout.String()); got != "hello-pkfire" {
		t.Errorf("stdout = %q", got)
	}
}

func TestRunPropagatesTaskEnv(t *testing.T) {
	var stdout, stderr bytes.Buffer
	r := runner.New(runner.Options{Stdout: &stdout, Stderr: &stderr})

	err := r.Run(context.Background(), "show", &config.Task{
		Cmd:   `printf "%s" "$GREETING"`,
		Shell: "bash",
		Env:   map[string]string{"GREETING": "ohayou"},
	}, &config.Defaults{Shell: "bash"})
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if got := stdout.String(); got != "ohayou" {
		t.Errorf("stdout = %q, want ohayou", got)
	}
}

func TestRunReportsFailure(t *testing.T) {
	r := runner.New(runner.Options{Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}})
	err := r.Run(context.Background(), "fail", &config.Task{
		Cmd:   "exit 7",
		Shell: "bash",
	}, nil)
	if err == nil {
		t.Fatal("expected error from failing task")
	}
	if !strings.Contains(err.Error(), `task "fail" failed`) {
		t.Errorf("error message = %q", err.Error())
	}
}

func TestRunAllStopsOnFirstError(t *testing.T) {
	var stdout, stderr bytes.Buffer
	r := runner.New(runner.Options{Stdout: &stdout, Stderr: &stderr})
	tasks := map[string]*config.Task{
		"a": {Cmd: "echo a", Shell: "bash"},
		"b": {Cmd: "exit 1", Shell: "bash"},
		"c": {Cmd: "echo c", Shell: "bash"},
	}
	err := r.RunAll(context.Background(), []string{"a", "b", "c"}, tasks, nil)
	if err == nil {
		t.Fatal("expected error")
	}
	if strings.Contains(stdout.String(), "c\n") {
		t.Error("`c` should not have run after `b` failed")
	}
}
