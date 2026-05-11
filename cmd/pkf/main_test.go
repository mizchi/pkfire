package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mizchi/pkfire/internal/config"
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
	hasPackageURI := strings.Contains(string(body), `amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@`)
	hasFallbackURL := strings.Contains(string(body), `amends "https://raw.githubusercontent.com/mizchi/pkfire/main/pkl/Taskfile.pkl"`)
	if !hasPackageURI && !hasFallbackURL {
		t.Errorf("skeleton missing a valid amends line:\n%s", body)
	}
	if !strings.Contains(string(body), `tasks {`) {
		t.Errorf("skeleton missing tasks block:\n%s", body)
	}
}

func TestSchemaAmendsURIVariesWithVersion(t *testing.T) {
	prev := version
	t.Cleanup(func() { version = prev })

	version = "dev"
	if got := schemaAmendsURI(); !strings.HasPrefix(got, "https://raw.githubusercontent.com/") {
		t.Errorf("dev build should fall back to HTTPS, got %q", got)
	}

	version = "0.2.0"
	want := `package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.2.0#/Taskfile.pkl`
	if got := schemaAmendsURI(); got != want {
		t.Errorf("release build should pin to its version: got %q want %q", got, want)
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

func TestSplitRunArgsAcceptsTrailingFlags(t *testing.T) {
	cases := []struct {
		name       string
		args       []string
		wantGlobal []string
		wantTask   string
		wantTail   []string
	}{
		{"task only", []string{"build"}, nil, "build", nil},
		{"global before task", []string{"-f", "x.pkl", "build"}, []string{"-f", "x.pkl"}, "build", nil},
		{"flag after task", []string{"build", "--watch"}, nil, "build", []string{"--watch"}},
		{"param after task", []string{"run", "--bump=patch"}, nil, "run", []string{"--bump=patch"}},
		{"tail args", []string{"run", "--", "a", "b"}, nil, "run", []string{"--", "a", "b"}},
		{"j with value before task", []string{"-j", "4", "build"}, []string{"-j", "4"}, "build", nil},
		{"--file=x form", []string{"--file=x.pkl", "build"}, []string{"--file=x.pkl"}, "build", nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			gl, tn, tl, err := splitRunArgs(tc.args)
			if err != nil {
				t.Fatalf("splitRunArgs: %v", err)
			}
			if !equalStrSlice(gl, tc.wantGlobal) {
				t.Errorf("globalArgs = %v, want %v", gl, tc.wantGlobal)
			}
			if tn != tc.wantTask {
				t.Errorf("taskName = %q, want %q", tn, tc.wantTask)
			}
			if !equalStrSlice(tl, tc.wantTail) {
				t.Errorf("taskArgs = %v, want %v", tl, tc.wantTail)
			}
		})
	}
}

func TestSplitRunArgsRequiresTaskName(t *testing.T) {
	if _, _, _, err := splitRunArgs([]string{"--watch"}); err == nil {
		t.Fatal("expected error when no task name is present")
	}
}

func TestResolveInvocationEnumParam(t *testing.T) {
	def := "patch"
	task := &config.Task{
		Params: []*config.Param{
			{Name: "bump", Type: "enum", Choices: []string{"patch", "minor", "major"}, Default: &def},
		},
	}
	inv, err := resolveInvocation(task, "t", []string{"--bump=minor"})
	if err != nil {
		t.Fatalf("resolveInvocation: %v", err)
	}
	if inv == nil || inv.Params["BUMP"] != "minor" {
		t.Fatalf("got %+v, want BUMP=minor", inv)
	}
}

func TestResolveInvocationEnumRejectsBadValue(t *testing.T) {
	task := &config.Task{
		Params: []*config.Param{{Name: "bump", Type: "enum", Choices: []string{"patch"}}},
	}
	if _, err := resolveInvocation(task, "t", []string{"--bump=bogus"}); err == nil {
		t.Fatal("expected enum-validation error")
	}
}

func TestResolveInvocationDefaultsAreApplied(t *testing.T) {
	def := "world"
	task := &config.Task{
		Params: []*config.Param{{Name: "hi", Type: "string", Default: &def}},
	}
	inv, err := resolveInvocation(task, "t", nil)
	if err != nil {
		t.Fatalf("resolveInvocation: %v", err)
	}
	if inv == nil || inv.Params["HI"] != "world" {
		t.Fatalf("default not applied: %+v", inv)
	}
}

func TestResolveInvocationMissingRequiredParam(t *testing.T) {
	task := &config.Task{
		Params: []*config.Param{{Name: "who", Type: "string"}},
	}
	if _, err := resolveInvocation(task, "t", nil); err == nil {
		t.Fatal("expected missing-required error")
	}
}

func TestResolveInvocationRejectsArgsWhenNotAccepted(t *testing.T) {
	task := &config.Task{AcceptsArgs: false}
	if _, err := resolveInvocation(task, "t", []string{"--", "extra"}); err == nil {
		t.Fatal("expected error when acceptsArgs=false")
	}
}

func TestResolveInvocationForwardsTailArgs(t *testing.T) {
	task := &config.Task{AcceptsArgs: true}
	inv, err := resolveInvocation(task, "t", []string{"--", "a", "b"})
	if err != nil {
		t.Fatalf("resolveInvocation: %v", err)
	}
	if inv == nil || len(inv.Args) != 2 || inv.Args[0] != "a" || inv.Args[1] != "b" {
		t.Fatalf("tail args not preserved: %+v", inv)
	}
}

func TestResolveInvocationIntParamValid(t *testing.T) {
	task := &config.Task{
		Params: []*config.Param{{Name: "count", Type: "int"}},
	}
	inv, err := resolveInvocation(task, "t", []string{"--count=42"})
	if err != nil {
		t.Fatalf("resolveInvocation: %v", err)
	}
	if inv == nil || inv.Params["COUNT"] != "42" {
		t.Fatalf("got %+v, want COUNT=42", inv)
	}
}

func TestResolveInvocationIntRejectsNonNumeric(t *testing.T) {
	task := &config.Task{
		Params: []*config.Param{{Name: "count", Type: "int"}},
	}
	if _, err := resolveInvocation(task, "t", []string{"--count=abc"}); err == nil {
		t.Fatal("expected int-validation error")
	}
}

func TestResolveInvocationIntAcceptsNegative(t *testing.T) {
	task := &config.Task{
		Params: []*config.Param{{Name: "off", Type: "int"}},
	}
	inv, err := resolveInvocation(task, "t", []string{"--off=-7"})
	if err != nil {
		t.Fatalf("resolveInvocation: %v", err)
	}
	if inv.Params["OFF"] != "-7" {
		t.Fatalf("got %+v, want OFF=-7", inv)
	}
}

func TestResolveInvocationBoolLoneFlagIsTrue(t *testing.T) {
	task := &config.Task{
		Params: []*config.Param{{Name: "watch", Type: "bool"}},
	}
	inv, err := resolveInvocation(task, "t", []string{"--watch"})
	if err != nil {
		t.Fatalf("resolveInvocation: %v", err)
	}
	if inv == nil || inv.Params["WATCH"] != "true" {
		t.Fatalf("got %+v, want WATCH=true", inv)
	}
}

func TestResolveInvocationBoolExplicitFalse(t *testing.T) {
	task := &config.Task{
		Params: []*config.Param{{Name: "watch", Type: "bool"}},
	}
	inv, err := resolveInvocation(task, "t", []string{"--watch=false"})
	if err != nil {
		t.Fatalf("resolveInvocation: %v", err)
	}
	if inv.Params["WATCH"] != "false" {
		t.Fatalf("got %+v, want WATCH=false", inv)
	}
}

func TestResolveInvocationBoolRejectsBadValue(t *testing.T) {
	task := &config.Task{
		Params: []*config.Param{{Name: "watch", Type: "bool"}},
	}
	if _, err := resolveInvocation(task, "t", []string{"--watch=yes"}); err == nil {
		t.Fatal("expected bool-validation error")
	}
}

func TestResolveInvocationBoolDoesNotConsumeNextToken(t *testing.T) {
	def := "world"
	task := &config.Task{
		Params: []*config.Param{
			{Name: "watch", Type: "bool"},
			{Name: "hi", Type: "string", Default: &def},
		},
	}
	// `--watch --hi=foo`: --watch is value-less, --hi takes "foo".
	inv, err := resolveInvocation(task, "t", []string{"--watch", "--hi=foo"})
	if err != nil {
		t.Fatalf("resolveInvocation: %v", err)
	}
	if inv.Params["WATCH"] != "true" || inv.Params["HI"] != "foo" {
		t.Fatalf("got %+v, want WATCH=true HI=foo", inv)
	}
}

func TestResolveInvocationValidatesIntDefault(t *testing.T) {
	bad := "abc"
	task := &config.Task{
		Params: []*config.Param{{Name: "count", Type: "int", Default: &bad}},
	}
	if _, err := resolveInvocation(task, "t", nil); err == nil {
		t.Fatal("expected error when int default fails to parse")
	}
}

func TestResolveInvocationReturnsNilWhenNoOverlay(t *testing.T) {
	task := &config.Task{}
	inv, err := resolveInvocation(task, "t", nil)
	if err != nil {
		t.Fatalf("resolveInvocation: %v", err)
	}
	if inv != nil {
		t.Fatalf("expected nil invocation for empty task+args, got %+v", inv)
	}
}

func equalStrSlice(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestListJSONEmitsStructuredOutput(t *testing.T) {
	requirePkl(t)
	var stdout, stderr bytes.Buffer
	if err := cmdList([]string{"-f", basicTaskfile(t), "--json"}, &stdout, &stderr); err != nil {
		t.Fatalf("cmdList --json: %v", err)
	}
	var got listJSON
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("output is not valid JSON: %v\n%s", err, stdout.String())
	}
	if len(got.Tasks) == 0 {
		t.Fatal("expected at least one task in output")
	}
	names := map[string]bool{}
	for _, e := range got.Tasks {
		names[e.Name] = true
	}
	for _, want := range []string{"build", "test"} {
		if !names[want] {
			t.Errorf("expected task %q in json output, got %+v", want, names)
		}
	}
}

func TestListJSONAndVerboseAreMutuallyExclusive(t *testing.T) {
	requirePkl(t)
	var stdout, stderr bytes.Buffer
	err := cmdList([]string{"-f", basicTaskfile(t), "--json", "-v"}, &stdout, &stderr)
	if err == nil || !strings.Contains(err.Error(), "subsumes") {
		t.Fatalf("expected --json + -v to error, got %v", err)
	}
}

func TestDoctorReportsTaskfileMetadata(t *testing.T) {
	requirePkl(t)
	var stdout, stderr bytes.Buffer
	if err := cmdDoctor([]string{"-f", basicTaskfile(t)}, &stdout, &stderr); err != nil {
		// doctor may exit non-zero if remote cache is misconfigured or pkl is missing,
		// but for the basic Taskfile + pkl-on-PATH case it should succeed.
		t.Fatalf("cmdDoctor: %v\n%s", err, stdout.String())
	}
	out := stdout.String()
	for _, want := range []string{"pkf doctor", "pkl", "cache", "taskfile"} {
		if !strings.Contains(out, want) {
			t.Errorf("doctor output missing %q:\n%s", want, out)
		}
	}
}

func TestFormatCheckMode(t *testing.T) {
	requirePkl(t)
	// A well-formed Pkl file produced by `pkf format` itself: format
	// --check on the in-tree schema dir should exit zero because we
	// keep pkl/ formatted at HEAD.
	var stdout, stderr bytes.Buffer
	repoRoot, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	pklDir := filepath.Join(repoRoot, "pkl")
	if err := cmdFormat([]string{"--check", pklDir}, &stdout, &stderr); err != nil {
		t.Fatalf("expected pkl/ to be clean, got %v\nstdout: %s\nstderr: %s",
			err, stdout.String(), stderr.String())
	}
}

func TestFormatDetectsViolation(t *testing.T) {
	requirePkl(t)
	// Write a deliberately mis-indented Pkl file and expect format --check
	// to flag it. Using a temp dir keeps the in-tree files clean.
	dir := t.TempDir()
	bad := filepath.Join(dir, "bad.pkl")
	if err := os.WriteFile(bad, []byte("foo =     1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	err := cmdFormat([]string{"--check", dir}, &stdout, &stderr)
	if err == nil {
		t.Fatalf("expected format --check to flag bad.pkl, got nil")
	}
	if !strings.Contains(err.Error(), "exited 11") {
		t.Errorf("expected exit-code-11 error, got: %v", err)
	}
}

func TestRunRefreshAndNoCacheAreMutuallyExclusive(t *testing.T) {
	requirePkl(t)
	var stdout, stderr bytes.Buffer
	err := cmdRun([]string{"-f", basicTaskfile(t), "--no-cache", "--refresh", "test"}, &stdout, &stderr)
	if err == nil || !strings.Contains(err.Error(), "mutually exclusive") {
		t.Fatalf("expected --no-cache + --refresh to error, got %v", err)
	}
}

func TestHooksInstallWritesShim(t *testing.T) {
	requirePkl(t)
	repo := newTempRepo(t)
	taskfile := filepath.Join(repo, "Taskfile.pkl")
	if err := os.WriteFile(taskfile, []byte(`amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.4.0#/Taskfile.pkl"

local pre = new Task {
  name = "pre-commit"
  cmd  = "echo ok"
  cache = false
}

tasks { pre }
`), 0o644); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	if err := cmdHooks([]string{"install", "-f", taskfile}, &stdout, &stderr); err != nil {
		t.Fatalf("hooks install: %v\n%s\n%s", err, stdout.String(), stderr.String())
	}
	hook := filepath.Join(repo, ".git", "hooks", "pre-commit")
	data, err := os.ReadFile(hook)
	if err != nil {
		t.Fatalf("hook not written: %v", err)
	}
	if !strings.Contains(string(data), "pkf run pre-commit") {
		t.Errorf("shim missing pkf run line:\n%s", data)
	}
	info, _ := os.Stat(hook)
	if info.Mode()&0o100 == 0 {
		t.Errorf("hook not executable: %v", info.Mode())
	}
}

func TestHooksInstallIsSilentOnNoop(t *testing.T) {
	requirePkl(t)
	repo := newTempRepo(t)
	taskfile := filepath.Join(repo, "Taskfile.pkl")
	if err := os.WriteFile(taskfile, []byte(`amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.4.0#/Taskfile.pkl"

local pre = new Task { name = "pre-commit"; cmd = "echo ok"; cache = false }
tasks { pre }
`), 0o644); err != nil {
		t.Fatal(err)
	}

	// First install: should write the shim and report.
	var out1, err1 bytes.Buffer
	if err := cmdHooks([]string{"install", "-f", taskfile}, &out1, &err1); err != nil {
		t.Fatalf("first install: %v", err)
	}
	if !strings.Contains(out1.String(), "installed") {
		t.Errorf("first install should log `installed`, got %q", out1.String())
	}

	// Second install with no change: must be completely silent so
	// `.envrc` / direnv-reload-on-cd doesn't spam the terminal.
	var out2, err2 bytes.Buffer
	if err := cmdHooks([]string{"install", "-f", taskfile}, &out2, &err2); err != nil {
		t.Fatalf("second install: %v", err)
	}
	if out2.Len() != 0 || err2.Len() != 0 {
		t.Errorf("idempotent reinstall must be silent.\nstdout=%q\nstderr=%q",
			out2.String(), err2.String())
	}
}

func TestHooksInstallPreservesUnmanagedHook(t *testing.T) {
	requirePkl(t)
	repo := newTempRepo(t)
	taskfile := filepath.Join(repo, "Taskfile.pkl")
	if err := os.WriteFile(taskfile, []byte(`amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.4.0#/Taskfile.pkl"

local pre = new Task { name = "pre-commit"; cmd = "echo ok"; cache = false }
tasks { pre }
`), 0o644); err != nil {
		t.Fatal(err)
	}
	hookDir := filepath.Join(repo, ".git", "hooks")
	if err := os.MkdirAll(hookDir, 0o755); err != nil {
		t.Fatal(err)
	}
	existing := filepath.Join(hookDir, "pre-commit")
	if err := os.WriteFile(existing, []byte("#!/bin/sh\necho user wrote this\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	if err := cmdHooks([]string{"install", "-f", taskfile}, &stdout, &stderr); err != nil {
		t.Fatalf("hooks install: %v", err)
	}
	got, _ := os.ReadFile(existing)
	if strings.Contains(string(got), "managed by pkf") {
		t.Errorf("install overwrote unmanaged hook without --force:\n%s", got)
	}
	if !strings.Contains(stderr.String(), "not managed by pkfire") {
		t.Errorf("expected stderr warning, got: %s", stderr.String())
	}
}

func TestHooksUninstallSkipsUnmanaged(t *testing.T) {
	requirePkl(t)
	repo := newTempRepo(t)
	taskfile := filepath.Join(repo, "Taskfile.pkl")
	if err := os.WriteFile(taskfile, []byte(`amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.4.0#/Taskfile.pkl"

local pre = new Task { name = "pre-commit"; cmd = "echo ok"; cache = false }
tasks { pre }
`), 0o644); err != nil {
		t.Fatal(err)
	}
	hookDir := filepath.Join(repo, ".git", "hooks")
	if err := os.MkdirAll(hookDir, 0o755); err != nil {
		t.Fatal(err)
	}
	existing := filepath.Join(hookDir, "pre-commit")
	if err := os.WriteFile(existing, []byte("#!/bin/sh\necho user wrote this\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	if err := cmdHooks([]string{"uninstall", "-f", taskfile}, &stdout, &stderr); err != nil {
		t.Fatalf("hooks uninstall: %v", err)
	}
	if _, err := os.Stat(existing); err != nil {
		t.Errorf("uninstall removed an unmanaged hook")
	}
}

func newTempRepo(t *testing.T) string {
	t.Helper()
	repo := t.TempDir()
	// Materialize a minimal .git directory so gitHooksDir's walk-up
	// recognizes the temp dir as a repository root. We don't actually
	// run git commands against it; the hooks code only stats .git/.
	if err := os.MkdirAll(filepath.Join(repo, ".git", "hooks"), 0o755); err != nil {
		t.Fatal(err)
	}
	return repo
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
