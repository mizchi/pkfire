// Command pkf is the pkfire CLI: a typed task runner that loads `Taskfile.pkl`
// and executes tasks with Bazel-style content-addressed caching.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

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
	"watch": true, "dry-run": true, "print-hash": true, "no-cache": true, "refresh": true,
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
	case "fmt":
		return cmdFmt(args[1:], stdout, stderr)
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
  run [-f FILE] [-j N] [--watch] [--dry-run] [--print-hash] [--no-cache|--refresh] <task>
                                        run a task and its transitive deps
  up  [-f FILE] [-j N] [--watch] <task> start every service in <task>'s subgraph;
                                        Ctrl+C releases the whole process tree
  list [-f FILE] [-v] [--json]          list declared tasks (-v: cmd/deps; --json: machine-readable)
  graph [-f FILE] [--format FMT] [--target TASK]
                                        emit DAG (formats: dot, mermaid)
  doctor [-f FILE]                      diagnose pkfire setup (pkl/cache/remote/taskfile)
  fmt [-f FILE] [--check] [PATH...]     pkl format -w (no PATH = the Taskfile's directory)
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
	// Split args so we can position-anchor on the task name: anything
	// before it is a global flag, everything after is task-scoped
	// (param flags + tail `-- a b c`).
	globalArgs, target, postArgs, err := splitRunArgs(args)
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

	inv, err := resolveInvocation(tf.Tasks[target], target, postArgs)
	if err != nil {
		return err
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
		return printDryRun(stdout, tf, order)
	case *printHash:
		return printHashes(stdout, root, tf, order, target, inv)
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
	r := runner.New(runner.Options{Workdir: root})
	orch := orchestrator.New(backend, r, stdout, stderr, orchestrator.Options{
		Parallelism: *jobs,
	})
	plan := &orchestrator.Plan{
		Order:            order,
		Tasks:            tf.Tasks,
		Defaults:         tf.Defaults,
		Root:             root,
		ConfigHash:       hash.HashBytes(tf.Canonical),
		Target:           target,
		TargetInvocation: inv,
		Refresh:          *refresh,
	}
	if *watch {
		return runWatch(ctx, abs, root, target, orch, plan, stderr)
	}
	_, err = orch.Execute(ctx, plan)
	return err
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
func splitRunArgs(args []string) (globalArgs []string, taskName string, taskArgs []string, err error) {
	i := 0
	for i < len(args) {
		a := args[i]
		if !strings.HasPrefix(a, "-") {
			taskName = a
			globalArgs = args[:i]
			taskArgs = args[i+1:]
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
	err = fmt.Errorf("run requires exactly one task name")
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

// cmdFmt is a thin alias for `pkl format`. With no positional args,
// formats the directory containing the discovered Taskfile.pkl — same
// walk-up behavior every other subcommand uses, so `pkf fmt` from a
// nested directory still does the right thing. `--check` flips to
// `pkl format --diff-name-only`, which exits 11 on violations and
// prints the path of each unformatted file (CI-friendly).
func cmdFmt(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("pkf fmt", flag.ContinueOnError)
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

// printDryRun walks the plan in topological order and prints each task's
// cmd, deps, and cache disposition without running anything or touching
// the cache directory.
func printDryRun(stdout io.Writer, tf *config.Taskfile, order []string) error {
	for i, name := range order {
		t := tf.Tasks[name]
		fmt.Fprintf(stdout, "%d. %s\n", i+1, name)
		if t.Description != nil {
			fmt.Fprintf(stdout, "   desc: %s\n", *t.Description)
		}
		fmt.Fprintf(stdout, "   cmd:  %s\n", t.Cmd)
		if len(t.Deps) > 0 {
			fmt.Fprintf(stdout, "   deps: %s\n", strings.Join(t.Deps, ", "))
		}
		if !t.Cache {
			fmt.Fprintf(stdout, "   cache: disabled\n")
		}
		if t.Workdir != nil && *t.Workdir != "" {
			fmt.Fprintf(stdout, "   workdir: %s\n", *t.Workdir)
		}
	}
	return nil
}
