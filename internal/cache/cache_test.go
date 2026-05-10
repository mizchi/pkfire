package cache_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/mizchi/pkfire/internal/cache"
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

func TestStoreAndRestoreRoundTrip(t *testing.T) {
	src := t.TempDir()
	dst := t.TempDir()
	cas := t.TempDir()

	mustWrite(t, filepath.Join(src, "bin/app"), "BINARY")
	mustWrite(t, filepath.Join(src, "bin/sub/extra.txt"), "EXTRA")
	mustWrite(t, filepath.Join(src, "untouched.txt"), "should-not-cache")

	c := cache.New(cas)
	key := [32]byte{0xab, 0xcd}

	if c.Has(key) {
		t.Fatal("fresh cache should not Has")
	}
	if err := c.Store(key, src, []string{"bin"}); err != nil {
		t.Fatalf("Store: %v", err)
	}
	if !c.Has(key) {
		t.Fatal("Has should be true after Store")
	}

	if err := c.Restore(key, dst); err != nil {
		t.Fatalf("Restore: %v", err)
	}
	got, err := os.ReadFile(filepath.Join(dst, "bin/app"))
	if err != nil {
		t.Fatalf("read app: %v", err)
	}
	if string(got) != "BINARY" {
		t.Errorf("bin/app = %q", got)
	}
	if _, err := os.Stat(filepath.Join(dst, "bin/sub/extra.txt")); err != nil {
		t.Errorf("nested file not restored: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dst, "untouched.txt")); !os.IsNotExist(err) {
		t.Errorf("non-output file should not have been cached: err=%v", err)
	}
}

func TestStoreSkipsMissingOutputs(t *testing.T) {
	src := t.TempDir()
	mustWrite(t, filepath.Join(src, "real"), "x")
	c := cache.New(t.TempDir())
	key := [32]byte{0x01}
	// "ghost" does not exist; Store should still succeed and only archive "real".
	if err := c.Store(key, src, []string{"real", "ghost"}); err != nil {
		t.Fatalf("Store: %v", err)
	}
	dst := t.TempDir()
	if err := c.Restore(key, dst); err != nil {
		t.Fatalf("Restore: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dst, "real")); err != nil {
		t.Errorf("expected `real` to be restored: %v", err)
	}
}

func TestStoreNoOutputsIsNoop(t *testing.T) {
	c := cache.New(t.TempDir())
	key := [32]byte{0x02}
	if err := c.Store(key, t.TempDir(), nil); err != nil {
		t.Fatalf("Store with no outputs: %v", err)
	}
	if c.Has(key) {
		t.Error("Has should remain false when no outputs were stored")
	}
}

func TestRestoreIsHermeticAgainstSiblingFiles(t *testing.T) {
	src := t.TempDir()
	mustWrite(t, filepath.Join(src, "out/a"), "AA")
	c := cache.New(t.TempDir())
	key := [32]byte{0x03}
	if err := c.Store(key, src, []string{"out"}); err != nil {
		t.Fatalf("Store: %v", err)
	}
	dst := t.TempDir()
	mustWrite(t, filepath.Join(dst, "out/b"), "should-survive")
	if err := c.Restore(key, dst); err != nil {
		t.Fatalf("Restore: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dst, "out/b")); err != nil {
		t.Errorf("Restore should not touch unrelated sibling files: %v", err)
	}
}
