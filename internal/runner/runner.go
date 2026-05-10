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

// Run executes a single task. Env is built from `defaults.Env` overlaid with
// `task.Env`; the ambient process env is *not* inherited so that future
// hashing has a stable view of inputs.
func (r *Runner) Run(ctx context.Context, name string, task *config.Task, defaults *config.Defaults) error {
	shell := task.Shell
	if shell == "" {
		if defaults != nil && defaults.Shell != "" {
			shell = defaults.Shell
		} else {
			shell = "bash"
		}
	}

	cmd := exec.CommandContext(ctx, shell, "-c", task.Cmd)
	cmd.Stdout = r.opts.Stdout
	cmd.Stderr = r.opts.Stderr
	cmd.Env = mergeEnv(defaults, task)

	cmd.Dir = r.opts.Workdir
	if task.Workdir != nil && *task.Workdir != "" {
		cmd.Dir = *task.Workdir
	}

	fmt.Fprintf(r.opts.Stderr, "[pkf] %s: %s\n", name, task.Cmd)
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

// mergeEnv merges defaults.Env and task.Env into a deterministic, sorted
// "KEY=VALUE" slice. Task entries override default entries.
func mergeEnv(defaults *config.Defaults, task *config.Task) []string {
	merged := make(map[string]string)
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
