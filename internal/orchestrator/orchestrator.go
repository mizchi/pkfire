// Package orchestrator coordinates the cache and the runner: for each task
// in topological order it derives the action key, returns a cached result
// when present, otherwise executes the task and stores the resulting outputs.
//
// Execute schedules tasks in parallel with a semaphore-bounded worker count
// while preserving declared dependencies via per-task done-channels.
package orchestrator

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"runtime"
	"sync"
	"time"

	"github.com/mizchi/pkfire/internal/cache"
	"github.com/mizchi/pkfire/internal/config"
	"github.com/mizchi/pkfire/internal/hash"
	"github.com/mizchi/pkfire/internal/runner"
)

// Outcome reports how a task was satisfied during a run.
type Outcome int

const (
	// OutcomeRan means the task executed and (if applicable) was cached.
	OutcomeRan Outcome = iota
	// OutcomeHit means the cache had a matching entry and outputs were restored.
	OutcomeHit
	// OutcomeUncached means the task executed but had `cache = false` set.
	OutcomeUncached
	// OutcomeSkipped means an upstream dependency failed and we never ran.
	OutcomeSkipped
)

// String renders an Outcome for log lines and debugging.
func (o Outcome) String() string {
	switch o {
	case OutcomeHit:
		return "hit"
	case OutcomeUncached:
		return "ran (uncached)"
	case OutcomeSkipped:
		return "skipped"
	default:
		return "ran"
	}
}

// Result records what happened for one task. `Key` is the zero value when
// the task was skipped before its key could be computed. `Duration` is
// the wall time spent on the task itself — cache restore for a hit,
// cmd execution for a run, zero for a skip.
type Result struct {
	Name     string
	Key      [32]byte
	Outcome  Outcome
	Duration time.Duration
}

// Plan is everything Execute needs that is not the orchestrator's own
// runner/cache. ConfigHash is typically `hash.HashBytes(taskfile.Canonical)`.
//
// Target/TargetInvocation describe the per-run command-line overlay for
// the explicit target task (the one the user named on `pkf run`).
// Non-target tasks always see a nil invocation: deps don't receive
// caller args/params, so their action keys stay stable across
// invocations.
//
// Refresh, when true, skips the cache *lookup* path but still writes
// results back to the cache. The difference from "no cache backend
// configured" is that a refresh run leaves the cache populated for
// subsequent normal runs — use it when an undeclared dependency
// changed (a global tool version, an environment shift outside
// `env { ... }`) and you want to re-baseline rather than execute
// uncached forever.
type Plan struct {
	Order            []string
	Tasks            map[string]*config.Task
	Defaults         *config.Defaults
	Root             string
	ConfigHash       []byte
	Target           string
	TargetInvocation *runner.Invocation
	Refresh          bool
}

// Options tunes a single Execute invocation.
type Options struct {
	// Parallelism is the maximum number of tasks running concurrently.
	// 0 means runtime.NumCPU(); 1 forces serial execution.
	Parallelism int
}

// Orchestrator holds the long-lived runner and (optionally) cache.
// A nil cache disables caching for the whole run.
type Orchestrator struct {
	cache  cache.Backend
	runner *runner.Runner
	stdout io.Writer
	stderr io.Writer
	opts   Options
}

// New returns an Orchestrator. `stderr` receives one human-readable line per
// task ("hit"/"ran"/"skipped") and may be io.Discard. `stdout` is where each
// task's captured stdout is flushed under a lock once the task finishes.
// `c` may be any backend (local CAS, HTTP remote, or layered combination)
// or nil to disable caching entirely.
func New(c cache.Backend, r *runner.Runner, stdout, stderr io.Writer, opts Options) *Orchestrator {
	if stdout == nil {
		stdout = io.Discard
	}
	if stderr == nil {
		stderr = io.Discard
	}
	return &Orchestrator{cache: c, runner: r, stdout: stdout, stderr: stderr, opts: opts}
}

