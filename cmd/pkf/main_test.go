package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/mizchi/pkfire/internal/config"
	"github.com/mizchi/pkfire/internal/graph"
	"github.com/mizchi/pkfire/internal/orchestrator"
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
		wantTasks  []string
		wantTail   []string
	}{
		{"task only", []string{"build"}, nil, []string{"build"}, nil},
		{"global before task", []string{"-f", "x.pkl", "build"}, []string{"-f", "x.pkl"}, []string{"build"}, nil},
		{"flag after task", []string{"build", "--watch"}, nil, []string{"build"}, []string{"--watch"}},
		{"param after task", []string{"run", "--bump=patch"}, nil, []string{"run"}, []string{"--bump=patch"}},
		{"tail args", []string{"run", "--", "a", "b"}, nil, []string{"run"}, []string{"--", "a", "b"}},
		{"j with value before task", []string{"-j", "4", "build"}, []string{"-j", "4"}, []string{"build"}, nil},
		{"--file=x form", []string{"--file=x.pkl", "build"}, []string{"--file=x.pkl"}, []string{"build"}, nil},
		{"multi target", []string{"a", "b", "c"}, nil, []string{"a", "b", "c"}, nil},
		{"multi target + flag after", []string{"a", "b", "--watch"}, nil, []string{"a", "b"}, []string{"--watch"}},
		{"global + multi target", []string{"-j", "8", "a", "b"}, []string{"-j", "8"}, []string{"a", "b"}, nil},
		{"no task (default fallback hint)", []string{"--watch"}, []string{"--watch"}, nil, nil},
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
			if !equalStrSlice(tn, tc.wantTasks) {
				t.Errorf("taskNames = %v, want %v", tn, tc.wantTasks)
			}
			if !equalStrSlice(tl, tc.wantTail) {
				t.Errorf("taskArgs = %v, want %v", tl, tc.wantTail)
			}
		})
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

func TestProfileChangesActionKey(t *testing.T) {
	requirePkl(t)
	taskfile := taskfileWithTasks(t, `
local probe = new Task { name = "probe"; cmd = "echo p"; cache = true; inputs { "Taskfile.pkl" } }
tasks { probe }
`)
	var devOut, ciOut bytes.Buffer
	if err := cmdRun([]string{"-f", taskfile, "--profile=dev", "--print-hash", "probe"}, &devOut, &bytes.Buffer{}); err != nil {
		t.Fatalf("dev print-hash: %v", err)
	}
	if err := cmdRun([]string{"-f", taskfile, "--profile=ci", "--print-hash", "probe"}, &ciOut, &bytes.Buffer{}); err != nil {
		t.Fatalf("ci print-hash: %v", err)
	}
	if devOut.String() == ciOut.String() {
		t.Errorf("different profiles should yield different action keys:\ndev=%s\nci= %s",
			devOut.String(), ciOut.String())
	}
}

func TestCmdExplainShowsKeyComponents(t *testing.T) {
	requirePkl(t)
	var stdout, stderr bytes.Buffer
	if err := cmdExplain([]string{"-f", basicTaskfile(t), "build"}, &stdout, &stderr); err != nil {
		t.Fatalf("cmdExplain: %v", err)
	}
	out := stdout.String()
	for _, want := range []string{
		"task:        build",
		"action key:",
		"cmd:",
		"go build",
		"shell:",
		"env (",
		"tools (",
		"inputs (",
		"config hash:",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("explain output missing %q:\n%s", want, out)
		}
	}
}

func TestCmdExplainErrorsOnUnknownTask(t *testing.T) {
	requirePkl(t)
	err := cmdExplain([]string{"-f", basicTaskfile(t), "nope"}, &bytes.Buffer{}, &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "unknown task") {
		t.Errorf("expected unknown-task error, got %v", err)
	}
}

