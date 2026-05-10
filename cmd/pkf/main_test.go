package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func requirePkl(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("pkl"); err != nil {
		t.Skip("pkl CLI not on PATH; skipping integration test")
	}
}

func basicTaskfile(t *testing.T) string {
	t.Helper()
	abs, err := filepath.Abs("../../examples/basic/Taskfile.pkl")
	if err != nil {
		t.Fatal(err)
	}
	return abs
}

func TestInitWritesSkeleton(t *testing.T) {
	target := filepath.Join(t.TempDir(), "Taskfile.pkl")
	var stdout, stderr bytes.Buffer
	if err := cmdInit([]string{"-f", target}, &stdout, &stderr); err != nil {
		t.Fatalf("cmdInit: %v", err)
	}
	body, err := os.ReadFile(target)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if !strings.Contains(string(body), `amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@`) {
		t.Errorf("skeleton missing package amends line:\n%s", body)
	}
	if !strings.Contains(string(body), `tasks {`) {
		t.Errorf("skeleton missing tasks block:\n%s", body)
	}
}

func TestInitRefusesExistingFileWithoutForce(t *testing.T) {
	target := filepath.Join(t.TempDir(), "Taskfile.pkl")
	if err := os.WriteFile(target, []byte("// existing"), 0o644); err != nil {
		t.Fatal(err)
	}
	err := cmdInit([]string{"-f", target}, &bytes.Buffer{}, &bytes.Buffer{})
	if err == nil {
		t.Fatal("expected error for pre-existing file")
	}
	body, _ := os.ReadFile(target)
	if string(body) != "// existing" {
		t.Errorf("file should not have been touched, got %q", body)
	}
}

func TestInitForceOverwrites(t *testing.T) {
	target := filepath.Join(t.TempDir(), "Taskfile.pkl")
	if err := os.WriteFile(target, []byte("// existing"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := cmdInit([]string{"-f", target, "--force"}, &bytes.Buffer{}, &bytes.Buffer{}); err != nil {
		t.Fatalf("cmdInit --force: %v", err)
	}
	body, err := os.ReadFile(target)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if string(body) == "// existing" {
		t.Error("--force should have overwritten the file")
	}
}

func TestListVerboseShowsCmdAndDeps(t *testing.T) {
	requirePkl(t)
	var stdout, stderr bytes.Buffer
	if err := cmdList([]string{"-f", basicTaskfile(t), "-v"}, &stdout, &stderr); err != nil {
		t.Fatalf("cmdList -v: %v", err)
	}
	out := stdout.String()
	if !strings.Contains(out, "cmd:  go build") {
		t.Errorf("verbose output missing build cmd:\n%s", out)
	}
	if !strings.Contains(out, "deps: build") {
		t.Errorf("verbose output missing deps line:\n%s", out)
	}
}

func TestGraphDOT(t *testing.T) {
	requirePkl(t)
	var stdout, stderr bytes.Buffer
	if err := cmdGraph([]string{"-f", basicTaskfile(t)}, &stdout, &stderr); err != nil {
		t.Fatalf("cmdGraph: %v", err)
	}
	out := stdout.String()
	if !strings.Contains(out, "digraph pkfire {") {
		t.Errorf("DOT output missing header:\n%s", out)
	}
	if !strings.Contains(out, `"build" -> "test"`) {
		t.Errorf("DOT output missing build->test edge:\n%s", out)
	}
}

func TestGraphMermaid(t *testing.T) {
	requirePkl(t)
	var stdout, stderr bytes.Buffer
	err := cmdGraph([]string{"-f", basicTaskfile(t), "--format", "mermaid"}, &stdout, &stderr)
	if err != nil {
		t.Fatalf("cmdGraph mermaid: %v", err)
	}
	out := stdout.String()
	if !strings.Contains(out, "flowchart LR") {
		t.Errorf("mermaid output missing header:\n%s", out)
	}
	if !strings.Contains(out, "build --> test") {
		t.Errorf("mermaid output missing build->test edge:\n%s", out)
	}
}

func TestGraphTargetSubgraph(t *testing.T) {
	requirePkl(t)
	var stdout, stderr bytes.Buffer
	err := cmdGraph([]string{"-f", basicTaskfile(t), "--target", "build"}, &stdout, &stderr)
	if err != nil {
		t.Fatalf("cmdGraph --target build: %v", err)
	}
	out := stdout.String()
	if strings.Contains(out, `"test"`) {
		t.Errorf("--target build should exclude `test` node:\n%s", out)
	}
	if !strings.Contains(out, `"build"`) {
		t.Errorf("--target build should include `build` node:\n%s", out)
	}
}

func TestWalkUpFindsAncestorTaskfile(t *testing.T) {
	repo := t.TempDir()
	root := filepath.Join(repo, "Taskfile.pkl")
	if err := os.WriteFile(root, []byte("// stub"), 0o644); err != nil {
		t.Fatal(err)
	}
	nested := filepath.Join(repo, "services/api/internal")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}

	got := walkUp(nested, "Taskfile.pkl")
	gotResolved, _ := filepath.EvalSymlinks(got)
	wantResolved, _ := filepath.EvalSymlinks(root)
	if gotResolved != wantResolved {
		t.Errorf("walkUp = %q, want %q", got, root)
	}
}

func TestWalkUpFallsBackWhenMissing(t *testing.T) {
	dir := t.TempDir()
	got := walkUp(dir, "Taskfile.pkl")
	want := filepath.Join(dir, "Taskfile.pkl")
	if got != want {
		t.Errorf("walkUp = %q, want %q (fallback path under start)", got, want)
	}
}

func TestRunDryRunPrintsPlanWithoutExecuting(t *testing.T) {
	requirePkl(t)
	var stdout, stderr bytes.Buffer
	if err := cmdRun([]string{"-f", basicTaskfile(t), "--dry-run", "test"}, &stdout, &stderr); err != nil {
		t.Fatalf("cmdRun --dry-run: %v", err)
	}
	out := stdout.String()
	for _, want := range []string{"1. build", "2. test", "cmd:  go build", "cmd:  go test"} {
		if !strings.Contains(out, want) {
			t.Errorf("dry-run output missing %q:\n%s", want, out)
		}
	}
}
