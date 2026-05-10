package watcher_test

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/mizchi/pkfire/internal/watcher"
)

func TestEmitsEventOnFileWrite(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "src.go")
	if err := os.WriteFile(target, []byte("v1"), 0o644); err != nil {
		t.Fatal(err)
	}

	w, err := watcher.New([]string{dir}, 50*time.Millisecond)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	t.Cleanup(func() { w.Close() })

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go w.Run(ctx)

	time.Sleep(20 * time.Millisecond)

	if err := os.WriteFile(target, []byte("v2"), 0o644); err != nil {
		t.Fatal(err)
	}

	select {
	case <-w.Events():
	case <-time.After(2 * time.Second):
		t.Fatal("did not receive event within 2s")
	}
}

func TestCoalescesBurstOfWrites(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "a"), []byte("0"), 0o644); err != nil {
		t.Fatal(err)
	}

	w, err := watcher.New([]string{dir}, 100*time.Millisecond)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	t.Cleanup(func() { w.Close() })

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go w.Run(ctx)

	time.Sleep(20 * time.Millisecond)

	for i := 0; i < 10; i++ {
		os.WriteFile(filepath.Join(dir, "a"), []byte{byte(i)}, 0o644)
		time.Sleep(10 * time.Millisecond)
	}

	got := 0
	deadline := time.After(800 * time.Millisecond)
loop:
	for {
		select {
		case <-w.Events():
			got++
		case <-deadline:
			break loop
		}
	}
	if got == 0 {
		t.Fatal("expected at least one coalesced event")
	}
	if got > 3 {
		t.Errorf("burst was not coalesced: got %d events for 10 writes", got)
	}
}

func TestIgnoresMissingPaths(t *testing.T) {
	dir := t.TempDir()
	missing := filepath.Join(dir, "ghost", "still-missing.txt")
	if _, err := watcher.New([]string{missing}, 10*time.Millisecond); err != nil {
		t.Fatalf("New should tolerate missing paths, got %v", err)
	}
}