func TestRunKeepGoingDoesNotCancelOnFailure(t *testing.T) {
	requirePkl(t)
	taskfile := taskfileWithTasks(t, `
local failing = new Task { name = "failing"; cmd = "exit 1"; cache = false }
local other   = new Task { name = "other";   cmd = "echo ran"; cache = false }
tasks { failing; other }
`)
	// Multi-target so both are roots. Default mode: the first failure
	// cancels everything (`other` may or may not have started — that's
	// the point). --keep-going forces independent subgraphs to
	// completion; we verify `other` ran in its output.
	var stdout, stderr bytes.Buffer
	err := cmdRun([]string{"-f", taskfile, "--keep-going", "failing", "other"}, &stdout, &stderr)
	if err == nil {
		t.Fatal("expected aggregated error from `failing`")
	}
	if !strings.Contains(stderr.String(), "echo ran") && !strings.Contains(stdout.String(), "ran") {
		t.Errorf("--keep-going should have let `other` run.\nstdout: %s\nstderr: %s", stdout.String(), stderr.String())
	}
}

func TestCompletionEmitsBashScript(t *testing.T) {
	var buf bytes.Buffer
	if err := cmdCompletion([]string{"bash"}, &buf, &bytes.Buffer{}); err != nil {
		t.Fatalf("cmdCompletion bash: %v", err)
	}
	out := buf.String()
	for _, want := range []string{"_pkf()", "complete -F _pkf pkf", "pkf list"} {
		if !strings.Contains(out, want) {
			t.Errorf("bash completion missing %q", want)
		}
	}
}

func TestCompletionEmitsZshScript(t *testing.T) {
	var buf bytes.Buffer
	if err := cmdCompletion([]string{"zsh"}, &buf, &bytes.Buffer{}); err != nil {
		t.Fatalf("cmdCompletion zsh: %v", err)
	}
	out := buf.String()
	for _, want := range []string{"#compdef pkf", "_pkf", "_describe"} {
		if !strings.Contains(out, want) {
			t.Errorf("zsh completion missing %q", want)
		}
	}
}

func TestCompletionEmitsFishScript(t *testing.T) {
	var buf bytes.Buffer
	if err := cmdCompletion([]string{"fish"}, &buf, &bytes.Buffer{}); err != nil {
		t.Fatalf("cmdCompletion fish: %v", err)
	}
	out := buf.String()
	for _, want := range []string{"complete -c pkf", "__pkf_tasks", "__fish_use_subcommand"} {
		if !strings.Contains(out, want) {
			t.Errorf("fish completion missing %q", want)
		}
	}
}

func TestCompletionRejectsUnknownShell(t *testing.T) {
	err := cmdCompletion([]string{"powershell"}, &bytes.Buffer{}, &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "unknown shell") {
		t.Errorf("expected unknown-shell error, got %v", err)
	}
}

func TestCompletionRequiresShellArg(t *testing.T) {
	err := cmdCompletion(nil, &bytes.Buffer{}, &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "usage") {
		t.Errorf("expected usage error, got %v", err)
	}
}

func TestRunQuietSuppressesPerTaskLogs(t *testing.T) {
	requirePkl(t)
	taskfile := taskfileWithTasks(t, `
local foo = new Task { name = "foo"; cmd = "echo foo"; cache = false }
tasks { foo }
`)
	var stdout, stderr bytes.Buffer
	if err := cmdRun([]string{"-f", taskfile, "--quiet", "foo"}, &stdout, &stderr); err != nil {
		t.Fatalf("cmdRun: %v", err)
	}
	if strings.Contains(stderr.String(), "[pkf] foo: echo foo") {
		t.Errorf("--quiet should suppress runner cmd-header lines:\n%s", stderr.String())
	}
	if strings.Contains(stderr.String(), "[pkf] foo: ran") {
		t.Errorf("--quiet should suppress orchestrator outcome lines:\n%s", stderr.String())
	}
	if !strings.Contains(stderr.String(), "[pkf] done:") {
		t.Errorf("end-of-run summary should still print:\n%s", stderr.String())
	}
}

