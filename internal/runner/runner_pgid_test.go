//go:build unix

package runner_test

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/mizchi/pkfire/internal/config"
	"github.com/mizchi/pkfire/internal/runner"
)

// TestRunReleasesGrandchildOnCancel verifies that when a task's context is
// cancelled, the runner SIGTERMs the entire process group — not just the
// shell — so a `bash -c "node server.js"`-style task does not leak its
// node child. The test forks a `sleep` in the background, records its pid,
// cancels the context, and asserts the sleep is no longer alive.
func TestRunReleasesGrandchildOnCancel(t *testing.T) {
	tmp := t.TempDir()
	pidFile := filepath.Join(tmp, "grandchild.pid")

	r := runner.New(runner.Options{Stdout: io.Discard, Stderr: io.Discard})
	ctx, cancel := context.WithCancel(context.Background())

	task := &config.Task{
		// Background sleep is the grandchild we expect to die.
		Cmd:                    fmt.Sprintf("sleep 30 & echo $! > %s; wait", pidFile),
		Shell:                  "bash",
		ShutdownTimeoutSeconds: 1,
	}

	runDone := make(chan error, 1)
	go func() { runDone <- r.Run(ctx, "sleeper", task, nil) }()

	pid := waitForPidFile(t, pidFile, 3*time.Second)
	cancel()

	select {
	case err := <-runDone:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("expected context.Canceled, got %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not return within 5s of cancel")
	}

	// Give the kernel a moment to reap the now-orphaned grandchild.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if err := syscall.Kill(pid, 0); errors.Is(err, syscall.ESRCH) {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Errorf("grandchild pid %d still alive 2s after cancel — process-group kill did not propagate", pid)
}

func waitForPidFile(t *testing.T, path string, timeout time.Duration) int {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		data, err := os.ReadFile(path)
		if err == nil {
			if pid, perr := strconv.Atoi(strings.TrimSpace(string(data))); perr == nil && pid > 0 {
				return pid
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("pid file %s never appeared", path)
	return 0
}
