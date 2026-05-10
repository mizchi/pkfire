// Command pkf is the pkfire CLI: a typed task runner that loads `Taskfile.pkl`
// and (eventually) executes tasks with Bazel-style content-addressed caching.
//
// Phase 3 wires loading + DAG + serial execution + action-key calculation.
// Cache restore lands in phase 4; parallel scheduling in phase 5.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"

	"github.com/mizchi/pkfire/internal/cache"
	"github.com/mizchi/pkfire/internal/config"
	"github.com/mizchi/pkfire/internal/graph"
	"github.com/mizchi/pkfire/internal/hash"
	"github.com/mizchi/pkfire/internal/orchestrator"
	"github.com/mizchi/pkfire/internal/runner"
)

const version = "0.0.0"

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
	case "list":
		return cmdList(args[1:], stdout, stderr)
	case "run":
		return cmdRun(args[1:], stdout, stderr)
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
  run [-f FILE] [-j N] [--print-hash] [--no-cache] <task>
                                        run a task and its transitive deps
  list [-f FILE]                        list declared tasks
  version                               print pkf version
  help                                  show this message

flags:
  -f, --file FILE        path to Taskfile.pkl (default: ./Taskfile.pkl)
  -j, --jobs N           max concurrent tasks (default: NumCPU)
      --print-hash       print action keys for the target subgraph and exit
      --no-cache         disable cache lookup and store for this run

cache directory:
  $PKFIRE_CACHE_DIR if set, otherwise $XDG_CACHE_HOME/pkfire (~/.cache/pkfire).
`)
}

func newFileFlag(fs *flag.FlagSet) *string {
	file := fs.String("f", "Taskfile.pkl", "path to Taskfile.pkl")
	fs.StringVar(file, "file", "Taskfile.pkl", "path to Taskfile.pkl")
	return file
}

func cmdList(args []string, stdout, _ io.Writer) error {
	fs := flag.NewFlagSet("pkf list", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	file := newFileFlag(fs)
	if err := fs.Parse(args); err != nil {
		return err
	}
	if len(fs.Args()) > 0 {
		return fmt.Errorf("list takes no positional args, got %v", fs.Args())
	}
	abs, err := filepath.Abs(*file)
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

func cmdRun(args []string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("pkf run", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	file := newFileFlag(fs)
	printHash := fs.Bool("print-hash", false, "print action keys and exit")
	noCache := fs.Bool("no-cache", false, "disable cache for this run")
	jobs := fs.Int("j", 0, "max concurrent tasks (default: NumCPU)")
	fs.IntVar(jobs, "jobs", 0, "max concurrent tasks (default: NumCPU)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	rest := fs.Args()
	if len(rest) != 1 {
		return fmt.Errorf("run requires exactly one task name")
	}
	target := rest[0]

	abs, err := filepath.Abs(*file)
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

	root := filepath.Dir(abs)
	if *printHash {
		return printHashes(stdout, root, tf, order)
	}

	var cas *cache.Cache
	if !*noCache {
		dir, err := cache.DefaultDir()
		if err != nil {
			return fmt.Errorf("resolve cache dir: %w", err)
		}
		cas = cache.New(dir)
	}
	r := runner.New(runner.Options{Workdir: root})
	orch := orchestrator.New(cas, r, stdout, stderr, orchestrator.Options{
		Parallelism: *jobs,
	})
	plan := &orchestrator.Plan{
		Order:      order,
		Tasks:      tf.Tasks,
		Defaults:   &tf.Defaults,
		Root:       root,
		ConfigHash: hash.HashBytes(tf.Canonical),
	}
	_, err = orch.Execute(ctx, plan)
	return err
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
func printHashes(stdout io.Writer, root string, tf *config.Taskfile, order []string) error {
	configHash := hash.HashBytes(tf.Canonical)
	for _, name := range order {
		task := tf.Tasks[name]
		key, err := orchestrator.ComputeKey(task, &tf.Defaults, root, configHash)
		if err != nil {
			return fmt.Errorf("compute key for %q: %w", name, err)
		}
		fmt.Fprintf(stdout, "%s\t%s\n", name, hash.FormatKey(key))
	}
	return nil
}
