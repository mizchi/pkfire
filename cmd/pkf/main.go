// Command pkf is the pkfire CLI: a typed task runner that loads `Taskfile.pkl`
// and executes tasks with Bazel-style content-addressed caching.
package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/bmatcuk/doublestar/v4"
	"github.com/mizchi/pkfire/internal/cache"
	"github.com/mizchi/pkfire/internal/config"
	"github.com/mizchi/pkfire/internal/graph"
	"github.com/mizchi/pkfire/internal/hash"
	"github.com/mizchi/pkfire/internal/orchestrator"
	"github.com/mizchi/pkfire/internal/runner"
	"github.com/mizchi/pkfire/internal/watcher"
)

// runFlagSpec captures the shape of `pkf run`'s built-in flags so we can
// split the command line into [global flags] [task name] [task args]
// without relying on stdlib `flag`'s default "stop at first positional"
// behavior — needed because `--<param>=<value>` and `-- <args>` appear
// AFTER the task name.
var runGlobalValueFlags = map[string]bool{
	"f": true, "file": true, "j": true, "jobs": true,
}
var runGlobalBoolFlags = map[string]bool{
	"watch": true, "dry-run": true, "print-hash": true, "no-cache": true, "refresh": true, "quiet": true, "timing": true, "keep-going": true,
}

// version is overridden at link time via `-ldflags "-X main.version=…"`.
var version = "dev"

func main() {
	if err := run(os.Args[1:], os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "pkf:", err)
		os.Exit(1)
	}
}

func run(args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 {
		usage(stdout)
		return nil
	}
	switch args[0] {
	case "version", "--version", "-v":
		fmt.Fprintln(stdout, version)
		return nil
	case "help", "--help", "-h":
		usage(stdout)
		return nil
	case "init":
		return cmdInit(args[1:], stdout, stderr)
	case "list":
		return cmdList(args[1:], stdout, stderr)
	case "graph":
		return cmdGraph(args[1:], stdout, stderr)
	case "run":
		return cmdRun(args[1:], stdout, stderr)
	case "up":
		return cmdUp(args[1:], stdout, stderr)
	case "doctor":
		return cmdDoctor(args[1:], stdout, stderr)
	case "format":
		return cmdFormat(args[1:], stdout, stderr)
	case "hooks":
		return cmdHooks(args[1:], stdout, stderr)
	case "affected":
		return cmdAffected(args[1:], stdout, stderr)
	case "clean":
		return cmdClean(args[1:], stdout, stderr)
	case "cache":
		return cmdCache(args[1:], stdout, stderr)
	case "completion":
		return cmdCompletion(args[1:], stdout, stderr)
	case "explain":
		return cmdExplain(args[1:], stdout, stderr)
	default:
		usage(stderr)
		return fmt.Errorf("unknown command %q", args[0])
	}
}

func usage(w io.Writer) {
	fmt.Fprint(w, `pkf — pkfire task runner

usage:
  pkf <command> [args]

commands:
  init [-f FILE] [--force]              write a starter Taskfile.pkl
  run [-f FILE] [-j N] [--watch] [--dry-run] [--print-hash] [--no-cache|--refresh] [--timing] [task...]
                                        run one or more tasks (no arg = the default task); multi-target runs the union
  up  [-f FILE] [-j N] [--watch] <task> start every service in <task>'s subgraph;
                                        Ctrl+C releases the whole process tree
  list [-f FILE] [-v] [--json]          list declared tasks (-v: cmd/deps; --json: machine-readable)
  graph [-f FILE] [--format FMT] [--target TASK]
                                        emit DAG (formats: dot, mermaid)
  doctor [-f FILE]                      diagnose pkfire setup (pkl/cache/remote/taskfile)
  format [-f FILE] [--check] [PATH...]  pkl format -w (no PATH = the Taskfile's directory)
  hooks <install|uninstall|list> [-f FILE] [--force]
                                        manage .git/hooks shims that delegate to pkf run
  affected [--since=<ref>] [--dry-run] [task...]
                                        run only tasks whose inputs changed since <ref> (and their dependents)
  clean [-f FILE] [--dry-run] [task...] remove tasks' declared outputs (no arg = every task with outputs)
  cache <stats|prune|rm|clear> [args]   inspect / clean the local CAS at $PKFIRE_CACHE_DIR
  completion <bash|zsh|fish>            emit a shell-completion script to stdout
  explain <task>                        dump every input to the task's action key (for cache-miss debugging)
  version                               print pkf version
  help                                  show this message

flags:
  -f, --file FILE        path to Taskfile.pkl (default: ./Taskfile.pkl)
  -j, --jobs N           max concurrent tasks (default: NumCPU)
      --watch            re-run on input changes (Ctrl+C to stop)
      --dry-run          print the execution plan and exit (no exec, no cache)
      --print-hash       print action keys for the target subgraph and exit
      --no-cache         disable cache lookup and store for this run
      --refresh          skip cache lookup but still store results (re-baseline)
      --json             (list only) machine-readable output
  -v, --verbose          (list only) include cmd preview and deps

cache directory:
  $PKFIRE_CACHE_DIR if set, otherwise $XDG_CACHE_HOME/pkfire (~/.cache/pkfire).
`)
}

func newFileFlag(fs *flag.FlagSet) *string {
	file := fs.String("f", "Taskfile.pkl", "path to Taskfile.pkl")
	fs.StringVar(file, "file", "Taskfile.pkl", "path to Taskfile.pkl")
	return file
}

// resolveFile turns the value of `-f` / `--file` into an absolute path.
// When the user did not specify the flag, this walks up from the current
// working directory looking for `Taskfile.pkl` in each ancestor — the
// same git/cargo discovery rule that lets `pkf run lint` work from any
// nested directory in a project. An explicit `-f` is taken at face value
// (filepath.Abs only).
func resolveFile(fs *flag.FlagSet, file string) (string, error) {
	if fileFlagWasSet(fs) {
		return filepath.Abs(file)
	}
	cwd, err := os.Getwd()
	if err != nil {
		return "", err
	}
	return walkUp(cwd, file), nil
}

func fileFlagWasSet(fs *flag.FlagSet) bool {
	set := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "f" || f.Name == "file" {
			set = true
		}
	})
	return set
}

// walkUp returns the first ancestor (or `start` itself) that contains a
// regular file named `name`. If none exists up to the filesystem root,
// it falls back to the path joined against `start`, which the caller
// will subsequently fail to load with a clear "no such file" error.
func walkUp(start, name string) string {
	dir := start
	for {
		candidate := filepath.Join(dir, name)
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return filepath.Join(start, name)
		}
		dir = parent
	}
}

// initSkeleton renders the starter Taskfile `pkf init` writes. The
// amends URI tracks the running binary's version: a release-built
// binary (linked with `-X main.version=<ver>`) writes
// `package://…/pkfire@<ver>#/Taskfile.pkl`, while a dev binary
// (`version == "dev"`) writes the main-tracking HTTPS URL so users
// hacking on this repo's HEAD always get a resolvable amends.
func initSkeleton() string {
	return fmt.Sprintf(`/// Generated by `+"`pkf init`"+`. See https://github.com/mizchi/pkfire.
///
/// Author each task as a `+"`Task`"+` instance with a unique `+"`name`"+`, then
/// list it in the module-level `+"`tasks`"+`. Refer to other tasks with their
/// local binding (e.g. `+"`deps { build }`"+`) — typos are caught by Pkl
/// at evaluation time, before the runner ever starts.
amends %q

local hello = new Task {
  name = "hello"
  description = "Smoke task — replace with your own"
  cmd = "echo hello from pkfire"
}

tasks { hello }
`, schemaAmendsURI())
}

// schemaAmendsURI is the `amends` line `pkf init` writes. Released
// binaries pin to their own version's Pkl package; dev binaries fall
// back to the main HTTPS URL.
func schemaAmendsURI() string {
	if version == "dev" || version == "" {
		return "https://raw.githubusercontent.com/mizchi/pkfire/main/pkl/Taskfile.pkl"
	}
	return fmt.Sprintf("package://pkg.pkl-lang.org/github.com/mizchi/pkfire/pkfire@%s#/Taskfile.pkl", version)
}

