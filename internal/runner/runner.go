// Package runner executes resolved tasks via the system shell.
//
// Phase 1 only does serial execution with no caching: deps -> dependents,
// each task runs as `<shell> -c <cmd>` with merged env. Caching, parallelism,
// and output capture come in later phases.
package runner

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"

	"github.com/mizchi/pkfire/internal/config"
)

// Options controls runner behavior.
type Options struct {
	Stdout  io.Writer
	Stderr  io.Writer
	Workdir string // base directory for relative `task.Workdir`
}

// Runner is a stateless executor; it is parameterized by Options.
type Runner struct {
	opts Options
}

// New returns a Runner with the given options. Defaults are filled in:
// Stdout/Stderr fall back to os.Stdout/os.Stderr; Workdir to ".".
func New(opts Options) *Runner {
	if opts.Stdout == nil {
		opts.Stdout = os.Stdout
	}
	if opts.Stderr == nil {
		opts.Stderr = os.Stderr
	}
	if opts.Workdir == "" {
		opts.Workdir = "."
	}
	return &Runner{opts: opts}
}

// Run executes a single task using the runner's default Stdout/Stderr.
func (r *Runner) Run(ctx context.Context, name string, task *config.Task, defaults *config.Defaults) error {
	return r.RunWithIO(ctx, name, task, defaults, r.opts.Stdout, r.opts.Stderr)
}

// RunWithIO is like Run but redirects the task's stdout/stderr to the given
// writers (the diagnostic "[pkf] ... " prefix line goes to `stderr`).
// Used by the parallel orchestrator to capture each task's output into a
// buffer and flush it under a lock — that keeps log output from interleaving.
func (r *Runner) RunWithIO(ctx context.Context, name string, task *config.Task, defaults *config.Defaults, stdout, stderr io.Writer) error {
	shell := task.Shell
	if shell == "" {
		if defaults != nil && defaults.Shell != "" {
			shell = defaults.Shell
		} else {
			shell = "bash"
		}
	}

	cmd := exec.CommandContext(ctx, shell, "-c", task.Cmd)
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	cmd.Env = mergeEnv(defaults, task)

	// `task.Workdir` is interpreted relative to the runner's base Workdir
	// (typically the directory holding Taskfile.pkl). This matches how
	// orchestrator.TaskRoot resolves inputs/outputs/cache, so `cmd.Dir`,
	// hashing, and cache restoration all see the same root.
	cmd.Dir = r.opts.Workdir
	if task.Workdir != nil && *task.Workdir != "" {
		if filepath.IsAbs(*task.Workdir) {
			cmd.Dir = *task.Workdir
		} else {
			cmd.Dir = filepath.Join(r.opts.Workdir, *task.Workdir)
		}
	}

	fmt.Fprintf(stderr, "[pkf] %s: %s\n", name, task.Cmd)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("task %q failed: %w", name, err)
	}
	return nil
}

// RunAll executes the given task names in order. Stops on the first error.
func (r *Runner) RunAll(ctx context.Context, order []string, tasks map[string]*config.Task, defaults *config.Defaults) error {
	for _, name := range order {
		t, ok := tasks[name]
		if !ok {
			return fmt.Errorf("task %q not found", name)
		}
		if err := r.Run(ctx, name, t, defaults); err != nil {
			return err
		}
	}
	return nil
}

// inheritedEnvKeys are passed through from the calling shell so common
// tools (compilers on PATH, locale-sensitive utilities, temp dirs) can
// run. They deliberately do *not* contribute to the action key — that is
// declared explicitly via `task.tools` so action keys stay reproducible
// across machines with different PATHs.
var inheritedEnvKeys = []string{
	"PATH", "HOME", "USER", "LOGNAME", "SHELL", "TERM", "TMPDIR",
	"LANG", "LC_ALL", "LC_CTYPE", "TZ",
}

// mergeEnv merges (inherited system env) ← defaults.Env ← task.Env into a
// deterministic, sorted "KEY=VALUE" slice. Later entries override earlier.
func mergeEnv(defaults *config.Defaults, task *config.Task) []string {
	merged := make(map[string]string)
	for _, k := range inheritedEnvKeys {
		if v, ok := os.LookupEnv(k); ok {
			merged[k] = v
		}
	}
	if defaults != nil {
		for k, v := range defaults.Env {
			merged[k] = v
		}
	}
	for k, v := range task.Env {
		merged[k] = v
	}
	out := make([]string, 0, len(merged))
	for k, v := range merged {
		out = append(out, k+"="+v)
	}
	sort.Strings(out)
	return out
}
