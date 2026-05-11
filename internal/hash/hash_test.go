package hash_test

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/mizchi/pkfire/internal/hash"
)

func mustWrite(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestKeyIsDeterministic(t *testing.T) {
	a := &hash.Action{
		Cmd:        "go build ./...",
		Shell:      "bash",
		Env:        map[string]string{"GOOS": "darwin", "CGO_ENABLED": "0"},
		Tools:      map[string]string{"go": "1.26.2"},
		Inputs:     []hash.FileEntry{{Path: "main.go", Hash: []byte{1, 2, 3}}},
		ConfigHash: []byte("cfg"),
	}
	k1 := a.Key()
	k2 := a.Key()
	if k1 != k2 {
		t.Fatal("Key is not deterministic")
	}
}

func TestKeyChangesWhenAnyComponentChanges(t *testing.T) {
	base := hash.Action{
		Cmd:        "echo hi",
		Shell:      "bash",
		Env:        map[string]string{"A": "1"},
		Tools:      map[string]string{"go": "1.26"},
		Inputs:     []hash.FileEntry{{Path: "a.go", Hash: []byte{0xaa}}},
		ConfigHash: []byte("c0"),
	}
	baseKey := base.Key()

	mutate := func(name string, f func(a *hash.Action)) {
		t.Run(name, func(t *testing.T) {
			a := base
			a.Env = cloneMap(base.Env)
			a.Tools = cloneMap(base.Tools)
			a.Inputs = append([]hash.FileEntry(nil), base.Inputs...)
			f(&a)
			if a.Key() == baseKey {
				t.Fatalf("%s did not change action key", name)
			}
		})
	}

	mutate("cmd", func(a *hash.Action) { a.Cmd = "echo bye" })
	mutate("shell", func(a *hash.Action) { a.Shell = "zsh" })
	mutate("env", func(a *hash.Action) { a.Env["A"] = "2" })
	mutate("tools", func(a *hash.Action) { a.Tools["go"] = "1.27" })
	mutate("input-content", func(a *hash.Action) { a.Inputs[0].Hash = []byte{0xbb} })
	mutate("input-path", func(a *hash.Action) { a.Inputs[0].Path = "b.go" })
	mutate("config", func(a *hash.Action) { a.ConfigHash = []byte("c1") })
	mutate("args-added", func(a *hash.Action) { a.Args = []string{"x"} })
	mutate("params-added", func(a *hash.Action) { a.Params = map[string]string{"BUMP": "patch"} })
}

func TestArgOrderAffectsKey(t *testing.T) {
	a := &hash.Action{Cmd: "x", Args: []string{"a", "b"}}
	b := &hash.Action{Cmd: "x", Args: []string{"b", "a"}}
	if a.Key() == b.Key() {
		t.Fatal("arg order should affect key")
	}
}

func TestKeyIgnoresEnvMapOrder(t *testing.T) {
	a := &hash.Action{Env: map[string]string{"B": "2", "A": "1"}}
	b := &hash.Action{Env: map[string]string{"A": "1", "B": "2"}}
	if a.Key() != b.Key() {
		t.Fatal("env order should not affect key")
	}
}

func TestExpandInputsHandlesDoublestar(t *testing.T) {
	root := t.TempDir()
	mustWrite(t, filepath.Join(root, "a.go"), "package x")
	mustWrite(t, filepath.Join(root, "sub/b.go"), "package y")
	mustWrite(t, filepath.Join(root, "sub/c.txt"), "skip me")
	mustWrite(t, filepath.Join(root, "deep/nested/d.go"), "package z")

	got, err := hash.ExpandInputs(root, []string{"**/*.go"})
	if err != nil {
		t.Fatalf("ExpandInputs: %v", err)
	}
	want := []string{"a.go", "deep/nested/d.go", "sub/b.go"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestExpandInputsDeduplicates(t *testing.T) {
	root := t.TempDir()
	mustWrite(t, filepath.Join(root, "a.go"), "package x")
	got, err := hash.ExpandInputs(root, []string{"a.go", "*.go", "**/*.go"})
	if err != nil {
		t.Fatalf("ExpandInputs: %v", err)
	}
	if !reflect.DeepEqual(got, []string{"a.go"}) {
		t.Errorf("got %v, want [a.go]", got)
	}
}

func TestHashInputsReflectsContentChange(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "x.go")
	mustWrite(t, target, "v1")

	first, err := hash.HashInputs(root, []string{"x.go"})
	if err != nil {
		t.Fatalf("HashInputs: %v", err)
	}
	mustWrite(t, target, "v2")
	second, err := hash.HashInputs(root, []string{"x.go"})
	if err != nil {
		t.Fatalf("HashInputs: %v", err)
	}
	if reflect.DeepEqual(first[0].Hash, second[0].Hash) {
		t.Fatal("file hash should change after edit")
	}
}

func cloneMap(m map[string]string) map[string]string {
	out := make(map[string]string, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}
