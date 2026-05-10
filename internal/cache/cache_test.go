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

func TestStoreEmptyOutputsStillRegistersEntry(t *testing.T) {
	c := cache.New(t.TempDir())
	key := [32]byte{0x02}
	if err := c.Store(key, t.TempDir(), nil); err != nil {
		t.Fatalf("Store with no outputs: %v", err)
	}
	// Entry must exist so that no-output tasks like `go vet` can hit cache.
	if !c.Has(key) {
		t.Error("Has should be true even when outputs were empty")
	}
	if err := c.Restore(key, t.TempDir()); err != nil {
		t.Errorf("Restore of empty entry: %v", err)
	}
}

func TestStoreAndRestorePreservesSymlinks(t *testing.T) {
	src := t.TempDir()
	mustWrite(t, filepath.Join(src, "out/real/data.txt"), "PAYLOAD")
	if err := os.Symlink("real/data.txt", filepath.Join(src, "out/aliased.txt")); err != nil {
		t.Fatalf("symlink (file): %v", err)
	}
	if err := os.Symlink("real", filepath.Join(src, "out/real-dir")); err != nil {
		t.Fatalf("symlink (dir): %v", err)
	}

	c := cache.New(t.TempDir())
	key := [32]byte{0x77}
	if err := c.Store(key, src, []string{"out"}); err != nil {
		t.Fatalf("Store: %v", err)
	}

	dst := t.TempDir()
	if err := c.Restore(key, dst); err != nil {
		t.Fatalf("Restore: %v", err)
	}

	// Regular file landed.
	got, err := os.ReadFile(filepath.Join(dst, "out/real/data.txt"))
	if err != nil || string(got) != "PAYLOAD" {
		t.Fatalf("real file = %q err=%v", got, err)
	}

	// File symlink: lstat sees the symlink; readlink returns the target.
	info, err := os.Lstat(filepath.Join(dst, "out/aliased.txt"))
	if err != nil {
		t.Fatalf("lstat alias: %v", err)
	}
	if info.Mode()&os.ModeSymlink == 0 {
		t.Errorf("aliased.txt was not restored as a symlink (mode=%v)", info.Mode())
	}
	link, err := os.Readlink(filepath.Join(dst, "out/aliased.txt"))
	if err != nil {
		t.Fatalf("readlink alias: %v", err)
	}
	if link != "real/data.txt" {
		t.Errorf("alias linkname = %q, want real/data.txt", link)
	}

	// Dir symlink behaves the same way.
	dirLink, err := os.Readlink(filepath.Join(dst, "out/real-dir"))
	if err != nil {
		t.Fatalf("readlink real-dir: %v", err)
	}
	if dirLink != "real" {
		t.Errorf("real-dir linkname = %q, want real", dirLink)
	}

	// Reading through the symlink works (the target was restored).
	through, err := os.ReadFile(filepath.Join(dst, "out/real-dir/data.txt"))
	if err != nil || string(through) != "PAYLOAD" {
		t.Errorf("read through dir symlink = %q err=%v", through, err)
	}
}

func TestRestoreRejectsAbsoluteSymlink(t *testing.T) {
	src := t.TempDir()
	if err := os.MkdirAll(filepath.Join(src, "out"), 0o755); err != nil {
		t.Fatal(err)
	}
	// Absolute target — should be rejected on extract for safety.
	if err := os.Symlink("/etc/passwd", filepath.Join(src, "out/escape")); err != nil {
		t.Fatalf("symlink: %v", err)
	}

	c := cache.New(t.TempDir())
	key := [32]byte{0x78}
	if err := c.Store(key, src, []string{"out"}); err != nil {
		t.Fatalf("Store: %v", err)
	}

	if err := c.Restore(key, t.TempDir()); err == nil {
		t.Fatal("expected Restore to refuse an absolute symlink target")
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
