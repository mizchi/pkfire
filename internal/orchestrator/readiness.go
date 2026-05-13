// Readiness probes for service tasks: TCP-port and shell-command checks.
// The same probe drives two behaviors during service spinup:
//
//  1. Reuse — when a probe succeeds *before* pkfire spawns the service,
//     the service is already up (typically: another `pkf up` session in
//     a different shell is owning it). pkfire skips the spawn and the
//     teardown so the existing process keeps running.
//  2. Startup gating — after a fresh spawn, pkfire polls the same probe
//     until it succeeds or `readyTimeoutSeconds` elapses. Dependent
//     services (and the body task's `cmd`) only start once readiness
//     passes.
//
// A task with no probe (`readyPort == 0` and `readyCmd == ""`) keeps the
// v1 "start and hope" behavior — useful for daemons whose readiness can
// only be inferred from the cmd's stdout, where the user is expected to
// implement their own retry in the consumer.
package orchestrator

import (
	"context"
	"fmt"
	"net"
	"os/exec"
	"time"

	"github.com/mizchi/pkfire/internal/config"
)

const (
	tcpProbeTimeout = 500 * time.Millisecond
	probeInterval   = 250 * time.Millisecond
)

// hasProbe reports whether the task declares any readiness signal.
func hasProbe(t *config.Task) bool {
	return t.ReadyPort > 0 || t.ReadyCmd != ""
}

// probeReady runs every configured probe once and returns nil iff all of
// them succeed. Probes are cheap (≤ tcpProbeTimeout for TCP, one shell
// exec for cmd) but a returned error is informational only — the caller
// retries on a poll loop.
func probeReady(ctx context.Context, t *config.Task, defaults *config.Defaults) error {
	if t.ReadyPort > 0 {
		addr := fmt.Sprintf("localhost:%d", t.ReadyPort)
		dialer := net.Dialer{Timeout: tcpProbeTimeout}
		c, err := dialer.DialContext(ctx, "tcp", addr)
		if err != nil {
			return fmt.Errorf("tcp probe %s: %w", addr, err)
		}
		_ = c.Close()
	}
	if t.ReadyCmd != "" {
		shell := config.ResolveShell(t, defaults)
		cmdArgs := config.ResolveShellFlags(t, defaults)
		cmdArgs = append(cmdArgs, t.ReadyCmd)
		cmd := exec.CommandContext(ctx, shell, cmdArgs...)
		// Probe runs with a minimal env — don't leak the runner's
		// merged env into a shell snippet whose only purpose is to
		// answer "is the service ready".
		cmd.Env = nil
		if out, err := cmd.CombinedOutput(); err != nil {
			return fmt.Errorf("cmd probe failed: %w (output: %s)", err, out)
		}
	}
	return nil
}

// waitReady polls the probe until it succeeds, the deadline elapses, or
// the context is cancelled. Returns nil on success; ctx.Err() if the
// caller cancels; a wrapped error otherwise.
func waitReady(ctx context.Context, t *config.Task, defaults *config.Defaults) error {
	timeout := time.Duration(t.ReadyTimeoutSeconds) * time.Second
	if timeout <= 0 {
		timeout = 30 * time.Second
	}
	deadline := time.Now().Add(timeout)
	var lastErr error
	for {
		if err := probeReady(ctx, t, defaults); err == nil {
			return nil
		} else {
			lastErr = err
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("readiness probe did not pass within %v: %w", timeout, lastErr)
		}
		select {
		case <-time.After(probeInterval):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}
