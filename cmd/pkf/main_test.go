package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

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
	if !strings.Contains(string(body), `amends "https://raw.githubusercontent.com/mizchi/pkfire/`) {
		t.Errorf("skeleton missing HTTPS amends line:\n%s", body)
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