// ComputeKey assembles a `hash.Action` for `task` and returns its action key.
// Exposed so `pkf run --print-hash` can reuse the same logic.
//
// `inv` is the per-invocation overlay (caller args + resolved params);
// pass nil for non-target tasks. When non-nil and non-empty, its
// contents are part of the digest so caller-supplied params/args
// invalidate the cache for that single task.
func ComputeKey(task *config.Task, defaults *config.Defaults, root string, configHash []byte, inv *runner.Invocation) ([32]byte, error) {
	entries, err := hash.HashInputs(root, task.Inputs)
	if err != nil {
		return [32]byte{}, err
	}
	shell := task.Shell
	var defEnv map[string]string
	if defaults != nil {
		if shell == "" {
			shell = defaults.Shell
		}
		defEnv = defaults.Env
	}
	a := &hash.Action{
		Cmd:        task.Cmd,
		Shell:      shell,
		Env:        hash.MergeEnv(defEnv, task.Env),
		Tools:      task.Tools,
		Inputs:     entries,
		ConfigHash: configHash,
	}
	if inv != nil {
		a.Args = inv.Args
		a.Params = inv.Params
	}
	return a.Key(), nil
}

// invocationFor returns the per-task invocation overlay: the plan's
// target invocation when `name` matches `plan.Target`, otherwise nil
// (deps don't receive caller args/params).
func invocationFor(p *Plan, name string) *runner.Invocation {
	if p.Target != "" && p.Target == name {
		return p.TargetInvocation
	}
	return nil
}

// Execute walks the plan, scheduling tasks once their declared deps complete.
// Returns the per-task results in topological order along with the first
// failure (if any). On failure, downstream tasks are reported as Skipped.
func (o *Orchestrator) Execute(ctx context.Context, p *Plan) ([]Result, error) {
	parallelism := o.opts.Parallelism
	if parallelism <= 0 {
		parallelism = runtime.NumCPU()
	}
	if parallelism > len(p.Order) {
		parallelism = len(p.Order)
	}
	if parallelism == 0 {
		return nil, nil
	}

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	idx := make(map[string]int, len(p.Order))
	for i, name := range p.Order {
		idx[name] = i
	}
	results := make([]Result, len(p.Order))
	depDone := make(map[string]chan struct{}, len(p.Order))
	depOK := make(map[string]*bool, len(p.Order))
	for _, name := range p.Order {
		depDone[name] = make(chan struct{})
		ok := true
		depOK[name] = &ok
	}

	sema := make(chan struct{}, parallelism)
	var ioMu sync.Mutex
	var errMu sync.Mutex
	var firstErr error

	setErr := func(err error) {
		errMu.Lock()
		if firstErr == nil {
			firstErr = err
			cancel()
		}
		errMu.Unlock()
	}

	var wg sync.WaitGroup
	for _, name := range p.Order {
		wg.Add(1)
		go func(name string) {
			defer wg.Done()
			defer close(depDone[name])
			task := p.Tasks[name]

			for _, d := range task.Deps {
				ch, ok := depDone[d]
				if !ok {
					setErr(fmt.Errorf("task %q references unknown dep %q", name, d))
					*depOK[name] = false
					return
				}
				select {
				case <-ch:
					if !*depOK[d] {
						*depOK[name] = false
						results[idx[name]] = Result{Name: name, Outcome: OutcomeSkipped}
						o.logLine(&ioMu, "[pkf] %s: skipped (dep %q failed)\n", name, d)
						return
					}
				case <-ctx.Done():
					*depOK[name] = false
					results[idx[name]] = Result{Name: name, Outcome: OutcomeSkipped}
					return
				}
			}

			select {
			case sema <- struct{}{}:
			case <-ctx.Done():
				*depOK[name] = false
				results[idx[name]] = Result{Name: name, Outcome: OutcomeSkipped}
				return
			}
			defer func() { <-sema }()

			res, err := o.executeOne(ctx, name, task, p, &ioMu)
			results[idx[name]] = res
			if err != nil {
				*depOK[name] = false
				setErr(err)
			}
		}(name)
	}
	wg.Wait()
	return results, firstErr
}

// TaskRoot returns the directory used as the resolution base for a task's
// inputs, outputs, and cwd. When `task.Workdir` is unset it equals
// `plan.Root`; otherwise the workdir path is resolved relative to it.
func TaskRoot(task *config.Task, planRoot string) string {
	if task.Workdir == nil || *task.Workdir == "" {
		return planRoot
	}
	if filepath.IsAbs(*task.Workdir) {
		return *task.Workdir
	}
	return filepath.Join(planRoot, *task.Workdir)
}