func TestExpandPatternsExpandsGlobs(t *testing.T) {
	tasks := map[string]*config.Task{
		"test:unit":        {},
		"test:integration": {},
		"build:linux":      {},
		"build:darwin":     {},
		"lint":             {},
	}
	got := expandPatterns([]string{"test:*"}, tasks)
	if got == nil {
		t.Fatal("expected expansion, got nil")
	}
	want := map[string]bool{"test:unit": true, "test:integration": true}
	if len(got) != len(want) {
		t.Errorf("got %v, want keys %v", got, want)
	}
	for _, n := range got {
		if !want[n] {
			t.Errorf("unexpected name: %s", n)
		}
	}
}

func TestExpandPatternsLeavesExactNames(t *testing.T) {
	tasks := map[string]*config.Task{"build": {}, "test": {}}
	got := expandPatterns([]string{"build", "test"}, tasks)
	if got != nil {
		t.Errorf("expected nil (no patterns), got %v", got)
	}
}

func TestExpandPatternsKeepsLiteralOnNoMatch(t *testing.T) {
	tasks := map[string]*config.Task{"build": {}}
	got := expandPatterns([]string{"nope:*"}, tasks)
	if got == nil {
		t.Fatal("expected expansion result even when no match")
	}
	if len(got) != 1 || got[0] != "nope:*" {
		t.Errorf("expected the literal `nope:*` to fall through, got %v", got)
	}
}

