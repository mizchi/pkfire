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

func TestRunWithIOUsesShellFlags(t *testing.T) {
	var stdout, stderr bytes.Buffer
	r := runner.New(runner.Options{Stdout: &stdout, Stderr: &stderr})
	err := r.RunWithIO(context.Background(), "strict", &config.Task{
		Cmd:        "false | true",
		Shell:      "bash",
		ShellFlags: []string{"-eu", "-o", "pipefail", "-c"},
	}, nil, nil, &stdout, &stderr)
	if err == nil {
		t.Fatal("expected bash pipefail shellFlags to fail the pipeline")
	}
}

func TestRunWithIOOmittedCmdIsNoop(t *testing.T) {
	var stdout, stderr bytes.Buffer
	r := runner.New(runner.Options{Stdout: &stdout, Stderr: &stderr})
	err := r.RunWithIO(context.Background(), "umbrella", &config.Task{
		Cmd:   "",
		Shell: "definitely-not-a-real-shell",
	}, nil, nil, &stdout, &stderr)
	if err != nil {
		t.Fatalf("omitted cmd should be a no-op: %v", err)
	}
	if stdout.String() != "" || stderr.String() != "" {
		t.Fatalf("noop task should not emit output, stdout=%q stderr=%q", stdout.String(), stderr.String())
	}
}

func TestRunInjectsPkfEnvVars(t *testing.T) {
	var stdout, stderr bytes.Buffer
	r := runner.New(runner.Options{Stdout: &stdout, Stderr: &stderr, Workdir: "/tmp"})
	err := r.Run(context.Background(), "show-me", &config.Task{
		Cmd:   `printf "%s|%s|%s" "$PKF_TASK_NAME" "$PKF_TASK_ROOT" "$PKF_WORKSPACE_ROOT"`,
		Shell: "bash",
	}, nil)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	got := stdout.String()
	if !strings.HasPrefix(got, "show-me|") {
		t.Errorf("PKF_TASK_NAME not injected: got %q", got)
	}
	if !strings.Contains(got, "|/tmp|") || !strings.HasSuffix(got, "|/tmp") {
		t.Errorf("PKF_TASK_ROOT / PKF_WORKSPACE_ROOT not set to expected /tmp: got %q", got)
	}
}

func TestRunWithIOTaskQuietSuppressesHeader(t *testing.T) {
	var stdout, stderr bytes.Buffer
	r := runner.New(runner.Options{Stdout: &stdout, Stderr: &stderr})
	err := r.RunWithIO(context.Background(), "wrapper", &config.Task{
		Cmd:   "echo payload",
		Shell: "bash",
		Quiet: true,
	}, nil, nil, &stdout, &stderr)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if got := strings.TrimSpace(stdout.String()); got != "payload" {
		t.Fatalf("stdout = %q, want payload", got)
	}
	if strings.Contains(stderr.String(), "[pkf] wrapper:") {
		t.Fatalf("quiet task should suppress runner header, stderr=%q", stderr.String())
	}
}

func TestRunInheritsHostEnvByDefault(t *testing.T) {
	t.Setenv("PKFIRE_TEST_INHERIT", "yes")
	var stdout, stderr bytes.Buffer
	r := runner.New(runner.Options{Stdout: &stdout, Stderr: &stderr})
	err := r.Run(context.Background(), "show", &config.Task{
		Cmd:        `printf "%s" "$PKFIRE_TEST_INHERIT"`,
		Shell:      "bash",
		InheritEnv: true,
	}, nil)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if got := stdout.String(); got != "yes" {
		t.Errorf("inherited env not visible: stdout = %q", got)
	}
}

func TestRunHermeticDropsAmbientEnv(t *testing.T) {
	t.Setenv("PKFIRE_TEST_HERMETIC", "leak")
	var stdout, stderr bytes.Buffer
	r := runner.New(runner.Options{Stdout: &stdout, Stderr: &stderr})
	err := r.Run(context.Background(), "show", &config.Task{
		Cmd:        `printf "%s" "$PKFIRE_TEST_HERMETIC"`,
		Shell:      "bash",
		InheritEnv: false,
	}, nil)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if got := stdout.String(); got != "" {
		t.Errorf("hermetic mode leaked ambient env: stdout = %q", got)
	}
}

func TestRunWithIOForwardsTailArgs(t *testing.T) {
	var stdout, stderr bytes.Buffer
	r := runner.New(runner.Options{Stdout: &stdout, Stderr: &stderr})
	err := r.RunWithIO(context.Background(), "run", &config.Task{
		Cmd:         `printf "%s|%s|%s" "$#" "$1" "$2"`,
		Shell:       "bash",
		AcceptsArgs: true,
	}, nil, &runner.Invocation{Args: []string{"alpha", "beta"}}, &stdout, &stderr)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if got := stdout.String(); got != "2|alpha|beta" {
		t.Errorf("tail args not forwarded: stdout = %q", got)
	}
}

func TestRunWithIORejectsArgsWhenNotAccepted(t *testing.T) {
	var stdout, stderr bytes.Buffer
	r := runner.New(runner.Options{Stdout: &stdout, Stderr: &stderr})
	err := r.RunWithIO(context.Background(), "run", &config.Task{
		Cmd:   "true",
		Shell: "bash",
	}, nil, &runner.Invocation{Args: []string{"x"}}, &stdout, &stderr)
	if err == nil {
		t.Fatal("expected error when task does not accept args")
	}
	if !strings.Contains(err.Error(), "does not accept positional args") {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestRunWithIOInjectsParamsAsEnv(t *testing.T) {
	var stdout, stderr bytes.Buffer
	r := runner.New(runner.Options{Stdout: &stdout, Stderr: &stderr})
	err := r.RunWithIO(context.Background(), "run", &config.Task{
		Cmd:   `printf "%s" "$BUMP"`,
		Shell: "bash",
	}, nil, &runner.Invocation{Params: map[string]string{"BUMP": "minor"}}, &stdout, &stderr)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if got := stdout.String(); got != "minor" {
		t.Errorf("param env not visible: stdout = %q", got)
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
