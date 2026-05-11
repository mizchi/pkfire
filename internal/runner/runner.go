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
	"time"

	"github.com/mizchi/pkfire/internal/config"
)

// defaultShutdownTimeout is the SIGTERM-to-SIGKILL grace period when a
// task didn't declare one. Mirrors the schema default.
const defaultShutdownTimeout = 5 * time.Second

// Options controls runner behavior.
type Options struct {
	Stdout  io.Writer
	Stderr  io.Writer
	Workdir string // base directory for relative `task.Workdir`
	// Quiet suppresses the diagnostic `[pkf] <task>: <cmd>` header
	// the runner emits before invoking `cmd`. Failures and the task
	// process's own stdout/stderr still pass through unmodified.
	Quiet bool
	// Profile is the run-wide --profile=<name> value. Injected as
	// $PKF_PROFILE into every cmd's env so tasks can branch on it.
	// Action-key folding happens at the orchestrator level (via
	// Plan.Profile); the runner just propagates the env var.
	Profile string
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

// Invocation carries the run-time inputs that are not on the schema:
// resolved typed params and positional tail args. Both are folded into
// the action key when `task.Cache` is true so a param-driven task caches
// per-value.
type Invocation struct {
	// Params maps the uppercased param name to its resolved value (CLI
	// value or schema default). Passed to `cmd` as env vars.
	Params map[string]string
	// Args are positional args from `pkf run task -- a b c`. Forwarded
	// to the shell so `cmd` sees `$1`, `$@`, etc.
	Args []string
}

// Run executes a single task using the runner's default Stdout/Stderr.
func (r *Runner) Run(ctx context.Context, name string, task *config.Task, defaults *config.Defaults) error {
	return r.RunWithIO(ctx, name, task, defaults, nil, r.opts.Stdout, r.opts.Stderr)
}

// RunWithIO is like Run but redirects the task's stdout/stderr to the given
// writers (the diagnostic "[pkf] ... " prefix line goes to `stderr`).
// Used by the parallel orchestrator to capture each task's output into a
// buffer and flush it under a lock — that keeps log output from interleaving.
//
// `inv` is the per-invocation context (resolved params + tail args). nil
// is equivalent to an empty Invocation, used for non-target tasks where
// arg/param passthrough doesn't apply.
func (r *Runner) RunWithIO(ctx context.Context, name string, task *config.Task, defaults *config.Defaults, inv *Invocation, stdout, stderr io.Writer) error {
	shell := task.Shell
	if shell == "" {
		if defaults != nil && defaults.Shell != "" {
			shell = defaults.Shell
		} else {
			shell = "bash"
		}
	}

	// `bash -c '<script>' arg0 arg1 arg2 ...` makes arg1, arg2, ... show
	// up as `$1`, `$2`, ..., and `$@` in the script. We use "pkf" as the
	// `$0` slot so error messages from the shell label the source
	// usefully.
	cmdArgs := []string{"-c", task.Cmd, "pkf"}
	if inv != nil && len(inv.Args) > 0 {
		if !task.AcceptsArgs {
			return fmt.Errorf("task %q does not accept positional args (set acceptsArgs = true)", name)
		}
		cmdArgs = append(cmdArgs, inv.Args...)
	}
	cmd := exec.Command(shell, cmdArgs...)
	cmd.Stdout = stdout
	cmd.Stderr = stderr

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

	// Inject pkfire-derived context as env vars so the cmd can
	// reference its own task identity without hard-coding paths.
	// Done AFTER cmd.Dir is computed so we can leak the resolved
	// absolute path. These vars are NOT part of the action key —
	// they're constants of the task definition (name, workdir),
	// already reflected in the digest via cmd/env/inputs.
	pkfEnv := []string{
		"PKF_TASK_NAME=" + name,
		"PKF_TASK_ROOT=" + cmd.Dir,
		"PKF_WORKSPACE_ROOT=" + r.opts.Workdir,
	}
	if r.opts.Profile != "" {
		pkfEnv = append(pkfEnv, "PKF_PROFILE="+r.opts.Profile)
	}
	cmd.Env = append(mergeEnv(defaults, task, inv), pkfEnv...)

	// Make the child a process-group leader so cancellation reaches the
	// whole subtree. exec.CommandContext only kills the direct child,
	// which leaks grandchildren (e.g. `bash -c "node server.js"` would
	// reap bash but leave node holding ports). See sysattr_unix.go.
	setProcessGroup(cmd)

	if !r.opts.Quiet {
		fmt.Fprintf(stderr, "[pkf] %s: %s\n", name, task.Cmd)
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("task %q failed to start: %w", name, err)
	}

	waitCh := make(chan error, 1)
	go func() { waitCh <- cmd.Wait() }()

	grace := defaultShutdownTimeout
	if task.ShutdownTimeoutSeconds > 0 {
		grace = time.Duration(task.ShutdownTimeoutSeconds) * time.Second
	}

	select {
	case err := <-waitCh:
		if err != nil {
			return fmt.Errorf("task %q failed: %w", name, err)
		}
		return nil
	case <-ctx.Done():
		// Graceful: SIGTERM the whole process group, give it `grace`
		// seconds to clean up, then SIGKILL if it's still alive.
		_ = terminateProcessGroup(cmd.Process.Pid)
		select {
		case <-waitCh:
			return ctx.Err()
		case <-time.After(grace):
			_ = killProcessGroup(cmd.Process.Pid)
			<-waitCh
			return ctx.Err()
		}
	}
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

// hermeticEnvKeys is the small allowlist used when a task sets
// `inheritEnv = false`. Just enough for compilers on PATH, locale-aware
// utilities, and temp-dir resolution — but no SSH agent, no editor
// state, no developer-specific tokens.
var hermeticEnvKeys = []string{
	"PATH", "HOME", "USER", "LOGNAME", "SHELL", "TERM", "TMPDIR",
	"LANG", "LC_ALL", "LC_CTYPE", "TZ",
}

// mergeEnv merges environment for `cmd`:
//
//   - When `task.InheritEnv` is true (the default), every var from
//     `os.Environ()` is included so things like SSH_AUTH_SOCK,
//     GPG_AGENT_INFO, and the user's locale shells through without
//     ceremony.
//   - When false, only the small `hermeticEnvKeys` allowlist passes
//     through — the pre-0.4 behavior, kept for tasks that need
//     reproducibility-by-isolation.
//
// In both cases `defaults.Env` overlays the inherited values, `task.Env`
// overlays `defaults.Env`, and `inv.Params` (each uppercased) overlays
// `task.Env`. *Only the schema-declared layers (defaults, task, params)
// contribute to the action key* — host env is intentionally not hashed.
func mergeEnv(defaults *config.Defaults, task *config.Task, inv *Invocation) []string {
	merged := make(map[string]string)
	if task.InheritEnv {
		for _, kv := range os.Environ() {
			if i := stringIndex(kv, '='); i >= 0 {
				merged[kv[:i]] = kv[i+1:]
			}
		}
	} else {
		for _, k := range hermeticEnvKeys {
			if v, ok := os.LookupEnv(k); ok {
				merged[k] = v
			}
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
	if inv != nil {
		for k, v := range inv.Params {
			merged[k] = v
		}
	}
	out := make([]string, 0, len(merged))
	for k, v := range merged {
		out = append(out, k+"="+v)
	}
	sort.Strings(out)
	return out
}

func stringIndex(s string, b byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == b {
			return i
		}
	}
	return -1
}