func TestCmdCleanDryRunListsOutputs(t *testing.T) {
	requirePkl(t)
	repo := t.TempDir()
	taskfile := filepath.Join(repo, "Taskfile.pkl")
	binFile := filepath.Join(repo, "bin/app")
	if err := os.MkdirAll(filepath.Dir(binFile), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(binFile, []byte("binary"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(taskfile, []byte(`amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.4.0#/Taskfile.pkl"

local build = new Task { name = "build"; cmd = "echo build"; outputs { "bin/app" }; cache = false }
tasks { build }
`), 0o644); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	if err := cmdClean([]string{"-f", taskfile, "--dry-run"}, &stdout, &stderr); err != nil {
		t.Fatalf("cmdClean: %v\n%s", err, stderr.String())
	}
	if !strings.Contains(stdout.String(), "would remove") {
		t.Errorf("expected `would remove` in output:\n%s", stdout.String())
	}
	if _, err := os.Stat(binFile); err != nil {
		t.Errorf("--dry-run should not have removed bin/app: %v", err)
	}
}

func TestCmdCleanRemovesOutputs(t *testing.T) {
	requirePkl(t)
	repo := t.TempDir()
	taskfile := filepath.Join(repo, "Taskfile.pkl")
	binFile := filepath.Join(repo, "bin/app")
	if err := os.MkdirAll(filepath.Dir(binFile), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(binFile, []byte("binary"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(taskfile, []byte(`amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.4.0#/Taskfile.pkl"

local build = new Task { name = "build"; cmd = "echo build"; outputs { "bin/app" }; cache = false }
tasks { build }
`), 0o644); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	if err := cmdClean([]string{"-f", taskfile}, &stdout, &stderr); err != nil {
		t.Fatalf("cmdClean: %v\n%s", err, stderr.String())
	}
	if _, err := os.Stat(binFile); !os.IsNotExist(err) {
		t.Errorf("bin/app should be gone, got err = %v", err)
	}
}

func TestParseDurationAcceptsDays(t *testing.T) {
	cases := map[string]time.Duration{
		"7d":  7 * 24 * time.Hour,
		"30d": 30 * 24 * time.Hour,
		"24h": 24 * time.Hour,
		"5m":  5 * time.Minute,
	}
	for input, want := range cases {
		got, err := parseDuration(input)
		if err != nil {
			t.Errorf("%s: %v", input, err)
			continue
		}
		if got != want {
			t.Errorf("%s: got %v want %v", input, got, want)
		}
	}
}

func TestCacheStatsHandlesMissingDir(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "nonexistent")
	var buf bytes.Buffer
	if err := cacheStatsCmd(&buf, dir); err != nil {
		t.Fatalf("cacheStatsCmd: %v", err)
	}
	out := buf.String()
	if !strings.Contains(out, "entries:   0") {
		t.Errorf("expected `entries:   0`:\n%s", out)
	}
}

func TestTasksMatchingChangesHonorsWorkdir(t *testing.T) {
	wd := "services/api"
	tf := &config.Taskfile{
		Tasks: map[string]*config.Task{
			"build:api": {Inputs: []string{"src/**/*.ts"}, Workdir: &wd},
			"build:web": {Inputs: []string{"src/**/*.ts"}, Workdir: stringPtr("services/web")},
			"docs":      {Inputs: []string{"docs/**/*.md"}},
			"nothing":   {}, // no inputs declared
		},
	}
	got := tasksMatchingChanges(tf, "/repo", []string{
		"services/api/src/foo.ts",
		"docs/intro.md",
	})
	want := map[string]bool{"build:api": true, "docs": true}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for k := range want {
		if !got[k] {
			t.Errorf("missing %q in result", k)
		}
	}
}

func TestExpandToDependentsClosure(t *testing.T) {
	tf := &config.Taskfile{
		Tasks: map[string]*config.Task{
			"build":     {Deps: []string{"gen"}},
			"gen":       {Deps: []string{}},
			"test":      {Deps: []string{"build"}},
			"unrelated": {Deps: []string{}},
		},
	}
	direct := map[string]bool{"gen": true}
	got := expandToDependents(tf, direct)
	for _, want := range []string{"gen", "build", "test"} {
		if !got[want] {
			t.Errorf("expected %q in closure, got %v", want, got)
		}
	}
	if got["unrelated"] {
		t.Errorf("unrelated task should not be in closure")
	}
}

func stringPtr(s string) *string { return &s }

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
	for _, want := range []string{
		`plan for "test"`,           // header
		"build", "test",             // both tasks in the subgraph
		"go build", "go test",       // truncated cmd previews
		"status", "action key",      // table header
		"summary:", "will run",      // bottom summary line
	} {
		if !strings.Contains(out, want) {
			t.Errorf("dry-run output missing %q:\n%s", want, out)
		}
	}
}

func TestRunDryRunNoCacheForcesAllWillRun(t *testing.T) {
	requirePkl(t)
	var stdout, stderr bytes.Buffer
	if err := cmdRun([]string{"-f", basicTaskfile(t), "--dry-run", "--no-cache", "test"}, &stdout, &stderr); err != nil {
		t.Fatalf("cmdRun --dry-run --no-cache: %v", err)
	}
	out := stdout.String()
	if !strings.Contains(out, "--no-cache / --refresh active") {
		t.Errorf("missing --no-cache note:\n%s", out)
	}
	// "hit" appears in the summary line ("0 hit · …") regardless;
	// what we care about is no task ROW with hit status. Rows are
	// indented with two spaces and start with the status column.
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, "  hit ") {
			t.Errorf("--no-cache dry-run reported a hit row, expected none:\n%s", out)
			break
		}
	}
}

// -----------------------------------------------------------------
// Tests for the 0.5.0+ multi-target / default-task / summary / affected
// feature batch. Split into focused units (unionSubgraph, printRunSummary,
// affected-helpers) + integration (full cmdRun / cmdAffected paths).
// -----------------------------------------------------------------

// taskfileWithTasks writes a Taskfile.pkl in a temp dir with the
// canonical `amends` line followed by `body`, returning the file path.
// Body is raw Pkl (e.g. `local foo = new Task { ... }; tasks { foo }`).
func taskfileWithTasks(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "Taskfile.pkl")
	full := `amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.4.0#/Taskfile.pkl"
` + body
	if err := os.WriteFile(path, []byte(full), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// newGitRepoWithCommit initializes a fresh git repo in a temp dir,
// writes the given files, and commits them. Returns the repo path.
// Sets author/committer via env so `git commit` succeeds regardless
// of host git config. Branch is `main`.
func newGitRepoWithCommit(t *testing.T, files map[string]string) string {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available on PATH")
	}
	repo := t.TempDir()
	gitEnv := append(os.Environ(),
		"GIT_AUTHOR_NAME=test",
		"GIT_AUTHOR_EMAIL=test@example.com",
		"GIT_COMMITTER_NAME=test",
		"GIT_COMMITTER_EMAIL=test@example.com",
	)
	run := func(args ...string) {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", repo}, args...)...)
		cmd.Env = gitEnv
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v failed: %v\n%s", args, err, out)
		}
	}
	run("init", "-q", "-b", "main")
	for path, content := range files {
		full := filepath.Join(repo, path)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	run("add", ".")
	run("commit", "-q", "-m", "initial")
	return repo
}

// commitChange writes additional files (or overwrites existing ones)
// in `repo` and creates a new commit. Used to produce a non-empty
// `git diff HEAD~1..HEAD` for the affected-set tests.
func commitChange(t *testing.T, repo string, files map[string]string) {
	t.Helper()
	gitEnv := append(os.Environ(),
		"GIT_AUTHOR_NAME=test",
		"GIT_AUTHOR_EMAIL=test@example.com",
		"GIT_COMMITTER_NAME=test",
		"GIT_COMMITTER_EMAIL=test@example.com",
	)
	for path, content := range files {
		full := filepath.Join(repo, path)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for _, args := range [][]string{
		{"-C", repo, "add", "."},
		{"-C", repo, "commit", "-q", "-m", "change"},
	} {
		cmd := exec.Command("git", args...)
		cmd.Env = gitEnv
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v failed: %v\n%s", args, err, out)
		}
	}
}

func TestUnionSubgraphPreservesTopoOrder(t *testing.T) {
	// graph:
	//   a ← b ← c
	//   d ← c           (d also depends on c)
	g, err := graph.Build([]graph.Node{
		{Name: "a", Deps: []string{"b"}},
		{Name: "b", Deps: []string{"c"}},
		{Name: "c"},
		{Name: "d", Deps: []string{"c"}},
	})
	if err != nil {
		t.Fatalf("graph.Build: %v", err)
	}
	order, err := unionSubgraph(g, []string{"a", "d"})
	if err != nil {
		t.Fatalf("unionSubgraph: %v", err)
	}
	pos := map[string]int{}
	for i, n := range order {
		pos[n] = i
	}
	// Both subgraphs must be present, deduplicated.
	for _, n := range []string{"a", "b", "c", "d"} {
		if _, ok := pos[n]; !ok {
			t.Errorf("missing node %q in union: %v", n, order)
		}
	}
	if pos["c"] >= pos["b"] || pos["b"] >= pos["a"] {
		t.Errorf("topo order violated for a-chain: %v", order)
	}
	if pos["c"] >= pos["d"] {
		t.Errorf("d should come after c: %v", order)
	}
}

func TestUnionSubgraphDedupesSharedDeps(t *testing.T) {
	g, err := graph.Build([]graph.Node{
		{Name: "shared"},
		{Name: "x", Deps: []string{"shared"}},
		{Name: "y", Deps: []string{"shared"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	order, err := unionSubgraph(g, []string{"x", "y"})
	if err != nil {
		t.Fatal(err)
	}
	if len(order) != 3 {
		t.Errorf("expected 3 unique tasks, got %v", order)
	}
}

func TestPrintRunSummaryBasic(t *testing.T) {
	results := []orchestrator.Result{
		{Name: "a", Outcome: orchestrator.OutcomeHit, Duration: 50 * time.Millisecond},
		{Name: "b", Outcome: orchestrator.OutcomeRan, Duration: 200 * time.Millisecond},
		{Name: "c", Outcome: orchestrator.OutcomeUncached, Duration: 100 * time.Millisecond},
	}
	var buf bytes.Buffer
	printRunSummary(&buf, results, 500*time.Millisecond, false)
	out := buf.String()
	for _, want := range []string{"3 tasks", "1 hit", "2 ran", "1 uncached", "500ms wall"} {
		if !strings.Contains(out, want) {
			t.Errorf("summary missing %q:\n%s", want, out)
		}
	}
	// No `--timing` table when flag is false.
	if strings.Contains(out, "[pkf] timing:") {
		t.Errorf("--timing=false should suppress per-task table:\n%s", out)
	}
}

func TestPrintRunSummaryTimingOrdersDescending(t *testing.T) {
	results := []orchestrator.Result{
		{Name: "fast", Outcome: orchestrator.OutcomeRan, Duration: 1 * time.Millisecond},
		{Name: "slow", Outcome: orchestrator.OutcomeRan, Duration: 1 * time.Second},
		{Name: "med", Outcome: orchestrator.OutcomeRan, Duration: 100 * time.Millisecond},
	}
	var buf bytes.Buffer
	printRunSummary(&buf, results, 2*time.Second, true)
	out := buf.String()
	iSlow := strings.Index(out, "slow")
	iMed := strings.Index(out, "med")
	iFast := strings.Index(out, "fast")
	if iSlow < 0 || iMed < 0 || iFast < 0 {
		t.Fatalf("missing one of the rows:\n%s", out)
	}
	if !(iSlow < iMed && iMed < iFast) {
		t.Errorf("timing rows not descending by duration:\n%s", out)
	}
}

func TestPrintRunSummarySkippedTasksAreReported(t *testing.T) {
	results := []orchestrator.Result{
		{Name: "a", Outcome: orchestrator.OutcomeRan, Duration: 10 * time.Millisecond},
		{Name: "b", Outcome: orchestrator.OutcomeSkipped, Duration: 0},
	}
	var buf bytes.Buffer
	printRunSummary(&buf, results, 50*time.Millisecond, false)
	out := buf.String()
	if !strings.Contains(out, "1 skipped") {
		t.Errorf("expected `1 skipped` in summary:\n%s", out)
	}
}

func TestPrintRunSummaryEmptyResultsIsNoop(t *testing.T) {
	var buf bytes.Buffer
	printRunSummary(&buf, nil, 0, false)
	if buf.Len() != 0 {
		t.Errorf("empty results should produce no output, got %q", buf.String())
	}
}

func TestRunMultiTargetExecutesUnion(t *testing.T) {
	requirePkl(t)
	var stdout, stderr bytes.Buffer
	if err := cmdRun([]string{"-f", basicTaskfile(t), "--dry-run", "build", "test"}, &stdout, &stderr); err != nil {
		t.Fatalf("multi-target dry-run: %v", err)
	}
	out := stdout.String()
	for _, want := range []string{"build", "test"} {
		if !strings.Contains(out, want) {
			t.Errorf("multi-target plan missing %q:\n%s", want, out)
		}
	}
}

func TestRunMultiTargetRejectsParams(t *testing.T) {
	requirePkl(t)
	taskfile := taskfileWithTasks(t, `
local a = new Task { name = "a"; cmd = "echo a"; cache = false }
local b = new Task { name = "b"; cmd = "echo b"; cache = false }
tasks { a; b }
`)
	var stdout, stderr bytes.Buffer
	err := cmdRun([]string{"-f", taskfile, "--dry-run", "a", "b", "--foo=x"}, &stdout, &stderr)
	if err == nil {
		t.Fatal("expected error: multi-target + --param ambiguity")
	}
	if !strings.Contains(err.Error(), "multi-target") {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestRunNoArgsUsesDefaultTask(t *testing.T) {
	requirePkl(t)
	taskfile := taskfileWithTasks(t, `
local def = new Task { name = "default"; cmd = "echo defaulted"; cache = false }
tasks { def }
`)
	var stdout, stderr bytes.Buffer
	if err := cmdRun([]string{"-f", taskfile, "--dry-run"}, &stdout, &stderr); err != nil {
		t.Fatalf("default dry-run: %v", err)
	}
	if !strings.Contains(stdout.String(), `"default"`) {
		t.Errorf("expected default task in plan header:\n%s", stdout.String())
	}
}

func TestRunNoArgsErrorsWithoutDefault(t *testing.T) {
	requirePkl(t)
	taskfile := taskfileWithTasks(t, `
local foo = new Task { name = "foo"; cmd = "echo foo"; cache = false }
tasks { foo }
`)
	var stdout, stderr bytes.Buffer
	err := cmdRun([]string{"-f", taskfile, "--dry-run"}, &stdout, &stderr)
	if err == nil {
		t.Fatal("expected error when no target and no `default` task")
	}
	if !strings.Contains(err.Error(), "default") {
		t.Errorf("error should mention `default`: %v", err)
	}
}

func TestGitChangedFilesReturnsAsymmetricDiff(t *testing.T) {
	repo := newGitRepoWithCommit(t, map[string]string{
		"src/main.go": "package main\n",
		"README.md":   "hello\n",
	})
	commitChange(t, repo, map[string]string{
		"src/main.go": "package main\nfunc main() {}\n",
	})
	got, err := gitChangedFiles(repo, "HEAD~1")
	if err != nil {
		t.Fatalf("gitChangedFiles: %v", err)
	}
	if len(got) != 1 || got[0] != "src/main.go" {
		t.Errorf("got %v, want [src/main.go]", got)
	}
}

func TestGitChangedFilesEmptyWhenNoCommits(t *testing.T) {
	repo := newGitRepoWithCommit(t, map[string]string{"x": "1\n"})
	got, err := gitChangedFiles(repo, "HEAD")
	if err != nil {
		t.Fatalf("gitChangedFiles: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("expected no changed files vs HEAD, got %v", got)
	}
}

func TestDefaultAffectedRefFallsBackToHEAD1(t *testing.T) {
	repo := newGitRepoWithCommit(t, map[string]string{"x": "1\n"})
	if got := defaultAffectedRef(repo); got != "HEAD~1" {
		t.Errorf("no origin/* configured: expected HEAD~1, got %q", got)
	}
}

func TestCmdAffectedSelectsTouchedTaskOnly(t *testing.T) {
	requirePkl(t)
	taskfile := `amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.4.0#/Taskfile.pkl"

local goBuild = new Task {
  name = "go-build"
  cmd  = "echo go build"
  cache = false
  inputs { "src/**/*.go" }
}
local docs = new Task {
  name = "docs"
  cmd  = "echo docs"
  cache = false
  inputs { "docs/**/*.md" }
}
tasks { goBuild; docs }
`
	repo := newGitRepoWithCommit(t, map[string]string{
		"Taskfile.pkl":  taskfile,
		"src/main.go":   "package main\n",
		"docs/intro.md": "intro\n",
	})
	commitChange(t, repo, map[string]string{
		"src/main.go": "package main\nfunc main() {}\n",
	})

	var stdout, stderr bytes.Buffer
	err := cmdAffected(
		[]string{"-f", filepath.Join(repo, "Taskfile.pkl"), "--since=HEAD~1", "--dry-run"},
		&stdout, &stderr,
	)
	if err != nil {
		t.Fatalf("cmdAffected: %v\n%s\n%s", err, stdout.String(), stderr.String())
	}
	out := stdout.String()
	if !strings.Contains(out, "go-build") {
		t.Errorf("`go-build` should be in the affected plan:\n%s", out)
	}
	// `docs` should NOT appear in the plan — its inputs glob doesn't
	// match anything in the diff.
	for _, line := range strings.Split(out, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "uncached") || strings.HasPrefix(trimmed, "will run") || strings.HasPrefix(trimmed, "hit") {
			if strings.Contains(trimmed, " docs") || strings.HasSuffix(trimmed, " docs") {
				t.Errorf("`docs` should not be affected by src/*.go changes:\n%s", out)
				break
			}
		}
	}
}

func TestCmdAffectedNoChangedFilesIsSilent(t *testing.T) {
	requirePkl(t)
	taskfile := `amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.4.0#/Taskfile.pkl"

local t = new Task { name = "t"; cmd = "echo t"; cache = false; inputs { "**/*.go" } }
tasks { t }
`
	repo := newGitRepoWithCommit(t, map[string]string{
		"Taskfile.pkl": taskfile,
		"main.go":      "package main\n",
	})
	var stdout, stderr bytes.Buffer
	err := cmdAffected(
		[]string{"-f", filepath.Join(repo, "Taskfile.pkl"), "--since=HEAD"},
		&stdout, &stderr,
	)
	if err != nil {
		t.Fatalf("cmdAffected: %v", err)
	}
	if !strings.Contains(stderr.String(), "no changed files") {
		t.Errorf("expected `no changed files` notice on stderr, got: %s", stderr.String())
	}
}

func TestCmdAffectedPositionalFilterRestrictsPlan(t *testing.T) {
	requirePkl(t)
	taskfile := `amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.4.0#/Taskfile.pkl"

local goBuild = new Task {
  name = "go-build"
  cmd  = "echo go build"
  cache = false
  inputs { "src/**/*.go" }
}
local goTest = new Task {
  name = "go-test"
  cmd  = "echo go test"
  cache = false
  inputs { "src/**/*.go" }
}
tasks { goBuild; goTest }
`
	repo := newGitRepoWithCommit(t, map[string]string{
		"Taskfile.pkl": taskfile,
		"src/main.go":  "package main\n",
	})
	commitChange(t, repo, map[string]string{
		"src/main.go": "package main\nvar _ = 1\n",
	})
	var stdout, stderr bytes.Buffer
	err := cmdAffected(
		[]string{"-f", filepath.Join(repo, "Taskfile.pkl"), "--since=HEAD~1", "--dry-run", "go-build"},
		&stdout, &stderr,
	)
	if err != nil {
		t.Fatalf("cmdAffected: %v\n%s", err, stderr.String())
	}
	out := stdout.String()
	if !strings.Contains(out, "go-build") {
		t.Errorf("`go-build` should be in the filtered plan:\n%s", out)
	}
	// Filter should drop go-test even though its inputs would match.
	for _, line := range strings.Split(out, "\n") {
		if strings.Contains(line, "go-test") {
			t.Errorf("`go-test` should have been filtered out:\n%s", out)
			break
		}
	}
}

func TestCmdAffectedExpandsToDependents(t *testing.T) {
	requirePkl(t)
	// `gen` is directly touched; `build` deps on `gen`; `test` deps on
	// `build`. The whole chain must end up in the plan even though
	// build/test's own inputs don't intersect the diff.
	taskfile := `amends "package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@0.4.0#/Taskfile.pkl"

local gen = new Task {
  name = "gen"
  cmd  = "echo gen"
  cache = false
  inputs { "schema/**/*.txt" }
}
local build = new Task {
  name = "build"
  cmd  = "echo build"
  cache = false
  deps { gen }
}
local test = new Task {
  name = "test"
  cmd  = "echo test"
  cache = false
  deps { build }
}
tasks { gen; build; test }
`
	repo := newGitRepoWithCommit(t, map[string]string{
		"Taskfile.pkl":   taskfile,
		"schema/api.txt": "v1\n",
	})
	commitChange(t, repo, map[string]string{
		"schema/api.txt": "v2\n",
	})
	var stdout, stderr bytes.Buffer
	if err := cmdAffected(
		[]string{"-f", filepath.Join(repo, "Taskfile.pkl"), "--since=HEAD~1", "--dry-run"},
		&stdout, &stderr,
	); err != nil {
		t.Fatalf("cmdAffected: %v\n%s", err, stderr.String())
	}
	out := stdout.String()
	for _, want := range []string{"gen", "build", "test"} {
		if !strings.Contains(out, want) {
			t.Errorf("dependent expansion lost %q:\n%s", want, out)
		}
	}
}