// executeOne runs a single task with cache lookup, capturing its stdout
// and stderr into buffers that are flushed atomically under `ioMu`.
func (o *Orchestrator) executeOne(ctx context.Context, name string, task *config.Task, p *Plan, ioMu *sync.Mutex) (Result, error) {
	start := time.Now()
	taskRoot := TaskRoot(task, p.Root)
	inv := invocationFor(p, name)
	key, err := ComputeKey(task, p.Defaults, taskRoot, p.ConfigHash, inv)
	if err != nil {
		return Result{Name: name}, fmt.Errorf("compute key for %q: %w", name, err)
	}
	short := hash.FormatKey(key)[:12]

	if task.Cache && o.cache != nil && !p.Refresh && o.cache.Has(key) {
		if err := o.cache.Restore(key, taskRoot); err != nil {
			return Result{Name: name, Key: key, Duration: time.Since(start)}, fmt.Errorf("cache restore for %q: %w", name, err)
		}
		o.logLine(ioMu, "[pkf] %s: hit %s\n", name, short)
		return Result{Name: name, Key: key, Outcome: OutcomeHit, Duration: time.Since(start)}, nil
	}

	// If the task declares `services`, bring them up before invoking
	// the task's cmd and tear them down once it finishes (success or
	// failure). Services run for the duration of this task only;
	// concurrent runs of other tasks are unaffected.
	var serviceCleanup func()
	if len(task.Services) > 0 {
		cleanup, err := o.startServices(ctx, name, p, ioMu)
		if err != nil {
			return Result{Name: name, Key: key, Duration: time.Since(start)}, err
		}
		serviceCleanup = cleanup
	}

	var stdoutBuf, stderrBuf bytes.Buffer
	runErr := o.runner.RunWithIO(ctx, name, task, p.Defaults, inv, &stdoutBuf, &stderrBuf)

	if serviceCleanup != nil {
		serviceCleanup()
	}

	ioMu.Lock()
	io.Copy(o.stderr, &stderrBuf)
	io.Copy(o.stdout, &stdoutBuf)
	ioMu.Unlock()

	if runErr != nil {
		if errors.Is(runErr, context.Canceled) {
			return Result{Name: name, Key: key, Outcome: OutcomeSkipped, Duration: time.Since(start)}, runErr
		}
		return Result{Name: name, Key: key, Duration: time.Since(start)}, runErr
	}

	outcome := OutcomeRan
	if !task.Cache {
		outcome = OutcomeUncached
	} else if o.cache != nil {
		if err := o.cache.Store(key, taskRoot, task.Outputs); err != nil {
			return Result{Name: name, Key: key, Duration: time.Since(start)}, fmt.Errorf("cache store for %q: %w", name, err)
		}
	}
	o.logLine(ioMu, "[pkf] %s: %s %s\n", name, outcome, short)
	return Result{Name: name, Key: key, Outcome: outcome, Duration: time.Since(start)}, nil
}

// startServices brings up every task listed in the named task's
// `services` field (recursively — a service that itself declares
// `services` has its dependencies started first). Returns a cleanup
// func that cancels the service context and waits for every supervised
// process to exit cleanly. The cleanup is idempotent.
//
// Errors are returned for: a referenced service name that isn't
// declared in the Taskfile, or a referenced task that exists but has
// `service = false`. Both are configuration mistakes worth surfacing
// before the task's `cmd` ever runs.
func (o *Orchestrator) startServices(ctx context.Context, taskName string, p *Plan, ioMu *sync.Mutex) (func(), error) {
	svcCtx, svcCancel := context.WithCancel(ctx)
	wg := &sync.WaitGroup{}
	started := make(map[string]bool)

	if err := o.startServiceTree(svcCtx, taskName, p, started, wg, ioMu); err != nil {
		svcCancel()
		wg.Wait()
		return nil, err
	}

	cleanup := func() {
		svcCancel()
		wg.Wait()
	}
	return cleanup, nil
}