func cmdInit(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("pkf init", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	file := newFileFlag(fs)
	force := fs.Bool("force", false, "overwrite an existing file")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if len(fs.Args()) > 0 {
		return fmt.Errorf("init takes no positional args, got %v", fs.Args())
	}
	if !*force {
		if _, err := os.Stat(*file); err == nil {
			return fmt.Errorf("%s already exists (use --force to overwrite)", *file)
		}
	}
	if err := os.WriteFile(*file, []byte(initSkeleton()), 0o644); err != nil {
		return err
	}
	fmt.Fprintf(stderr, "wrote %s\n", *file)
	fmt.Fprintf(stderr, "  next: pkf list      # see declared tasks\n")
	fmt.Fprintf(stderr, "        pkf run hello # smoke the generated example\n")
	return nil
}

func cmdList(args []string, stdout, _ io.Writer) error {
	fs := flag.NewFlagSet("pkf list", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	file := newFileFlag(fs)
	verbose := fs.Bool("v", false, "show cmd preview and deps")
	fs.BoolVar(verbose, "verbose", false, "show cmd preview and deps")
	asJSON := fs.Bool("json", false, "emit machine-readable output")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if len(fs.Args()) > 0 {
		return fmt.Errorf("list takes no positional args, got %v", fs.Args())
	}
	if *asJSON && *verbose {
		return fmt.Errorf("--json subsumes -v (use one or the other)")
	}
	abs, err := resolveFile(fs, *file)
	if err != nil {
		return err
	}
	tf, err := config.Load(context.Background(), abs)
	if err != nil {
		return err
	}
	names := make([]string, 0, len(tf.Tasks))
	for n := range tf.Tasks {
		names = append(names, n)
	}
	sort.Strings(names)
	if *asJSON {
		return printListJSON(stdout, tf, names)
	}
	if !*verbose {
		for _, n := range names {
			t := tf.Tasks[n]
			desc := ""
			if t.Description != nil {
				desc = "  — " + *t.Description
			}
			fmt.Fprintf(stdout, "%s%s\n", n, desc)
		}
		return nil
	}
	for i, n := range names {
		if i > 0 {
			fmt.Fprintln(stdout)
		}
		t := tf.Tasks[n]
		fmt.Fprintf(stdout, "%s\n", n)
		if t.Description != nil {
			fmt.Fprintf(stdout, "  desc: %s\n", *t.Description)
		}
		fmt.Fprintf(stdout, "  cmd:  %s\n", t.Cmd)
		if len(t.Deps) > 0 {
			fmt.Fprintf(stdout, "  deps: %s\n", strings.Join(t.Deps, ", "))
		}
		if !t.Cache {
			fmt.Fprintf(stdout, "  cache: disabled\n")
		}
	}
	return nil
}

// listParamJSON mirrors config.Param for the --json output. Kept as
// its own type so we don't leak Pkl-internal field tags (`pkl:"..."`)
// into the JSON contract.
type listParamJSON struct {
	Name        string   `json:"name"`
	Type        string   `json:"type"`
	Choices     []string `json:"choices,omitempty"`
	Default     *string  `json:"default,omitempty"`
	Description string   `json:"description,omitempty"`
}

type listTaskJSON struct {
	Name        string          `json:"name"`
	Description string          `json:"description,omitempty"`
	Cmd         string          `json:"cmd"`
	Shell       string          `json:"shell,omitempty"`
	Deps        []string        `json:"deps,omitempty"`
	Inputs      []string        `json:"inputs,omitempty"`
	Outputs     []string        `json:"outputs,omitempty"`
	Workdir     string          `json:"workdir,omitempty"`
	Cache       bool            `json:"cache"`
	Service     bool            `json:"service"`
	Services    []string        `json:"services,omitempty"`
	AcceptsArgs bool            `json:"acceptsArgs"`
	InheritEnv  bool            `json:"inheritEnv"`
	Params      []listParamJSON `json:"params,omitempty"`
}

type listJSON struct {
	Tasks []listTaskJSON `json:"tasks"`
}

func printListJSON(stdout io.Writer, tf *config.Taskfile, names []string) error {
	out := listJSON{Tasks: make([]listTaskJSON, 0, len(names))}
	for _, n := range names {
		t := tf.Tasks[n]
		entry := listTaskJSON{
			Name:        n,
			Cmd:         t.Cmd,
			Shell:       t.Shell,
			Deps:        t.Deps,
			Inputs:      t.Inputs,
			Outputs:     t.Outputs,
			Cache:       t.Cache,
			Service:     t.Service,
			Services:    t.Services,
			AcceptsArgs: t.AcceptsArgs,
			InheritEnv:  t.InheritEnv,
		}
		if t.Description != nil {
			entry.Description = *t.Description
		}
		if t.Workdir != nil {
			entry.Workdir = *t.Workdir
		}
		for _, p := range t.Params {
			entry.Params = append(entry.Params, listParamJSON{
				Name:    p.Name,
				Type:    p.Type,
				Choices: p.Choices,
				Default: p.Default,
				Description: func() string {
					if p.Description != nil {
						return *p.Description
					}
					return ""
				}(),
			})
		}
		out.Tasks = append(out.Tasks, entry)
	}
	enc := json.NewEncoder(stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(out)
}

func cmdGraph(args []string, stdout, _ io.Writer) error {
	fs := flag.NewFlagSet("pkf graph", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	file := newFileFlag(fs)
	format := fs.String("format", "dot", "output format: dot or mermaid")
	target := fs.String("target", "", "render only the subgraph rooted at this task")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if len(fs.Args()) > 0 {
		return fmt.Errorf("graph takes no positional args, got %v", fs.Args())
	}
	abs, err := resolveFile(fs, *file)
	if err != nil {
		return err
	}
	tf, err := config.Load(context.Background(), abs)
	if err != nil {
		return err
	}
	g, err := buildGraph(tf)
	if err != nil {
		return err
	}

	var nodes []string
	if *target != "" {
		if !g.Has(*target) {
			return fmt.Errorf("unknown task: %q", *target)
		}
		nodes, err = g.Subgraph(*target)
		if err != nil {
			return err
		}
	} else {
		nodes = g.Names()
	}
	keep := make(map[string]bool, len(nodes))
	for _, n := range nodes {
		keep[n] = true
	}

	switch *format {
	case "dot":
		return writeDOT(stdout, tf, nodes, keep)
	case "mermaid":
		return writeMermaid(stdout, tf, nodes, keep)
	default:
		return fmt.Errorf("unknown format %q (want: dot, mermaid)", *format)
	}
}

func writeDOT(w io.Writer, tf *config.Taskfile, nodes []string, keep map[string]bool) error {
	fmt.Fprintln(w, "digraph pkfire {")
	fmt.Fprintln(w, "  rankdir=LR;")
	fmt.Fprintln(w, `  node [shape=box, style="rounded,filled", fillcolor="#f8f8ff"];`)
	for _, n := range nodes {
		t := tf.Tasks[n]
		label := n
		if t.Description != nil {
			label = fmt.Sprintf("%s\\n%s", n, *t.Description)
		}
		fmt.Fprintf(w, "  %q [label=%q];\n", n, label)
	}
	for _, n := range nodes {
		for _, d := range tf.Tasks[n].Deps {
			if keep[d] {
				fmt.Fprintf(w, "  %q -> %q;\n", d, n)
			}
		}
	}
	fmt.Fprintln(w, "}")
	return nil
}

// mermaidIDReplacer turns task names into Mermaid-safe node IDs. The set
// of unsafe characters is conservative — only [A-Za-z0-9_] is accepted by
// the renderer in id positions.
var mermaidIDReplacer = strings.NewReplacer(
	":", "_", "-", "_", "/", "_", ".", "_", " ", "_",
)

func mermaidID(s string) string { return mermaidIDReplacer.Replace(s) }

func writeMermaid(w io.Writer, tf *config.Taskfile, nodes []string, keep map[string]bool) error {
	fmt.Fprintln(w, "flowchart LR")
	for _, n := range nodes {
		fmt.Fprintf(w, "  %s[%q]\n", mermaidID(n), n)
	}
	for _, n := range nodes {
		for _, d := range tf.Tasks[n].Deps {
			if keep[d] {
				fmt.Fprintf(w, "  %s --> %s\n", mermaidID(d), mermaidID(n))
			}
		}
	}
	return nil
}

func cmdRun(args []string, stdout, stderr io.Writer) error {
	globalArgs, targets, postArgs, err := splitRunArgs(args)
	if err != nil {
		return err
	}

	fs := flag.NewFlagSet("pkf run", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	file := newFileFlag(fs)
	printHash := fs.Bool("print-hash", false, "print action keys and exit")
	dryRun := fs.Bool("dry-run", false, "print the execution plan and exit")
	noCache := fs.Bool("no-cache", false, "disable cache lookup AND store for this run")
	refresh := fs.Bool("refresh", false, "skip cache lookup but still store results (re-baseline)")
	watch := fs.Bool("watch", false, "re-run on input changes")
	timing := fs.Bool("timing", false, "print per-task duration at end of run")
	quiet := fs.Bool("quiet", false, "suppress per-task log lines (errors + summary still print)")
	keepGoing := fs.Bool("keep-going", false, "don't stop on first failure; run independent subgraphs to completion")
	jobs := fs.Int("j", 0, "max concurrent tasks (default: NumCPU)")
	fs.IntVar(jobs, "jobs", 0, "max concurrent tasks (default: NumCPU)")
	if err := fs.Parse(globalArgs); err != nil {
		return err
	}
	if len(fs.Args()) != 0 {
		return fmt.Errorf("unexpected args before task name: %v", fs.Args())
	}

	abs, err := resolveFile(fs, *file)
	if err != nil {
		return err
	}
	ctx := context.Background()
	tf, err := config.Load(ctx, abs)
	if err != nil {
		return err
	}

	// Fall back to the `default` task when no target was given. Errors
	// loudly when neither a target nor a default exists — silent
	// behavior here would be confusing for users typing `pkf run` to
	// see what runs.
	if len(targets) == 0 {
		if _, ok := tf.Tasks["default"]; ok {
			targets = []string{"default"}
		} else {
			return fmt.Errorf("no task specified and no `default` task declared; try `pkf list` to see available tasks")
		}
	}

	// Expand glob-shaped targets (`pkf run 'test:*'`) against the
	// task list. Exact names pass through. After expansion we may
	// have more than one target, which then trips the multi-target
	// / param mutual-exclusion just like an explicit `pkf run a b`.
	if expanded := expandPatterns(targets, tf.Tasks); expanded != nil {
		targets = expanded
	}

	// Multiple targets are unambiguous for non-overlay flags, but
	// `--param=value` and `-- tail args` can't be safely routed to two
	// different tasks. Reject the combination early.
	if len(targets) > 1 && len(postArgs) > 0 {
		return fmt.Errorf("multi-target run cannot accept --param / -- args (which target would they apply to?)")
	}

	g, err := buildGraph(tf)
	if err != nil {
		return err
	}
	for _, t := range targets {
		if !g.Has(t) {
			return fmt.Errorf("unknown task: %q (no glob pattern matched)", t)
		}
	}
	order, err := unionSubgraph(g, targets)
	if err != nil {
		return err
	}

	// Invocation overlay only meaningful for a single target.
	var inv *runner.Invocation
	var invTarget string
	if len(targets) == 1 {
		invTarget = targets[0]
		inv, err = resolveInvocation(tf.Tasks[invTarget], invTarget, postArgs)
		if err != nil {
			return err
		}
	}

	root := filepath.Dir(abs)
	switch {
	case *dryRun && *printHash:
		return fmt.Errorf("--dry-run and --print-hash are mutually exclusive")
	case *noCache && *refresh:
		return fmt.Errorf("--no-cache and --refresh are mutually exclusive (--refresh stores; --no-cache does not)")
	case *watch && (*dryRun || *printHash):
		return fmt.Errorf("--watch is incompatible with --dry-run / --print-hash")
	case *dryRun:
		return printDryRun(stdout, root, tf, order, invTarget, inv, *noCache || *refresh)
	case *printHash:
		return printHashes(stdout, root, tf, order, invTarget, inv)
	}

	var backend cache.Backend
	if !*noCache {
		dir, err := cache.DefaultDir()
		if err != nil {
			return fmt.Errorf("resolve cache dir: %w", err)
		}
		local := cache.New(dir)
		if remoteURL := os.Getenv("PKFIRE_REMOTE_CACHE"); remoteURL != "" {
			remote := cache.NewRemote(remoteURL, os.Getenv("PKFIRE_REMOTE_TOKEN"))
			backend = cache.NewLayered(local, remote)
		} else {
			backend = local
		}
	}
	r := runner.New(runner.Options{Workdir: root, Quiet: *quiet})
	orch := orchestrator.New(backend, r, stdout, stderr, orchestrator.Options{
		Parallelism: *jobs,
		Quiet:       *quiet,
		KeepGoing:   *keepGoing,
	})
	plan := &orchestrator.Plan{
		Order:            order,
		Tasks:            tf.Tasks,
		Defaults:         tf.Defaults,
		Root:             root,
		ConfigHash:       hash.HashBytes(tf.Canonical),
		Target:           invTarget,
		TargetInvocation: inv,
		Refresh:          *refresh,
	}
	if *watch {
		// Watch mode is still single-target only — its restart
		// semantics revolve around the named target's subgraph.
		if len(targets) != 1 {
			return fmt.Errorf("--watch requires exactly one task")
		}
		return runWatch(ctx, abs, root, targets[0], orch, plan, stderr)
	}
	start := time.Now()
	results, err := orch.Execute(ctx, plan)
	wall := time.Since(start)
	printRunSummary(stderr, results, wall, *timing)
	return err
}

// unionSubgraph computes the topological order over the union of
// every target's subgraph. The graph package already sorts each
// subgraph, so for multi-target we walk in declared target order
// and dedupe by name — that preserves "anything reachable from
// target[i] lands before target[i+1] unless already scheduled".
func unionSubgraph(g *graph.Graph, targets []string) ([]string, error) {
	seen := make(map[string]bool)
	var out []string
	for _, t := range targets {
		sub, err := g.Subgraph(t)
		if err != nil {
			return nil, err
		}
		for _, n := range sub {
			if !seen[n] {
				seen[n] = true
				out = append(out, n)
			}
		}
	}
	return out, nil
}

// printRunSummary emits a single line summarizing outcomes after a
// non-watch `pkf run`. With `--timing`, also prints per-task durations
// in descending order. Goes to stderr so structured stdout consumers
// (like JSON output paths) aren't polluted.
func printRunSummary(stderr io.Writer, results []orchestrator.Result, wall time.Duration, timing bool) {
	if len(results) == 0 {
		return
	}
	var hits, ran, uncached, skipped int
	var taskWall time.Duration
	for _, r := range results {
		taskWall += r.Duration
		switch r.Outcome {
		case orchestrator.OutcomeHit:
			hits++
		case orchestrator.OutcomeRan:
			ran++
		case orchestrator.OutcomeUncached:
			uncached++
		case orchestrator.OutcomeSkipped:
			skipped++
		}
	}
	fmt.Fprintf(stderr, "[pkf] done: %d task%s · %d hit · %d ran · %d uncached",
		len(results), plural(len(results)), hits, ran+uncached, uncached)
	if skipped > 0 {
		fmt.Fprintf(stderr, " · %d skipped", skipped)
	}
	fmt.Fprintf(stderr, " (%s wall", wall.Round(time.Millisecond))
	if taskWall > 0 && taskWall > wall {
		fmt.Fprintf(stderr, ", %s CPU", taskWall.Round(time.Millisecond))
	}
	fmt.Fprintln(stderr, ")")

	if timing {
		sorted := append([]orchestrator.Result(nil), results...)
		sort.Slice(sorted, func(i, j int) bool { return sorted[i].Duration > sorted[j].Duration })
		fmt.Fprintln(stderr, "[pkf] timing:")
		for _, r := range sorted {
			if r.Duration == 0 {
				continue
			}
			fmt.Fprintf(stderr, "  %8s  %s\n", r.Duration.Round(time.Millisecond), r.Name)
		}
	}
}

// splitRunArgs walks args splitting at the first non-global-flag token —
// that token is the task name. Returns (globalFlags, taskName, taskArgs).
// taskArgs contains everything after the task name (param flags, "--",
// tail args).
//
// We can't use stdlib `flag.Parse` for this because stdlib stops at the
// first positional, which would prevent `pkf run task --watch` from
// parsing `--watch` as a global. Hand-rolling lets us keep the
// pre-0.4 flag order (`pkf run -f x.pkl mytask`) while also accepting
// the new shape (`pkf run mytask --param=val -- tail`).
// splitRunArgs walks args splitting at the first task name. Returns
// (globalFlags, taskNames, taskArgs). Multiple consecutive non-flag
// positionals all become task names — `pkf run a b c` runs the
// topological union of a, b, c. After the last task name, any
// flag-shaped tokens (and `--`/tail args) are task-scoped.
func splitRunArgs(args []string) (globalArgs []string, taskNames []string, taskArgs []string, err error) {
	i := 0
	for i < len(args) {
		a := args[i]
		if !strings.HasPrefix(a, "-") {
			globalArgs = args[:i]
			// Collect every consecutive non-flag positional as a target.
			for i < len(args) && !strings.HasPrefix(args[i], "-") {
				taskNames = append(taskNames, args[i])
				i++
			}
			taskArgs = args[i:]
			return
		}
		// `--` before a task name is unusual; preserve it as a global
		// token (the FlagSet will reject it cleanly).
		bare := strings.TrimLeft(a, "-")
		if eq := strings.Index(bare, "="); eq >= 0 {
			bare = bare[:eq]
			i++
			continue
		}
		if runGlobalValueFlags[bare] {
			i += 2
			continue
		}
		if runGlobalBoolFlags[bare] {
			i++
			continue
		}
		// Unknown flag-shaped token before the task name. Let FlagSet
		// report it.
		i++
	}
	// No task name. Callers may handle this as "run the default task";
	// signal with an empty slice + nil error so the cmd layer can
	// apply that fallback consistently.
	globalArgs = args
	return
}

// resolveInvocation reads `postArgs` (everything after the task name on
// `pkf run`'s command line) against the task's declared params and
// `--` tail-args contract. Returns nil when the task declares neither
// params nor acceptsArgs and the caller supplied nothing (so plans
// without invocation overlays match pre-0.4 cache keys exactly).
func resolveInvocation(task *config.Task, name string, postArgs []string) (*runner.Invocation, error) {
	// Split at `--`: everything after is tail args.
	var preTail, tail []string
	tailSeen := false
	for i, a := range postArgs {
		if a == "--" {
			preTail = postArgs[:i]
			tail = postArgs[i+1:]
			tailSeen = true
			break
		}
	}
	if !tailSeen {
		preTail = postArgs
	}

	// Validate tail-args against acceptsArgs.
	if len(tail) > 0 && !task.AcceptsArgs {
		return nil, fmt.Errorf("task %q does not accept positional args (set acceptsArgs = true)", name)
	}

	// Walk preTail collecting --<name>=<value> / --<name> <value> against
	// declared params; unknown flags are errors.
	//
	// Bool params take a value-less form: `--flag` alone means true. To
	// keep parsing predictable, bool params never consume the next
	// token as a value — use `--flag=false` (with `=`) for explicit
	// false.
	declared := make(map[string]*config.Param, len(task.Params))
	for _, p := range task.Params {
		declared[p.Name] = p
	}
	given := make(map[string]string)
	i := 0
	for i < len(preTail) {
		tok := preTail[i]
		if !strings.HasPrefix(tok, "--") {
			return nil, fmt.Errorf("unexpected positional %q (did you mean to pass tail args after `--`?)", tok)
		}
		body := strings.TrimPrefix(tok, "--")
		var key, val string
		hasEq := false
		if eq := strings.Index(body, "="); eq >= 0 {
			key, val = body[:eq], body[eq+1:]
			hasEq = true
			i++
		} else {
			key = body
		}
		p, ok := declared[key]
		if !ok {
			return nil, fmt.Errorf("task %q has no param %q", name, key)
		}
		if !hasEq {
			if p.Type == "bool" {
				val = "true"
				i++
			} else {
				if i+1 >= len(preTail) {
					return nil, fmt.Errorf("flag --%s needs a value", key)
				}
				val = preTail[i+1]
				i += 2
			}
		}
		if err := validateParamValue(p, val); err != nil {
			return nil, err
		}
		given[key] = val
	}

	// Apply defaults; error on missing required params. Defaults are
	// validated too, so a typo like `default = "tru"` on a bool param
	// errors before the task ever runs.
	resolved := make(map[string]string)
	for _, p := range task.Params {
		v, ok := given[p.Name]
		if !ok {
			if p.Default == nil {
				return nil, fmt.Errorf("task %q requires --%s", name, p.Name)
			}
			v = *p.Default
			if err := validateParamValue(p, v); err != nil {
				return nil, fmt.Errorf("default for --%s: %w", p.Name, err)
			}
		}
		resolved[strings.ToUpper(p.Name)] = v
	}

	if len(resolved) == 0 && len(tail) == 0 {
		return nil, nil
	}
	return &runner.Invocation{Params: resolved, Args: tail}, nil
}

// validateParamValue checks that `val` matches the param's declared
// type. Returns nil for "string" (anything goes).
func validateParamValue(p *config.Param, val string) error {
	switch p.Type {
	case "enum":
		for _, c := range p.Choices {
			if c == val {
				return nil
			}
		}
		return fmt.Errorf("param --%s=%q is not one of: %s", p.Name, val, strings.Join(p.Choices, ", "))
	case "int":
		if _, err := strconv.ParseInt(val, 10, 64); err != nil {
			return fmt.Errorf("param --%s=%q is not a valid integer", p.Name, val)
		}
		return nil
	case "bool":
		if val != "true" && val != "false" {
			return fmt.Errorf("param --%s=%q is not a valid boolean (want true or false)", p.Name, val)
		}
		return nil
	default:
		return nil
	}
}

// runWatch loops: execute the plan, then wait for input changes (or Ctrl+C),
// then re-execute. An in-flight run is cancelled when a fresh change lands so
// the user always sees results for the latest source state.
func runWatch(parentCtx context.Context, taskfilePath, root, target string, orch *orchestrator.Orchestrator, plan *orchestrator.Plan, stderr io.Writer) error {
	ctx, cancel := signal.NotifyContext(parentCtx, os.Interrupt, syscall.SIGTERM)
	defer cancel()

	paths := watchTargets(root, taskfilePath, plan)
	w, err := watcher.New(paths, 200*time.Millisecond)
	if err != nil {
		return fmt.Errorf("init watcher: %w", err)
	}
	defer w.Close()
	go w.Run(ctx)

	fmt.Fprintf(stderr, "[pkf] watching %d path(s) for %q (Ctrl+C to stop)\n", len(paths), target)

	for {
		runCtx, runCancel := context.WithCancel(ctx)
		done := make(chan error, 1)
		go func() {
			_, e := orch.Execute(runCtx, plan)
			done <- e
		}()

		err := <-done
		runCancel()
		if err != nil && !errors.Is(err, context.Canceled) {
			fmt.Fprintf(stderr, "[pkf] run failed: %v\n", err)
		}

		// Drop every event the run itself may have produced (output writes,
		// pkl evaluator scratch files, etc.) — only post-run edits should
		// count toward the next iteration.
		drain(w.Events())
		fmt.Fprintln(stderr, "[pkf] idle — waiting for changes")

		select {
		case <-w.Events():
			fmt.Fprintln(stderr, "[pkf] change detected — re-running")
		case <-ctx.Done():
			return nil
		}
	}
}

func drain(ch <-chan struct{}) {
	for {
		select {
		case <-ch:
		default:
			return
		}
	}
}

// watchTargets collects the set of filesystem paths whose changes should
// trigger a re-run: the Taskfile itself, every input glob's expansion, and
// (since glob expansion may miss new files) the workdir of each task.
func watchTargets(root, taskfilePath string, plan *orchestrator.Plan) []string {
	seen := map[string]struct{}{taskfilePath: {}}
	for _, name := range plan.Order {
		t := plan.Tasks[name]
		taskRoot := orchestrator.TaskRoot(t, plan.Root)
		seen[taskRoot] = struct{}{}
		entries, err := hash.HashInputs(taskRoot, t.Inputs)
		if err != nil {
			continue
		}
		for _, e := range entries {
			seen[filepath.Join(taskRoot, e.Path)] = struct{}{}
		}
	}
	out := make([]string, 0, len(seen))
	for p := range seen {
		out = append(out, p)
	}
	return out
}

func buildGraph(tf *config.Taskfile) (*graph.Graph, error) {
	nodes := make([]graph.Node, 0, len(tf.Tasks))
	for name, t := range tf.Tasks {
		nodes = append(nodes, graph.Node{Name: name, Deps: append([]string(nil), t.Deps...)})
	}
	return graph.Build(nodes)
}

// printHashes computes and prints the action key of every task in `order`.
// Cache state is not consulted; this is a diagnostic for understanding why
// a task does or does not hit cache.
func printHashes(stdout io.Writer, root string, tf *config.Taskfile, order []string, target string, inv *runner.Invocation) error {
	configHash := hash.HashBytes(tf.Canonical)
	for _, name := range order {
		task := tf.Tasks[name]
		taskRoot := orchestrator.TaskRoot(task, root)
		var taskInv *runner.Invocation
		if name == target {
			taskInv = inv
		}
		key, err := orchestrator.ComputeKey(task, tf.Defaults, taskRoot, configHash, taskInv)
		if err != nil {
			return fmt.Errorf("compute key for %q: %w", name, err)
		}
		fmt.Fprintf(stdout, "%s\t%s\n", name, hash.FormatKey(key))
	}
	return nil
}

// gitHookEvents is the set of git client-side hook names that pkfire
// will wire to a same-named task. Server-side hooks (pre-receive,
// update, post-receive) are intentionally absent — they live on the
// server and have a different lifecycle.
var gitHookEvents = []string{
	"pre-commit",
	"prepare-commit-msg",
	"commit-msg",
	"post-commit",
	"pre-rebase",
	"post-checkout",
	"post-merge",
	"pre-push",
	"post-rewrite",
}

// pkfHookMarker is grepped to distinguish "pkfire installed this hook"
// from "the user (or some other tool) wrote this hook". Uninstall
// refuses to delete hooks without the marker so a hand-written hook
// doesn't disappear on `pkf hooks uninstall`.
const pkfHookMarker = "# managed by pkf hooks install"

// cmdExplain prints every input that feeds a task's action key —
// cmd, shell, sorted env, sorted tools, every expanded input file
// with its content hash, the Pkl module's config hash, and any
// resolved CLI params/args. Diagnostic for "why isn't this hitting
// cache?" — when the action key changes between runs and the user
// can't figure out which component flipped.
//
// The output is grouped by component so you can diff two runs'
// `pkf explain <task>` outputs and see exactly what moved.
func cmdExplain(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("pkf explain", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	file := newFileFlag(fs)
	if err := fs.Parse(args); err != nil {
		return err
	}
	rest := fs.Args()
	if len(rest) != 1 {
		return fmt.Errorf("usage: pkf explain <task>")
	}
	target := rest[0]

	abs, err := resolveFile(fs, *file)
	if err != nil {
		return err
	}
	tf, err := config.Load(context.Background(), abs)
	if err != nil {
		return err
	}
	task, ok := tf.Tasks[target]
	if !ok {
		return fmt.Errorf("unknown task: %q", target)
	}
	root := filepath.Dir(abs)
	taskRoot := orchestrator.TaskRoot(task, root)
	configHash := hash.HashBytes(tf.Canonical)

	// Re-derive the same things ComputeKey computes, but expose them
	// at every layer (not just the final BLAKE3 digest).
	shell := task.Shell
	var defEnv map[string]string
	if tf.Defaults != nil {
		if shell == "" {
			shell = tf.Defaults.Shell
		}
		defEnv = tf.Defaults.Env
	}
	env := hash.MergeEnv(defEnv, task.Env)
	entries, err := hash.HashInputs(taskRoot, task.Inputs)
	if err != nil {
		return fmt.Errorf("hash inputs for %q: %w", target, err)
	}
	action := &hash.Action{
		Cmd:        task.Cmd,
		Shell:      shell,
		Env:        env,
		Tools:      task.Tools,
		Inputs:     entries,
		ConfigHash: configHash,
	}
	key := action.Key()

	fmt.Fprintf(stdout, "task:        %s\n", target)
	fmt.Fprintf(stdout, "action key:  %s\n", hash.FormatKey(key))
	fmt.Fprintf(stdout, "cache:       %v\n", task.Cache)
	if task.Workdir != nil && *task.Workdir != "" {
		fmt.Fprintf(stdout, "workdir:     %s  (absolute: %s)\n", *task.Workdir, taskRoot)
	} else {
		fmt.Fprintf(stdout, "workdir:     %s  (Taskfile dir)\n", taskRoot)
	}
	fmt.Fprintln(stdout)
	fmt.Fprintf(stdout, "cmd:\n  %s\n", strings.ReplaceAll(task.Cmd, "\n", "\n  "))
	fmt.Fprintln(stdout)
	fmt.Fprintf(stdout, "shell:       %s\n", shell)
	fmt.Fprintln(stdout)

	fmt.Fprintf(stdout, "env (%d):\n", len(env))
	envKeys := make([]string, 0, len(env))
	for k := range env {
		envKeys = append(envKeys, k)
	}
	sort.Strings(envKeys)
	for _, k := range envKeys {
		fmt.Fprintf(stdout, "  %s=%s\n", k, env[k])
	}
	if len(env) == 0 {
		fmt.Fprintln(stdout, "  (none)")
	}
	fmt.Fprintln(stdout)

	fmt.Fprintf(stdout, "tools (%d):\n", len(task.Tools))
	toolKeys := make([]string, 0, len(task.Tools))
	for k := range task.Tools {
		toolKeys = append(toolKeys, k)
	}
	sort.Strings(toolKeys)
	for _, k := range toolKeys {
		fmt.Fprintf(stdout, "  %s=%s\n", k, task.Tools[k])
	}
	if len(task.Tools) == 0 {
		fmt.Fprintln(stdout, "  (none)")
	}
	fmt.Fprintln(stdout)

	fmt.Fprintf(stdout, "inputs (%d files):\n", len(entries))
	for _, e := range entries {
		fmt.Fprintf(stdout, "  %x  %s\n", e.Hash[:6], e.Path)
	}
	if len(entries) == 0 {
		fmt.Fprintln(stdout, "  (none — glob expansion matched zero files)")
	}
	fmt.Fprintln(stdout)

	fmt.Fprintf(stdout, "config hash: %x  (sha-256-ish prefix of pkl/Taskfile.pkl canonical form)\n", configHash[:8])

	if task.AcceptsArgs || len(task.Params) > 0 {
		fmt.Fprintln(stdout)
		fmt.Fprintln(stdout, "invocation overlay:")
		fmt.Fprintf(stdout, "  acceptsArgs: %v\n", task.AcceptsArgs)
		fmt.Fprintf(stdout, "  params: %d declared\n", len(task.Params))
		for _, p := range task.Params {
			def := "(required)"
			if p.Default != nil {
				def = fmt.Sprintf("default=%q", *p.Default)
			}
			fmt.Fprintf(stdout, "    --%s (%s) %s\n", p.Name, p.Type, def)
		}
		fmt.Fprintln(stdout, "  these contribute to the action key only when supplied on the cmd line")
	}
	return nil
}

// Shell-completion scripts shipped with the binary. Sources live in
// cmd/pkf/completion/ so the bash/zsh/fish snippets stay readable and
// testable as plain files; go:embed inlines them at build time so
// the binary is still a single artifact.
//
//go:embed completion/pkf.bash
var completionBash string

//go:embed completion/pkf.zsh
var completionZsh string

//go:embed completion/pkf.fish
var completionFish string

// cmdCompletion writes the requested shell's completion script to
// stdout. Suggested installs are in the script header of each file.
// Dynamic completions (task names for run/affected/clean/up) shell
// out to `pkf list`, so the script stays static and always reflects
// the current Taskfile.
func cmdCompletion(args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: pkf completion <bash|zsh|fish>")
	}
	switch args[0] {
	case "bash":
		_, err := io.WriteString(stdout, completionBash)
		return err
	case "zsh":
		_, err := io.WriteString(stdout, completionZsh)
		return err
	case "fish":
		_, err := io.WriteString(stdout, completionFish)
		return err
	default:
		return fmt.Errorf("unknown shell %q (supported: bash, zsh, fish)", args[0])
	}
}

// cmdClean removes the declared `outputs` of one or more tasks. The
// cache is intentionally NOT touched — clean is "remove the artifacts
// you can re-generate", not "force re-run". To force re-run, use
// `pkf run --refresh <task>`. To drop a cache entry too, follow up
// with `pkf cache rm <action-key>`.
//
// Outputs paths are interpreted relative to each task's `workdir`,
// same as the runner uses them. Removal is recursive (os.RemoveAll)
// so an `outputs { "bin" }` cleans the directory and everything in
// it. Missing paths are silently OK (idempotent).
func cmdClean(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("pkf clean", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	file := newFileFlag(fs)
	dryRun := fs.Bool("dry-run", false, "list paths without removing them")
	if err := fs.Parse(args); err != nil {
		return err
	}

	abs, err := resolveFile(fs, *file)
	if err != nil {
		return err
	}
	tf, err := config.Load(context.Background(), abs)
	if err != nil {
		return err
	}
	root := filepath.Dir(abs)

	requested := fs.Args()
	if patterns := expandPatterns(requested, tf.Tasks); patterns != nil {
		requested = patterns
	}

	// No targets = every task that declares outputs. Skip the rest so
	// users don't accidentally trigger "rm -rf" on tasks they didn't
	// even know existed.
	var names []string
	if len(requested) == 0 {
		for n, t := range tf.Tasks {
			if len(t.Outputs) > 0 {
				names = append(names, n)
			}
		}
		sort.Strings(names)
	} else {
		for _, n := range requested {
			if _, ok := tf.Tasks[n]; !ok {
				return fmt.Errorf("unknown task: %q", n)
			}
			names = append(names, n)
		}
	}

	if len(names) == 0 {
		fmt.Fprintln(stderr, "[pkf] clean: no tasks declare outputs — nothing to do")
		return nil
	}

	removed := 0
	for _, name := range names {
		task := tf.Tasks[name]
		if len(task.Outputs) == 0 {
			fmt.Fprintf(stderr, "[pkf] %s: no outputs declared — skipping\n", name)
			continue
		}
		taskRoot := orchestrator.TaskRoot(task, root)
		for _, out := range task.Outputs {
			path := filepath.Join(taskRoot, out)
			if _, err := os.Lstat(path); err != nil {
				if !os.IsNotExist(err) {
					fmt.Fprintf(stderr, "[pkf] %s: stat %s: %v\n", name, path, err)
				}
				continue
			}
			if *dryRun {
				fmt.Fprintf(stdout, "would remove: %s  (%s)\n", path, name)
			} else {
				if err := os.RemoveAll(path); err != nil {
					return fmt.Errorf("remove %s: %w", path, err)
				}
				fmt.Fprintf(stdout, "removed: %s  (%s)\n", path, name)
			}
			removed++
		}
	}
	if removed == 0 && !*dryRun {
		fmt.Fprintln(stderr, "[pkf] clean: nothing to remove (no declared outputs exist on disk)")
	}
	return nil
}

// cmdCache implements `pkf cache <stats|prune|rm|clear>` over the
// local CAS at $PKFIRE_CACHE_DIR (default $XDG_CACHE_HOME/pkfire).
// Remote cache is never touched here — that's the server admin's
// problem.
func cmdCache(args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: pkf cache <stats|prune|rm|clear> [args]")
	}
	sub := args[0]
	dir, err := cache.DefaultDir()
	if err != nil {
		return fmt.Errorf("resolve cache dir: %w", err)
	}

	switch sub {
	case "stats":
		return cacheStatsCmd(stdout, dir)
	case "prune":
		return cachePruneCmd(stdout, stderr, dir, args[1:])
	case "rm":
		return cacheRmCmd(stdout, stderr, dir, args[1:])
	case "clear":
		return cacheClearCmd(stdout, stderr, dir, args[1:])
	default:
		return fmt.Errorf("unknown cache subcommand %q (want stats|prune|rm|clear)", sub)
	}
}

// cachePath returns the on-disk entry path for a hex action key.
// Mirrors internal/cache/cache.go's `entryDir` layout — keep these
// two in sync (or move to a shared helper later).
func cachePath(dir, hex string) string {
	if len(hex) < 2 {
		return ""
	}
	return filepath.Join(dir, "cas", hex[:2], hex[2:])
}

// walkCacheEntries iterates every cas/<aa>/<bbbb...> directory in
// `dir` and calls `fn` with the entry's hex key, full path, total
// size, and the mtime of its archive file. Errors during walk are
// logged but don't abort — best-effort.
func walkCacheEntries(dir string, fn func(hex, path string, size int64, mtime time.Time)) error {
	cas := filepath.Join(dir, "cas")
	prefixes, err := os.ReadDir(cas)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	for _, p := range prefixes {
		if !p.IsDir() || len(p.Name()) != 2 {
			continue
		}
		suffixes, err := os.ReadDir(filepath.Join(cas, p.Name()))
		if err != nil {
			continue
		}
		for _, s := range suffixes {
			if !s.IsDir() {
				continue
			}
			entryDir := filepath.Join(cas, p.Name(), s.Name())
			var size int64
			var mtime time.Time
			filepath.Walk(entryDir, func(_ string, info os.FileInfo, err error) error {
				if err != nil || info == nil {
					return nil
				}
				if !info.IsDir() {
					size += info.Size()
					if info.ModTime().After(mtime) {
						mtime = info.ModTime()
					}
				}
				return nil
			})
			fn(p.Name()+s.Name(), entryDir, size, mtime)
		}
	}
	return nil
}

func cacheStatsCmd(stdout io.Writer, dir string) error {
	var total int64
	count := 0
	var oldest, newest time.Time
	err := walkCacheEntries(dir, func(_, _ string, size int64, mtime time.Time) {
		total += size
		count++
		if oldest.IsZero() || mtime.Before(oldest) {
			oldest = mtime
		}
		if mtime.After(newest) {
			newest = mtime
		}
	})
	if err != nil {
		return err
	}
	fmt.Fprintf(stdout, "cache dir: %s\n", dir)
	fmt.Fprintf(stdout, "entries:   %d\n", count)
	fmt.Fprintf(stdout, "size:      %s\n", humanBytes(total))
	if count > 0 {
		fmt.Fprintf(stdout, "oldest:    %s (%s ago)\n", oldest.Format(time.RFC3339), time.Since(oldest).Round(time.Hour))
		fmt.Fprintf(stdout, "newest:    %s (%s ago)\n", newest.Format(time.RFC3339), time.Since(newest).Round(time.Hour))
	}
	return nil
}

func cachePruneCmd(stdout, stderr io.Writer, dir string, args []string) error {
	fs := flag.NewFlagSet("pkf cache prune", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	olderThan := fs.String("older-than", "30d", "drop entries whose newest file mtime is older than this (e.g. 7d, 24h)")
	dryRun := fs.Bool("dry-run", false, "list what would be removed without removing")
	if err := fs.Parse(args); err != nil {
		return err
	}
	threshold, err := parseDuration(*olderThan)
	if err != nil {
		return fmt.Errorf("--older-than: %w", err)
	}
	cutoff := time.Now().Add(-threshold)
	removed := 0
	var freed int64
	err = walkCacheEntries(dir, func(hex, path string, size int64, mtime time.Time) {
		if mtime.After(cutoff) {
			return
		}
		freed += size
		removed++
		if *dryRun {
			fmt.Fprintf(stdout, "would remove %s (%s, %s old)\n", hex[:12], humanBytes(size), time.Since(mtime).Round(time.Hour))
			return
		}
		if err := os.RemoveAll(path); err != nil {
			fmt.Fprintf(stderr, "[pkf] cache: rm %s: %v\n", path, err)
			return
		}
		fmt.Fprintf(stdout, "removed %s (%s, %s old)\n", hex[:12], humanBytes(size), time.Since(mtime).Round(time.Hour))
	})
	if err != nil {
		return err
	}
	if *dryRun {
		fmt.Fprintf(stdout, "\nwould remove %d entries (%s)\n", removed, humanBytes(freed))
	} else {
		fmt.Fprintf(stdout, "\nremoved %d entries (%s freed)\n", removed, humanBytes(freed))
	}
	return nil
}

func cacheRmCmd(stdout, stderr io.Writer, dir string, args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: pkf cache rm <action-key-hex>")
	}
	removed := 0
	for _, key := range args {
		// Accept full 64-char hex or any prefix ≥ 2; the layout is
		// cas/<aa>/<rest>, so we need ≥ 2 chars to find the bucket.
		if len(key) < 2 {
			return fmt.Errorf("action key %q too short (need ≥ 2 hex chars)", key)
		}
		path := cachePath(dir, key)
		if len(key) < 64 {
			// Prefix match: find a unique entry in the bucket.
			bucket := filepath.Join(dir, "cas", key[:2])
			entries, _ := os.ReadDir(bucket)
			var matches []string
			rest := key[2:]
			for _, e := range entries {
				if strings.HasPrefix(e.Name(), rest) {
					matches = append(matches, e.Name())
				}
			}
			switch len(matches) {
			case 0:
				fmt.Fprintf(stderr, "[pkf] cache rm: no entry matching %s\n", key)
				continue
			case 1:
				path = filepath.Join(bucket, matches[0])
			default:
				return fmt.Errorf("prefix %q matches %d entries; disambiguate", key, len(matches))
			}
		}
		if _, err := os.Stat(path); err != nil {
			if os.IsNotExist(err) {
				fmt.Fprintf(stderr, "[pkf] cache rm: no entry at %s\n", key)
				continue
			}
			return err
		}
		if err := os.RemoveAll(path); err != nil {
			return fmt.Errorf("remove %s: %w", path, err)
		}
		fmt.Fprintf(stdout, "removed %s\n", key)
		removed++
	}
	fmt.Fprintf(stdout, "\nremoved %d entries\n", removed)
	return nil
}

func cacheClearCmd(stdout, stderr io.Writer, dir string, args []string) error {
	fs := flag.NewFlagSet("pkf cache clear", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	yes := fs.Bool("yes", false, "skip confirmation (intended for scripts / CI)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cas := filepath.Join(dir, "cas")
	if _, err := os.Stat(cas); err != nil {
		if os.IsNotExist(err) {
			fmt.Fprintln(stdout, "cache already empty")
			return nil
		}
		return err
	}
	if !*yes {
		return fmt.Errorf("refusing to clear %s without --yes (interactive confirmation not wired up; use --yes for scripts)", cas)
	}
	if err := os.RemoveAll(cas); err != nil {
		return fmt.Errorf("remove %s: %w", cas, err)
	}
	fmt.Fprintf(stdout, "cleared %s\n", cas)
	return nil
}

// parseDuration extends Go's time.ParseDuration with "d" for days,
// since cache age is naturally expressed in days for prune contexts.
// "7d" → 168h, "30d" → 720h, etc. Any standard suffix
// (h/m/s/...) still works.
func parseDuration(s string) (time.Duration, error) {
	if strings.HasSuffix(s, "d") {
		nDays, err := strconv.Atoi(strings.TrimSuffix(s, "d"))
		if err != nil {
			return 0, fmt.Errorf("parse %q: %w", s, err)
		}
		return time.Duration(nDays) * 24 * time.Hour, nil
	}
	return time.ParseDuration(s)
}

// expandPatterns expands any glob-shaped (`*` or `?`) entries in
// `targets` against `tasks`'s keys, leaving exact names untouched.
// Returns nil when nothing expanded (caller can use the original
// slice); returns a non-nil slice (possibly empty) when at least
// one pattern was attempted, so callers can detect the
// expand-vs-passthrough boundary.
//
// Used by `pkf run`, `pkf affected`, and `pkf clean` so all three
// share consistent semantics — `pkf run 'test:*'` does the same
// thing as `pkf clean 'build:*'`.
func expandPatterns(targets []string, tasks map[string]*config.Task) []string {
	anyPattern := false
	for _, t := range targets {
		if strings.ContainsAny(t, "*?") {
			anyPattern = true
			break
		}
	}
	if !anyPattern {
		return nil
	}
	seen := make(map[string]bool)
	var out []string
	for _, t := range targets {
		if !strings.ContainsAny(t, "*?") {
			if !seen[t] {
				seen[t] = true
				out = append(out, t)
			}
			continue
		}
		matched := false
		var names []string
		for n := range tasks {
			names = append(names, n)
		}
		sort.Strings(names)
		for _, n := range names {
			ok, _ := path.Match(t, n)
			if !ok {
				continue
			}
			matched = true
			if !seen[n] {
				seen[n] = true
				out = append(out, n)
			}
		}
		if !matched {
			// Caller can spot empty expansion by length, but warn
			// here so users see WHY: pattern matched nothing.
			out = append(out, t) // keep the literal; caller's "unknown task" path will surface it cleanly
		}
	}
	return out
}

// cmdAffected runs only those tasks whose declared `inputs` glob
// matches at least one file changed between `--since=<ref>` and HEAD,
// plus their transitive *dependents* (downstream tasks reachable in
// the deps DAG). The monorepo-CI killer: in a PR with a small diff,
// it lets `pkf affected --since=origin/main test` run only the test
// tasks that actually depend on what changed.
//
// Two kinds of decisions about "what's affected":
//
//   - Task with non-empty inputs: affected iff at least one input
//     glob (interpreted relative to the task's workdir) matches a
//     changed file path.
//   - Task with empty inputs: never affected by file changes. (If
//     it's `cache = false`, the user marked it as "always run when
//     invoked" — `pkf affected` doesn't drag those in by default.)
//
// After computing the directly-affected set, the function expands to
// include every task that transitively depends on an affected one
// (forward closure in the deps DAG). Without this, you'd miss
// downstream rebuilds.
//
// Optional positional args filter the resulting plan to a subset of
// task names (exact-match), so `pkf affected --since=origin/main
// test:unit test:integration` restricts the gate to those two.
func cmdAffected(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("pkf affected", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	file := newFileFlag(fs)
	since := fs.String("since", "", "git ref to diff against (default: origin/main, fallback HEAD~1)")
	dryRun := fs.Bool("dry-run", false, "print the affected plan and exit")
	noCache := fs.Bool("no-cache", false, "disable cache for this run")
	refresh := fs.Bool("refresh", false, "skip cache lookup but still store results")
	timing := fs.Bool("timing", false, "print per-task duration at end of run")
	quiet := fs.Bool("quiet", false, "suppress per-task log lines (errors + summary still print)")
	keepGoing := fs.Bool("keep-going", false, "don't stop on first failure; run independent subgraphs to completion")
	jobs := fs.Int("j", 0, "max concurrent tasks (default: NumCPU)")
	fs.IntVar(jobs, "jobs", 0, "max concurrent tasks (default: NumCPU)")
	if err := fs.Parse(args); err != nil {
		return err
	}

	abs, err := resolveFile(fs, *file)
	if err != nil {
		return err
	}
	ctx := context.Background()
	tf, err := config.Load(ctx, abs)
	if err != nil {
		return err
	}
	root := filepath.Dir(abs)

	sinceRef := *since
	if sinceRef == "" {
		sinceRef = defaultAffectedRef(root)
		fmt.Fprintf(stderr, "[pkf] affected: using --since=%s (no explicit ref given)\n", sinceRef)
	}
	changed, err := gitChangedFiles(root, sinceRef)
	if err != nil {
		return fmt.Errorf("compute changed files: %w", err)
	}
	if len(changed) == 0 {
		fmt.Fprintln(stderr, "[pkf] affected: no changed files — nothing to do")
		return nil
	}

	direct := tasksMatchingChanges(tf, root, changed)
	affectedSet := expandToDependents(tf, direct)
	if len(affectedSet) == 0 {
		fmt.Fprintln(stderr, "[pkf] affected: changes don't intersect any task's inputs — nothing to do")
		return nil
	}

	// Filter to user-supplied targets if any. Glob-shaped names
	// (`test:*`) expand against the task list first so
	// `pkf affected --since=X 'test:*'` selects every test:*
	// task that the diff actually affected.
	if posArgs := fs.Args(); len(posArgs) > 0 {
		if expanded := expandPatterns(posArgs, tf.Tasks); expanded != nil {
			posArgs = expanded
		}
		filter := make(map[string]bool, len(posArgs))
		for _, n := range posArgs {
			if _, ok := tf.Tasks[n]; !ok {
				return fmt.Errorf("unknown task: %q (no glob pattern matched)", n)
			}
			filter[n] = true
		}
		for name := range affectedSet {
			if !filter[name] {
				delete(affectedSet, name)
			}
		}
		if len(affectedSet) == 0 {
			fmt.Fprintln(stderr, "[pkf] affected: none of the named tasks are in the affected set")
			return nil
		}
	}

	g, err := buildGraph(tf)
	if err != nil {
		return err
	}
	// Build the plan as the union of subgraphs rooted at each
	// affected task. This brings in each affected task's own deps so
	// the runtime DAG stays self-consistent (dep order honored).
	roots := make([]string, 0, len(affectedSet))
	for n := range affectedSet {
		roots = append(roots, n)
	}
	sort.Strings(roots)
	order, err := unionSubgraph(g, roots)
	if err != nil {
		return err
	}

	if *noCache && *refresh {
		return fmt.Errorf("--no-cache and --refresh are mutually exclusive")
	}
	if *dryRun {
		return printDryRun(stdout, root, tf, order, "", nil, *noCache || *refresh)
	}

	var backend cache.Backend
	if !*noCache {
		dir, err := cache.DefaultDir()
		if err != nil {
			return fmt.Errorf("resolve cache dir: %w", err)
		}
		local := cache.New(dir)
		if remoteURL := os.Getenv("PKFIRE_REMOTE_CACHE"); remoteURL != "" {
			remote := cache.NewRemote(remoteURL, os.Getenv("PKFIRE_REMOTE_TOKEN"))
			backend = cache.NewLayered(local, remote)
		} else {
			backend = local
		}
	}
	r := runner.New(runner.Options{Workdir: root, Quiet: *quiet})
	orch := orchestrator.New(backend, r, stdout, stderr, orchestrator.Options{Parallelism: *jobs, Quiet: *quiet, KeepGoing: *keepGoing})
	plan := &orchestrator.Plan{
		Order:      order,
		Tasks:      tf.Tasks,
		Defaults:   tf.Defaults,
		Root:       root,
		ConfigHash: hash.HashBytes(tf.Canonical),
		Refresh:    *refresh,
	}
	start := time.Now()
	results, err := orch.Execute(ctx, plan)
	wall := time.Since(start)
	printRunSummary(stderr, results, wall, *timing)
	return err
}

// defaultAffectedRef picks a sensible default for `--since` when the
// user doesn't supply one. Tries `origin/main` first (the standard
// CI base), then `origin/master`, falling back to `HEAD~1` (compare
// against the previous commit — useful for local "what just
// changed").
func defaultAffectedRef(repoRoot string) string {
	for _, candidate := range []string{"origin/main", "origin/master"} {
		cmd := exec.Command("git", "-C", repoRoot, "rev-parse", "--verify", candidate)
		if cmd.Run() == nil {
			return candidate
		}
	}
	return "HEAD~1"
}

// gitChangedFiles returns the file set in the asymmetric diff range
// `<since>...HEAD` — commits in HEAD not in <since>, restricted to
// added/copied/modified/renamed files (a deleted file can't appear in
// any task's inputs by definition). Path strings are relative to the
// repo root.
func gitChangedFiles(repoRoot, since string) ([]string, error) {
	args := []string{"-C", repoRoot, "diff", "--name-only", "--diff-filter=ACMR", since + "...HEAD"}
	out, err := exec.Command("git", args...).Output()
	if err != nil {
		return nil, fmt.Errorf("git %s: %w", strings.Join(args, " "), err)
	}
	var files []string
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line == "" {
			continue
		}
		files = append(files, line)
	}
	return files, nil
}

// tasksMatchingChanges returns the set of task names whose declared
// `inputs` globs match at least one file in `changed`. Each task's
// glob is interpreted relative to its `workdir`, so a task with
// `workdir = "services/api"` and `inputs = "src/**/*.ts"` matches
// changed file `services/api/src/foo.ts`.
//
// Tasks with empty `inputs` cannot be matched here (they have no
// declared file dependencies; `pkf affected` doesn't speculate).
func tasksMatchingChanges(tf *config.Taskfile, root string, changed []string) map[string]bool {
	out := make(map[string]bool)
	for name, task := range tf.Tasks {
		if len(task.Inputs) == 0 {
			continue
		}
		taskRoot := orchestrator.TaskRoot(task, root)
		// Convert changed-file repo-relative paths into paths
		// relative to the task's root for glob matching.
		rel, err := filepath.Rel(root, taskRoot)
		if err != nil || rel == "" {
			rel = "."
		}
		prefix := ""
		if rel != "." {
			prefix = filepath.ToSlash(rel) + "/"
		}
		for _, file := range changed {
			file = filepath.ToSlash(file)
			if prefix != "" {
				if !strings.HasPrefix(file, prefix) {
					continue
				}
				file = strings.TrimPrefix(file, prefix)
			}
			for _, pat := range task.Inputs {
				if ok, _ := doublestar.PathMatch(pat, file); ok {
					out[name] = true
					break
				}
			}
			if out[name] {
				break
			}
		}
	}
	return out
}

// expandToDependents takes a set of directly-affected task names and
// adds every task that transitively depends on any of them. Walks the
// deps DAG forward (a task A `deps { B }` means A reaches B; here we
// want the reverse — what reaches A's affected node).
func expandToDependents(tf *config.Taskfile, direct map[string]bool) map[string]bool {
	// Build the reverse adjacency: `dependents[B]` = [A : A.deps contains B]
	dependents := make(map[string][]string, len(tf.Tasks))
	for name, task := range tf.Tasks {
		for _, dep := range task.Deps {
			dependents[dep] = append(dependents[dep], name)
		}
	}
	result := make(map[string]bool, len(direct))
	queue := make([]string, 0, len(direct))
	for n := range direct {
		result[n] = true
		queue = append(queue, n)
	}
	for len(queue) > 0 {
		n := queue[0]
		queue = queue[1:]
		for _, d := range dependents[n] {
			if !result[d] {
				result[d] = true
				queue = append(queue, d)
			}
		}
	}
	return result
}

// cmdHooks implements `pkf hooks <install|uninstall|list>`. The
// convention is: any task whose `name` matches a git client-side hook
// event becomes an installable hook. Installing writes
// `.git/hooks/<event>` as a tiny shim that `exec`s `pkf run <event>`,
// carrying through any args the hook receives. The Taskfile's `cmd`
// is responsible for whatever scoping the hook needs (e.g.
// `git diff --cached --name-only` inside `cmd` to operate on the
// staged set).
func cmdHooks(args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: pkf hooks <install|uninstall|list> [-f FILE] [--force]")
	}
	sub := args[0]
	fs := flag.NewFlagSet("pkf hooks", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	file := newFileFlag(fs)
	force := fs.Bool("force", false, "overwrite existing hooks not managed by pkfire")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	if len(fs.Args()) > 0 {
		return fmt.Errorf("hooks %s takes no positional args, got %v", sub, fs.Args())
	}

	abs, err := resolveFile(fs, *file)
	if err != nil {
		return err
	}
	tf, err := config.Load(context.Background(), abs)
	if err != nil {
		return err
	}

	hooksDir, err := gitHooksDir(abs)
	if err != nil {
		return err
	}

	switch sub {
	case "install":
		return hooksInstall(stdout, stderr, tf, hooksDir, *force)
	case "uninstall":
		return hooksUninstall(stdout, stderr, hooksDir)
	case "list":
		return hooksList(stdout, tf, hooksDir)
	default:
		return fmt.Errorf("unknown hooks subcommand %q (want install|uninstall|list)", sub)
	}
}

// gitHooksDir locates the .git/hooks directory by walking up from the
// Taskfile.pkl's directory. Returns an error when not inside a git
// repository — `pkf hooks` is a no-op outside one.
//
// Honors core.hooksPath when the repository has it configured (git
// itself respects this for hook invocation; the install ceremony has
// to follow suit).
func gitHooksDir(taskfilePath string) (string, error) {
	start := filepath.Dir(taskfilePath)
	dir := start
	for {
		gitDir := filepath.Join(dir, ".git")
		if info, err := os.Stat(gitDir); err == nil {
			if info.IsDir() {
				// Standard repo. Check core.hooksPath via a config read.
				if custom := readGitConfig(dir, "core.hooksPath"); custom != "" {
					if filepath.IsAbs(custom) {
						return custom, nil
					}
					return filepath.Join(dir, custom), nil
				}
				return filepath.Join(gitDir, "hooks"), nil
			}
			// .git is a file → worktree or submodule. Parse `gitdir: ...`.
			data, err := os.ReadFile(gitDir)
			if err != nil {
				return "", fmt.Errorf("read %s: %w", gitDir, err)
			}
			line := strings.TrimSpace(string(data))
			line = strings.TrimPrefix(line, "gitdir:")
			line = strings.TrimSpace(line)
			if !filepath.IsAbs(line) {
				line = filepath.Join(dir, line)
			}
			return filepath.Join(line, "hooks"), nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("not inside a git repository (no .git found from %s)", start)
		}
		dir = parent
	}
}

// readGitConfig reads a single git config value via `git config --get`.
// Returns empty string when unset or git is unavailable; never errors —
// callers treat missing as "use default".
func readGitConfig(repoDir, key string) string {
	cmd := exec.Command("git", "-C", repoDir, "config", "--get", key)
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// hookScript renders the shim that gets written to .git/hooks/<event>.
// Carries through `$@` so git's per-hook args (e.g. commit-msg's path
// to the message file) reach the task's cmd. Uses /usr/bin/env to find
// pkf so PATH overrides work in the user's interactive shell.
func hookScript(event string) string {
	return fmt.Sprintf(`#!/bin/sh
%s
exec pkf run %s -- "$@"
`, pkfHookMarker, event)
}

func hooksInstall(stdout, stderr io.Writer, tf *config.Taskfile, hooksDir string, force bool) error {
	if err := os.MkdirAll(hooksDir, 0o755); err != nil {
		return fmt.Errorf("create %s: %w", hooksDir, err)
	}
	// Counters distinguish "nothing in the Taskfile to install" (silent
	// noop) from "everything was already up-to-date" (also silent).
	matched := 0
	wrote := 0
	skipped := 0
	for _, event := range gitHookEvents {
		task, ok := tf.Tasks[event]
		if !ok {
			continue
		}
		matched++
		// `cache = true` on a hook task is almost always a bug — hooks
		// fire per-commit on a constantly-shifting tree. Warn but don't
		// block; the user might have a niche reason.
		if task.Cache {
			fmt.Fprintf(stderr, "[pkf] warning: task %q has cache=true; hooks typically want cache=false\n", event)
		}
		path := filepath.Join(hooksDir, event)
		want := hookScript(event)
		existing, readErr := os.ReadFile(path)
		switch {
		case readErr == nil && string(existing) == want:
			// Bit-identical shim already on disk. Silent so this is
			// safe to spam from .envrc / direnv-reload-on-cd.
			continue
		case readErr == nil && strings.Contains(string(existing), pkfHookMarker):
			// Pkfire-managed but stale (probably an older shim that
			// pre-dates the current pkf version). Overwrite + report.
		case readErr == nil:
			// Some other tool (or the user) wrote this hook. Don't
			// stomp on it without `--force`.
			if !force {
				fmt.Fprintf(stderr, "[pkf] %s: not managed by pkfire, skipping (use --force to overwrite)\n", event)
				skipped++
				continue
			}
		}
		if err := writeAtomic(path, []byte(want), 0o755); err != nil {
			return fmt.Errorf("write %s: %w", path, err)
		}
		fmt.Fprintf(stdout, "installed %s → pkf run %s\n", path, event)
		wrote++
	}
	if matched == 0 {
		// Only print this "nothing to do" hint when there were NO hook
		// tasks at all — that almost always means a Taskfile typo or
		// missing task. Silent when matches exist and were idempotent.
		fmt.Fprintln(stdout, "no installable hooks: the Taskfile declares no task named after a git hook event")
		fmt.Fprintln(stdout, "  recognized events: "+strings.Join(gitHookEvents, ", "))
	}
	_ = wrote
	_ = skipped
	return nil
}

// writeAtomic writes `data` to `path` with `mode`, going through a
// temp file in the same directory + rename so a concurrent reader
// (or a concurrent `pkf hooks install` triggered by parallel direnv
// reloads) never sees a partial write. Failure modes:
//   - tempfile creation fails: returned as-is.
//   - chmod fails: we already wrote, so unlink and bail.
//   - rename fails: unlink the temp and bail.
func writeAtomic(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".pkf-hook-*.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	cleanup := func() { _ = os.Remove(tmpPath) }
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		cleanup()
		return err
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return err
	}
	if err := os.Chmod(tmpPath, mode); err != nil {
		cleanup()
		return err
	}
	if err := os.Rename(tmpPath, path); err != nil {
		cleanup()
		return err
	}
	return nil
}

func hooksUninstall(stdout, stderr io.Writer, hooksDir string) error {
	removed := 0
	for _, event := range gitHookEvents {
		path := filepath.Join(hooksDir, event)
		data, err := os.ReadFile(path)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return err
		}
		if !strings.Contains(string(data), pkfHookMarker) {
			fmt.Fprintf(stderr, "[pkf] %s: not managed by pkfire, leaving alone\n", event)
			continue
		}
		if err := os.Remove(path); err != nil {
			return err
		}
		fmt.Fprintf(stdout, "removed %s\n", path)
		removed++
	}
	if removed == 0 {
		fmt.Fprintln(stdout, "no pkfire-managed hooks found")
	}
	return nil
}

func hooksList(stdout io.Writer, tf *config.Taskfile, hooksDir string) error {
	fmt.Fprintf(stdout, "hooks dir: %s\n\n", hooksDir)
	for _, event := range gitHookEvents {
		_, hasTask := tf.Tasks[event]
		state := "—"
		path := filepath.Join(hooksDir, event)
		if data, err := os.ReadFile(path); err == nil {
			if strings.Contains(string(data), pkfHookMarker) {
				state = "installed (pkfire)"
			} else {
				state = "installed (other)"
			}
		}
		taskState := "no task"
		if hasTask {
			taskState = "task declared"
		}
		fmt.Fprintf(stdout, "  %-20s  %-20s  %s\n", event, state, taskState)
	}
	return nil
}

// cmdFormat is a thin alias for `pkl format` — same spelling as the
// underlying CLI to keep the surface intuitive. With no positional
// args, formats the directory containing the discovered Taskfile.pkl
// — same walk-up behavior every other subcommand uses, so
// `pkf format` from a nested directory still does the right thing.
// `--check` flips to `pkl format --diff-name-only`, which exits 11
// on violations and prints the path of each unformatted file
// (CI-friendly).
func cmdFormat(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("pkf format", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	file := newFileFlag(fs)
	check := fs.Bool("check", false, "report unformatted files without writing (exit 11 if any)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	paths := fs.Args()
	if len(paths) == 0 {
		abs, err := resolveFile(fs, *file)
		if err != nil {
			return err
		}
		// If the discovered Taskfile exists, format its directory.
		// Otherwise fall back to cwd so `pkf fmt` works in a fresh
		// Pkl-only project that has no Taskfile yet.
		if info, statErr := os.Stat(abs); statErr == nil && !info.IsDir() {
			paths = []string{filepath.Dir(abs)}
		} else {
			cwd, err := os.Getwd()
			if err != nil {
				return err
			}
			paths = []string{cwd}
		}
	}
	pklArgs := []string{"format"}
	if *check {
		pklArgs = append(pklArgs, "--diff-name-only")
	} else {
		pklArgs = append(pklArgs, "-w")
	}
	pklArgs = append(pklArgs, paths...)

	cmd := exec.Command("pkl", pklArgs...)
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	if err := cmd.Run(); err != nil {
		// Propagate pkl's exit code so CI can act on --check (11) vs
		// any other failure (binary missing, parse error, ...).
		if ee, ok := err.(*exec.ExitError); ok {
			return fmt.Errorf("pkl format exited %d", ee.ExitCode())
		}
		return fmt.Errorf("pkl format: %w", err)
	}
	return nil
}

// cmdDoctor runs a battery of environmental checks and reports
// OK/WARN/FAIL per row. Designed for "I just installed pkf, what's
// missing?" and "my CI run is failing weirdly, is something
// half-configured?" — every check is read-only, every line is one
// line, and the exit code is non-zero iff any FAIL fired.
func cmdDoctor(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("pkf doctor", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	file := newFileFlag(fs)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if len(fs.Args()) > 0 {
		return fmt.Errorf("doctor takes no positional args, got %v", fs.Args())
	}

	var anyFail bool
	report := func(level, label, msg string) {
		fmt.Fprintf(stdout, "  %-4s  %-10s  %s\n", level, label, msg)
		if level == "FAIL" {
			anyFail = true
		}
	}

	fmt.Fprintf(stdout, "pkf doctor (pkf %s)\n", version)

	// 1. pkl CLI
	if pklPath, err := exec.LookPath("pkl"); err == nil {
		if ver, err := pklVersion(pklPath); err == nil {
			report("OK", "pkl", fmt.Sprintf("%s at %s", ver, pklPath))
		} else {
			report("WARN", "pkl", fmt.Sprintf("found at %s but `--version` failed: %v", pklPath, err))
		}
	} else {
		report("FAIL", "pkl", "not in PATH — install from https://pkl-lang.org/main/current/pkl-cli/")
	}

	// 2. cache directory
	cacheDir, err := cache.DefaultDir()
	if err != nil {
		report("WARN", "cache", fmt.Sprintf("could not resolve dir: %v", err))
	} else if info, err := os.Stat(cacheDir); err != nil {
		if os.IsNotExist(err) {
			report("OK", "cache", fmt.Sprintf("%s (empty — will be created on first run)", cacheDir))
		} else {
			report("WARN", "cache", fmt.Sprintf("%s: %v", cacheDir, err))
		}
	} else if !info.IsDir() {
		report("FAIL", "cache", fmt.Sprintf("%s exists but is not a directory", cacheDir))
	} else {
		size, count := cacheStats(cacheDir)
		report("OK", "cache", fmt.Sprintf("%s (%s across %d entries)", cacheDir, humanBytes(size), count))
	}

	// 3. remote cache (only if configured)
	if remote := os.Getenv("PKFIRE_REMOTE_CACHE"); remote != "" {
		// HEAD a CAS path with a zero digest — expect 404 / 401 / 200, but
		// not a connection error. Any HTTP response means the endpoint
		// is alive and the URL shape is correct.
		probeURL := strings.TrimRight(remote, "/") + "/v1/cas/" + strings.Repeat("0", 64)
		req, _ := http.NewRequest("HEAD", probeURL, nil)
		if tok := os.Getenv("PKFIRE_REMOTE_TOKEN"); tok != "" {
			req.Header.Set("Authorization", "Bearer "+tok)
		}
		client := &http.Client{Timeout: 5 * time.Second}
		if resp, err := client.Do(req); err != nil {
			report("FAIL", "remote", fmt.Sprintf("%s unreachable: %v", remote, err))
		} else {
			resp.Body.Close()
			switch resp.StatusCode {
			case 401, 403:
				report("FAIL", "remote", fmt.Sprintf("%s returned %d — check PKFIRE_REMOTE_TOKEN", remote, resp.StatusCode))
			case 404, 200:
				report("OK", "remote", fmt.Sprintf("%s reachable (status %d)", remote, resp.StatusCode))
			default:
				report("WARN", "remote", fmt.Sprintf("%s responded %d (expected 200/404)", remote, resp.StatusCode))
			}
		}
	} else {
		report("OK", "remote", "PKFIRE_REMOTE_CACHE not set (local-only)")
	}

	// 4. Taskfile (best-effort — doctor should be runnable outside any project)
	abs, ferr := resolveFile(fs, *file)
	if ferr == nil {
		if info, err := os.Stat(abs); err == nil && !info.IsDir() {
			if tf, err := config.Load(context.Background(), abs); err != nil {
				report("FAIL", "taskfile", fmt.Sprintf("%s failed to load: %v", abs, err))
			} else {
				amends := scanAmends(abs)
				if amends == "" {
					amends = "(unknown)"
				}
				report("OK", "taskfile", fmt.Sprintf("%s (%d tasks; amends %s)", abs, len(tf.Tasks), amends))
			}
		} else {
			report("WARN", "taskfile", fmt.Sprintf("no Taskfile.pkl found near %s", abs))
		}
	} else {
		report("WARN", "taskfile", fmt.Sprintf("could not resolve file path: %v", ferr))
	}

	fmt.Fprintln(stdout)
	if anyFail {
		fmt.Fprintln(stderr, "doctor: one or more checks FAILed — see above")
		return errors.New("doctor reported failures")
	}
	return nil
}

// pklVersion runs `pkl --version` and returns the trimmed first token of
// the first line (`Pkl 0.31.1` → `0.31.1`). Cheap probe; the CLI prints
// the same shape across releases.
func pklVersion(path string) (string, error) {
	out, err := exec.Command(path, "--version").Output()
	if err != nil {
		return "", err
	}
	line := strings.SplitN(strings.TrimSpace(string(out)), "\n", 2)[0]
	parts := strings.Fields(line)
	if len(parts) < 2 {
		return line, nil
	}
	return parts[1], nil
}

// cacheStats walks `dir` and returns the total file size plus a
// rough "entry count" (number of regular files at the cas/ leaf). Used
// only for the doctor display, so accuracy matters less than speed.
func cacheStats(dir string) (size int64, count int) {
	filepath.Walk(dir, func(_ string, info os.FileInfo, err error) error {
		if err != nil || info == nil {
			return nil
		}
		if !info.IsDir() {
			size += info.Size()
			count++
		}
		return nil
	})
	return
}

// humanBytes renders a byte count as a short human string (KB/MB/GB).
// Uses 1024 bases because the doctor output already aims at developer
// eyeballs, not marketers.
func humanBytes(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for x := n / unit; x >= unit; x /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(n)/float64(div), "KMGTPE"[exp])
}

// scanAmends greps the first `amends "..."` line of a Pkl file. We
// deliberately don't re-evaluate the module here — doctor must stay
// fast even when the schema URL is unreachable.
func scanAmends(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "amends ") {
			if start := strings.Index(line, "\""); start >= 0 {
				if end := strings.Index(line[start+1:], "\""); end >= 0 {
					return line[start+1 : start+1+end]
				}
			}
			return line
		}
	}
	return ""
}

// cmdUp starts every `service: true` task in the target's subgraph. Non-
// service tasks in the subgraph (e.g. a build step the service depends on)
// run first via the regular orchestrator. Once all pre-tasks succeed,
// services start concurrently and stay alive until the parent context is
// cancelled (Ctrl+C, SIGTERM) or, with --watch, until input changes
// trigger a stop-rebuild-restart cycle.
//
// On shutdown, runner sends SIGTERM to each service's process group, waits
// up to its `shutdownTimeoutSeconds`, then escalates to SIGKILL — so a
// `cmd = "node server.js"` style service does not leak its node child.
func cmdUp(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("pkf up", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	file := newFileFlag(fs)
	watch := fs.Bool("watch", false, "restart services on input changes")
	noCache := fs.Bool("no-cache", false, "disable cache for the pre-service tasks")
	jobs := fs.Int("j", 0, "max concurrent pre-service tasks (default: NumCPU)")
	fs.IntVar(jobs, "jobs", 0, "max concurrent pre-service tasks (default: NumCPU)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	rest := fs.Args()
	if len(rest) != 1 {
		return fmt.Errorf("up requires exactly one task name")
	}
	target := rest[0]

	abs, err := resolveFile(fs, *file)
	if err != nil {
		return err
	}
	parentCtx := context.Background()
	tf, err := config.Load(parentCtx, abs)
	if err != nil {
		return err
	}
	g, err := buildGraph(tf)
	if err != nil {
		return err
	}
	if !g.Has(target) {
		return fmt.Errorf("unknown task: %q", target)
	}
	order, err := g.Subgraph(target)
	if err != nil {
		return err
	}

	var preOrder, services []string
	serviceSet := make(map[string]bool)
	for _, name := range order {
		if tf.Tasks[name].Service {
			services = append(services, name)
			serviceSet[name] = true
		} else {
			preOrder = append(preOrder, name)
		}
	}
	if len(services) == 0 {
		return fmt.Errorf("plan for %q contains no service task; use `pkf run` instead", target)
	}
	// Pre-service tasks may legitimately list services in their `deps`
	// (the canonical pattern is `local dev = new Task { deps { db; api;
	// web } }` as a `pkf up dev` aggregator). Strip service deps from
	// the prePlan's task copies so orchestrator.Execute doesn't error
	// on references it can't satisfy — services are owned by `pkf up`,
	// not by the orchestrator's plan walker.
	prePlanTasks := make(map[string]*config.Task, len(preOrder))
	for _, name := range preOrder {
		orig := tf.Tasks[name]
		copy := *orig
		copy.Deps = nil
		for _, d := range orig.Deps {
			if !serviceSet[d] {
				copy.Deps = append(copy.Deps, d)
			}
		}
		prePlanTasks[name] = &copy
	}

	root := filepath.Dir(abs)
	var backend cache.Backend
	if !*noCache {
		dir, err := cache.DefaultDir()
		if err != nil {
			return fmt.Errorf("resolve cache dir: %w", err)
		}
		local := cache.New(dir)
		if remoteURL := os.Getenv("PKFIRE_REMOTE_CACHE"); remoteURL != "" {
			remote := cache.NewRemote(remoteURL, os.Getenv("PKFIRE_REMOTE_TOKEN"))
			backend = cache.NewLayered(local, remote)
		} else {
			backend = local
		}
	}
	r := runner.New(runner.Options{Workdir: root})
	orch := orchestrator.New(backend, r, stdout, stderr, orchestrator.Options{Parallelism: *jobs})

	prePlan := &orchestrator.Plan{
		Order:      preOrder,
		Tasks:      prePlanTasks,
		Defaults:   tf.Defaults,
		Root:       root,
		ConfigHash: hash.HashBytes(tf.Canonical),
	}

	ctx, cancel := signal.NotifyContext(parentCtx, os.Interrupt, syscall.SIGTERM)
	defer cancel()

	fullPlan := &orchestrator.Plan{
		Order: order, Tasks: tf.Tasks, Defaults: tf.Defaults, Root: root,
		ConfigHash: prePlan.ConfigHash,
	}
	if *watch {
		return runUpWatch(ctx, abs, root, fullPlan, orch, prePlan, services, stderr)
	}
	return runUpOnce(ctx, orch, fullPlan, prePlan, services, stderr)
}

// runningService tracks a single live service so the watch loop can
// reconcile per-service: if the service's action key hasn't changed
// after a file event, leave the process alone; if it has changed,
// stop just that service and start it again with the new key.
type runningService struct {
	name string
	stop func() // nil for reused services (nothing to tear down on our end)
	key  [32]byte
}

// runUpOnce runs the pre-service tasks (build, codegen, etc.) once,
// then starts each service through orchestrator.StartSingleService —
// which honors readyPort/readyCmd reuse and gates dependents on
// readiness — and blocks until the context is cancelled. On Ctrl+C
// (or watch-driven restart of the whole session) the per-service
// stop funcs run in reverse order.
func runUpOnce(ctx context.Context, orch *orchestrator.Orchestrator, fullPlan, prePlan *orchestrator.Plan, services []string, stderr io.Writer) error {
	if len(prePlan.Order) > 0 {
		if _, err := orch.Execute(ctx, prePlan); err != nil {
			return err
		}
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	fmt.Fprintf(stderr, "[pkf] up: starting %d service(s) — Ctrl+C to stop\n", len(services))

	running, err := startAllServices(ctx, orch, fullPlan, services)
	if err != nil {
		stopServices(running)
		return err
	}
	defer stopServices(running)

	<-ctx.Done()
	return nil
}

// runUpWatch maintains a per-service running state. On every input
// event, the pre-service plan is re-executed (cache hits skip
// unchanged steps) and every service's action key is recomputed: a
// service whose key changed is stopped and restarted; everything else
// keeps running. This is the meaningful difference from a naïve
// "stop everything, start everything" loop — when only `src/api/*`
// changes, only `api` restarts, and `db`'s 15-second crash-recovery
// window doesn't show up on every save.
//
// Limitation: Taskfile.pkl itself is NOT reloaded between
// iterations. Editing the Taskfile during `pkf up --watch` is
// effectively a no-op for the running services; restart pkf to pick
// up schema-level changes.
func runUpWatch(parentCtx context.Context, taskfilePath, root string, fullPlan *orchestrator.Plan, orch *orchestrator.Orchestrator, prePlan *orchestrator.Plan, services []string, stderr io.Writer) error {
	paths := watchTargets(root, taskfilePath, fullPlan)
	w, err := watcher.New(paths, 200*time.Millisecond)
	if err != nil {
		return fmt.Errorf("init watcher: %w", err)
	}
	defer w.Close()
	go w.Run(parentCtx)

	fmt.Fprintf(stderr, "[pkf] up --watch: watching %d path(s) (Ctrl+C to stop)\n", len(paths))

	running, err := initialUp(parentCtx, orch, fullPlan, prePlan, services, stderr)
	if err != nil {
		stopServices(running)
		return err
	}
	defer stopServices(running)

	for {
		select {
		case <-w.Events():
			drain(w.Events())
			fmt.Fprintln(stderr, "[pkf] change detected — reconciling services")
			if _, err := orch.Execute(parentCtx, prePlan); err != nil {
				fmt.Fprintf(stderr, "[pkf] pre-service tasks failed: %v\n", err)
				continue
			}
			if err := reconcileServices(parentCtx, orch, fullPlan, services, running, stderr); err != nil {
				fmt.Fprintf(stderr, "[pkf] reconcile failed: %v\n", err)
			}
		case <-parentCtx.Done():
			return nil
		}
	}
}

// initialUp runs the pre-service plan, then starts every service from
// scratch. Returns the slice of running entries in start order so
// stopServices can reap them in reverse on shutdown.
func initialUp(ctx context.Context, orch *orchestrator.Orchestrator, fullPlan, prePlan *orchestrator.Plan, services []string, stderr io.Writer) ([]*runningService, error) {
	if len(prePlan.Order) > 0 {
		if _, err := orch.Execute(ctx, prePlan); err != nil {
			return nil, err
		}
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	fmt.Fprintf(stderr, "[pkf] up: starting %d service(s) — Ctrl+C to stop\n", len(services))
	return startAllServices(ctx, orch, fullPlan, services)
}

// startAllServices launches each service in declared order, attaching
// its current action key. Returns whatever has been started so far
// even if an entry fails — the caller passes that slice to
// stopServices to cleanly reap partial state.
func startAllServices(ctx context.Context, orch *orchestrator.Orchestrator, fullPlan *orchestrator.Plan, services []string) ([]*runningService, error) {
	running := make([]*runningService, 0, len(services))
	for _, name := range services {
		key, err := serviceKey(fullPlan, name)
		if err != nil {
			return running, err
		}
		stop, err := orch.StartSingleService(ctx, name, fullPlan)
		if err != nil {
			return running, err
		}
		running = append(running, &runningService{name: name, stop: stop, key: key})
	}
	return running, nil
}

// reconcileServices walks `services`, recomputes each entry's action
// key, and restarts any whose key has changed. Service order is
// preserved so dependents land on top of their (possibly restarted)
// upstreams in declared topological order.
func reconcileServices(ctx context.Context, orch *orchestrator.Orchestrator, fullPlan *orchestrator.Plan, services []string, running []*runningService, stderr io.Writer) error {
	byName := make(map[string]*runningService, len(running))
	for _, r := range running {
		byName[r.name] = r
	}
	for _, name := range services {
		newKey, err := serviceKey(fullPlan, name)
		if err != nil {
			return err
		}
		entry := byName[name]
		if entry != nil && entry.key == newKey {
			continue
		}
		if entry != nil {
			fmt.Fprintf(stderr, "[pkf] %s: action key changed — restarting\n", name)
			if entry.stop != nil {
				entry.stop()
			}
			entry.stop = nil
		}
		stop, err := orch.StartSingleService(ctx, name, fullPlan)
		if err != nil {
			return err
		}
		if entry == nil {
			running = append(running, &runningService{name: name, stop: stop, key: newKey})
		} else {
			entry.stop = stop
			entry.key = newKey
		}
	}
	return nil
}

// serviceKey computes the action key (BLAKE3 over cmd/env/inputs/etc.
// plus the Pkl module's canonical form) used to decide whether a
// service should be restarted.
func serviceKey(p *orchestrator.Plan, name string) ([32]byte, error) {
	t, ok := p.Tasks[name]
	if !ok {
		return [32]byte{}, fmt.Errorf("service %q not in plan", name)
	}
	taskRoot := orchestrator.TaskRoot(t, p.Root)
	// Services in `pkf up` never receive caller args/params (those
	// are scoped to `pkf run`), so the invocation is always nil here.
	return orchestrator.ComputeKey(t, p.Defaults, taskRoot, p.ConfigHash, nil)
}

// stopServices reaps every running entry in reverse start order. nil
// stop funcs (reused services) are skipped — those processes belong
// to whoever started them in the first place.
func stopServices(running []*runningService) {
	for i := len(running) - 1; i >= 0; i-- {
		if running[i].stop != nil {
			running[i].stop()
			running[i].stop = nil
		}
	}
}

// printDryRun walks the plan in topological order and reports what
// would happen at run time without touching files or processes:
//
//   - hit       — cache lookup succeeds, restore-from-CAS path
//   - will run  — cache miss or task.Cache = true but never run before
//   - uncached  — task.Cache = false (always runs, never stored)
//   - service   — task.Service = true (rejected by `pkf run`; preview only)
//
// When --no-cache or --refresh is set, the cache-lookup path is
// inert so every cacheable task shows as "will run". `inv` carries
// the per-invocation overlay (params / tail args) for the target
// task so its action key matches what Execute would compute.
func printDryRun(stdout io.Writer, root string, tf *config.Taskfile, order []string, target string, inv *runner.Invocation, skipCacheLookup bool) error {
	configHash := hash.HashBytes(tf.Canonical)

	// Try to open the local cache for hit/miss prediction. A missing
	// cache directory is fine — we just predict everything as "will
	// run". Remote cache is intentionally not consulted here: it would
	// turn a quick dry-run into a network round-trip per task.
	var local *cache.Cache
	if !skipCacheLookup {
		if dir, err := cache.DefaultDir(); err == nil {
			local = cache.New(dir)
		}
	}

	type row struct {
		status   string
		shortKey string
		name     string
		cmd      string
		note     string
	}
	rows := make([]row, 0, len(order))
	hits, runs, uncached, services := 0, 0, 0, 0

	for _, name := range order {
		t := tf.Tasks[name]
		var taskInv *runner.Invocation
		if name == target {
			taskInv = inv
		}

		r := row{name: name, cmd: oneLine(t.Cmd)}

		switch {
		case t.Service:
			r.status = "service"
			r.note = "pkf up only"
			services++
		case !t.Cache:
			r.status = "uncached"
			uncached++
		default:
			taskRoot := orchestrator.TaskRoot(t, root)
			key, err := orchestrator.ComputeKey(t, tf.Defaults, taskRoot, configHash, taskInv)
			if err != nil {
				return fmt.Errorf("compute key for %q: %w", name, err)
			}
			r.shortKey = hash.FormatKey(key)[:12]
			if local != nil && local.Has(key) {
				r.status = "hit"
				hits++
			} else {
				r.status = "will run"
				runs++
			}
		}
		if taskInv != nil && (len(taskInv.Args) > 0 || len(taskInv.Params) > 0) {
			r.note = oneLine(invocationSummary(taskInv))
		}
		rows = append(rows, r)
	}

	// Width pass for alignment.
	statusW, keyW, nameW := len("status"), 12, len("task")
	for _, r := range rows {
		if len(r.status) > statusW {
			statusW = len(r.status)
		}
		if len(r.name) > nameW {
			nameW = len(r.name)
		}
	}
	fmt.Fprintf(stdout, "plan for %q (%d task%s):\n\n", target, len(order), plural(len(order)))
	fmt.Fprintf(stdout, "  %-*s  %-*s  %-*s  %s\n", statusW, "status", keyW, "action key", nameW, "task", "cmd")
	fmt.Fprintf(stdout, "  %s  %s  %s  %s\n",
		strings.Repeat("-", statusW),
		strings.Repeat("-", keyW),
		strings.Repeat("-", nameW),
		strings.Repeat("-", 40))
	for _, r := range rows {
		fmt.Fprintf(stdout, "  %-*s  %-*s  %-*s  %s\n",
			statusW, r.status, keyW, r.shortKey, nameW, r.name, r.cmd)
		if r.note != "" {
			fmt.Fprintf(stdout, "  %-*s  %-*s  %-*s  ↳ %s\n",
				statusW, "", keyW, "", nameW, "", r.note)
		}
	}
	fmt.Fprintf(stdout, "\nsummary: %d hit · %d will run · %d uncached", hits, runs, uncached)
	if services > 0 {
		fmt.Fprintf(stdout, " · %d service%s", services, plural(services))
	}
	fmt.Fprintln(stdout)
	if skipCacheLookup {
		fmt.Fprintln(stdout, "note: --no-cache / --refresh active — every cacheable task forced to `will run`")
	}
	return nil
}

// oneLine collapses a multi-line cmd to a single readable line with
// a length cap, so the dry-run table stays one row per task.
func oneLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i] + " …"
	}
	const max = 60
	if len(s) > max {
		s = s[:max-1] + "…"
	}
	return s
}

// invocationSummary renders the per-invocation overlay (tail args +
// resolved params) in a single line for the dry-run note column.
func invocationSummary(inv *runner.Invocation) string {
	var parts []string
	keys := make([]string, 0, len(inv.Params))
	for k := range inv.Params {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		parts = append(parts, fmt.Sprintf("%s=%s", k, inv.Params[k]))
	}
	if len(inv.Args) > 0 {
		parts = append(parts, "-- "+strings.Join(inv.Args, " "))
	}
	return strings.Join(parts, ", ")
}

func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}
