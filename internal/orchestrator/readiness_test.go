package orchestrator_test

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/mizchi/pkfire/internal/config"
	"github.com/mizchi/pkfire/internal/orchestrator"
	"github.com/mizchi/pkfire/internal/runner"
)

// syncBuf is a goroutine-safe bytes.Buffer wrapper. Service spawns,
// the body task, and orchestrator log lines all race for the same
// stdout/stderr writers — a plain bytes.Buffer races under
// `go test -race`.
type syncBuf struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (s *syncBuf) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.Write(p)
}

func (s *syncBuf) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.String()
}

// TestServicesReuseExistingProcessByPortProbe verifies that when a
// service declares a `readyPort` and the port is already accepting
// connections (e.g. a `pkf up` session running in another shell), the
// orchestrator reuses the existing process: it does not spawn a new
// instance, does not poll for readiness on a fresh spawn, and does
// not tear anything down at the end of the body task.
//
// We simulate the "already running" state with a one-line listener.
// If reuse worked, the listener is still alive after the run; if the
// orchestrator spawned the service's `cmd` instead, the cmd's
// `pkill -f own-name` would have been observed in stderr.
func TestServicesReuseExistingProcessByPortProbe(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("setup listener: %v", err)
	}
	defer listener.Close()
	port := listener.Addr().(*net.TCPAddr).Port

	go func() {
		for {
			c, err := listener.Accept()
			if err != nil {
				return
			}
			_ = c.Close()
		}
	}()

	mock := &config.Task{
		// If reuse fails, this would echo the marker before sleep.
		Cmd:                    "echo SHOULD_NOT_RUN; sleep 5",
		Shell:                  "bash",
		Service:                true,
		ReadyPort:              port,
		ReadyTimeoutSeconds:    5,
		ShutdownTimeoutSeconds: 1,
	}
	probe := &config.Task{
		Cmd:      "echo body-ran",
		Shell:    "bash",
		Cache:    false,
		Services: []string{"mock"},
	}
	tf := map[string]*config.Task{"mock": mock, "probe": probe}
	plan := &orchestrator.Plan{
		Order:    []string{"probe"},
		Tasks:    tf,
		Defaults: &config.Defaults{Shell: "bash"},
		Root:     t.TempDir(),
	}

	var stdout, stderr syncBuf
	r := runner.New(runner.Options{Stdout: &stdout, Stderr: &stderr, Workdir: plan.Root})
	orch := orchestrator.New(nil, r, &stdout, &stderr, orchestrator.Options{Parallelism: 1})

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	results, err := orch.Execute(ctx, plan)
	if err != nil {
		t.Fatalf("Execute: %v\nstderr: %s", err, stderr.String())
	}
	if len(results) != 1 || results[0].Name != "probe" {
		t.Fatalf("unexpected results: %+v", results)
	}

	combined := stderr.String() + stdout.String()
	if !strings.Contains(combined, fmt.Sprintf(`reusing existing service "mock"`)) {
		t.Errorf("expected reuse log line; got:\n%s", combined)
	}
	if strings.Contains(combined, "SHOULD_NOT_RUN") {
		t.Errorf("mock cmd was executed despite the port being already open:\n%s", combined)
	}
	if !strings.Contains(stdout.String(), "body-ran") {
		t.Errorf("body cmd never produced its marker:\n%s", stdout.String())
	}
}

// TestServicesWaitForReadinessAfterSpawn verifies that when no
// pre-existing listener is on `readyPort`, the orchestrator spawns
// the service and gates the body task on the probe passing — i.e.
// dependent code only runs *after* the service binds the port.
func TestServicesWaitForReadinessAfterSpawn(t *testing.T) {
	port := freeTCPPort(t)

	// Service: small bash listener that binds the port after a brief
	// delay so the wait loop has something to actually wait on.
	mock := &config.Task{
		// Sleep, bind, then accept-and-close in a tight loop so probe
		// dials don't consume the only backlog slot. Without the loop
		// the second connect (the body's) would ETIMEDOUT against a
		// full listen-queue.
		Cmd: fmt.Sprintf(
			`sleep 0.5; exec python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",%d)); s.listen(8)
while True:
  c,_=s.accept(); c.close()'`,
			port,
		),
		Shell:                  "bash",
		Service:                true,
		ReadyPort:              port,
		ReadyTimeoutSeconds:    5,
		ShutdownTimeoutSeconds: 1,
	}
	probe := &config.Task{
		// Body asserts the port is open at the moment it runs.
		Cmd: fmt.Sprintf(
			`python3 -c 'import socket; s=socket.socket(); s.connect(("127.0.0.1",%d))' && echo body-saw-port-open`,
			port,
		),
		Shell:    "bash",
		Cache:    false,
		Services: []string{"mock"},
	}
	tf := map[string]*config.Task{"mock": mock, "probe": probe}
	plan := &orchestrator.Plan{
		Order:    []string{"probe"},
		Tasks:    tf,
		Defaults: &config.Defaults{Shell: "bash"},
		Root:     t.TempDir(),
	}

	var stdout, stderr syncBuf
	r := runner.New(runner.Options{Stdout: &stdout, Stderr: &stderr, Workdir: plan.Root})
	orch := orchestrator.New(nil, r, &stdout, &stderr, orchestrator.Options{Parallelism: 1})

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	if _, err := orch.Execute(ctx, plan); err != nil {
		t.Fatalf("Execute: %v\nstderr: %s", err, stderr.String())
	}
	combined := stderr.String() + stdout.String()
	if !strings.Contains(combined, `service "mock" is ready`) {
		t.Errorf("expected readiness log; got:\n%s", combined)
	}
	if !strings.Contains(stdout.String(), "body-saw-port-open") {
		t.Errorf("body did not see the port open at run time:\n%s", combined)
	}
}

func freeTCPPort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("free port: %v", err)
	}
	port := l.Addr().(*net.TCPAddr).Port
	_ = l.Close()
	return port
}