func (o *Orchestrator) startServiceTree(ctx context.Context, taskName string, p *Plan, started map[string]bool, wg *sync.WaitGroup, ioMu *sync.Mutex) error {
	task := p.Tasks[taskName]
	for _, svcName := range task.Services {
		if started[svcName] {
			continue
		}
		svcTask, ok := p.Tasks[svcName]
		if !ok {
			return fmt.Errorf("task %q references service %q, which is not declared", taskName, svcName)
		}
		if !svcTask.Service {
			return fmt.Errorf("task %q lists %q in services, but %q has service=false", taskName, svcName, svcName)
		}
		started[svcName] = true

		// Reuse: when the service declares a probe and that probe
		// already succeeds, the service is up — owned by some other
		// pkf session, a `docker compose up`, the user's IDE, etc.
		// Skip the spawn so we don't port-collide, and skip recursing
		// into svcTask.services because anything the existing
		// service depends on must also be up for the probe to pass.
		if hasProbe(svcTask) {
			if err := probeReady(ctx, svcTask, p.Defaults); err == nil {
				o.logLine(ioMu, "[pkf] %s: reusing existing service %q (probe passes)\n", taskName, svcName)
				continue
			}
		}

		// Recurse before launching so deeper services in the chain are
		// up before the ones that depend on them.
		if err := o.startServiceTree(ctx, svcName, p, started, wg, ioMu); err != nil {
			return err
		}

		o.logLine(ioMu, "[pkf] %s: starting service %q\n", taskName, svcName)
		// Per-service log prefixers so a busy `pkf up dev` with db +
		// api + web doesn't interleave into an unreadable mess.
		stdoutW := newPrefixWriter(fmt.Sprintf("[%s] ", svcName), o.stdout)
		stderrW := newPrefixWriter(fmt.Sprintf("[%s] ", svcName), o.stderr)
		wg.Add(1)
		go func(name string, t *config.Task, sw, ew *prefixWriter) {
			defer wg.Done()
			defer sw.flush()
			defer ew.flush()
			_ = o.runner.RunWithIO(ctx, name, t, p.Defaults, nil, sw, ew)
		}(svcName, svcTask, stdoutW, stderrW)

		// After spawning, gate dependent work on the probe passing.
		// Without this, the next service in the loop (or the body
		// task's cmd) could race the spawned process.
		if hasProbe(svcTask) {
			if err := waitReady(ctx, svcTask, p.Defaults); err != nil {
				return fmt.Errorf("service %q did not become ready: %w", svcName, err)
			}
			o.logLine(ioMu, "[pkf] %s: service %q is ready\n", taskName, svcName)
		}
	}
	return nil
}

// StartSingleService spawns one service task and returns when it is
// "ready" — either the readiness probe passes (after polling), or
// there is no probe and the spawn returned. The caller is responsible
// for invoking the returned stop func when the service should be torn
// down; stop sends SIGTERM to the process group, waits up to the
// task's `shutdownTimeoutSeconds`, then escalates to SIGKILL.
//
// When the service declares a readiness probe and that probe already
// succeeds *before* the spawn, the existing process is reused: no
// fork, and the returned stop func is nil (the caller has nothing to
// reap on its end). Useful for `pkf up dev` already running in another
// shell.
//
// Distinct from `startServiceTree` (used by executeOne for body-task
// `services { ... }` chains): that version walks the recursion under
// a single shared cancel context and waits for the entire subtree to
// exit on cleanup. `pkf up` wants per-service control so a watch loop
// can restart only the services whose action key actually changed.
func (o *Orchestrator) StartSingleService(ctx context.Context, name string, p *Plan) (stop func(), err error) {
	t, ok := p.Tasks[name]
	if !ok {
		return nil, fmt.Errorf("service %q is not declared in the Taskfile", name)
	}
	if !t.Service {
		return nil, fmt.Errorf("task %q is not a service", name)
	}

	if hasProbe(t) {
		if err := probeReady(ctx, t, p.Defaults); err == nil {
			fmt.Fprintf(o.stderr, "[pkf] reusing existing service %q (probe passes)\n", name)
			return nil, nil
		}
	}

	svcCtx, svcCancel := context.WithCancel(ctx)
	waitCh := make(chan struct{})

	fmt.Fprintf(o.stderr, "[pkf] starting service %q\n", name)
	stdoutW := newPrefixWriter(fmt.Sprintf("[%s] ", name), o.stdout)
	stderrW := newPrefixWriter(fmt.Sprintf("[%s] ", name), o.stderr)
	go func() {
		defer close(waitCh)
		defer stdoutW.flush()
		defer stderrW.flush()
		_ = o.runner.RunWithIO(svcCtx, name, t, p.Defaults, nil, stdoutW, stderrW)
	}()

	if hasProbe(t) {
		if err := waitReady(ctx, t, p.Defaults); err != nil {
			svcCancel()
			<-waitCh
			return nil, fmt.Errorf("service %q did not become ready: %w", name, err)
		}
		fmt.Fprintf(o.stderr, "[pkf] service %q is ready\n", name)
	}

	stop = func() {
		svcCancel()
		<-waitCh
	}
	return stop, nil
}

func (o *Orchestrator) logLine(mu *sync.Mutex, format string, args ...any) {
	mu.Lock()
	defer mu.Unlock()
	fmt.Fprintf(o.stderr, format, args...)
}
