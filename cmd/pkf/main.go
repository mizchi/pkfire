// Command pkf is the pkfire CLI: a typed task runner that loads `Taskfile.pkl`
// and (eventually) executes tasks with Bazel-style content-addressed caching.
//
// Phase 1 wires loading + DAG + serial execution. Cache, parallelism, and
// remote storage land in later phases.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"

	"github.com/mizchi/pkfire/internal/config"
	"github.com/mizchi/pkfire/internal/graph"
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
  run [-f FILE] <task>   run a task and its transitive deps
  list [-f FILE]         list declared tasks
  version                print pkf version
  help                   show this message

flags:
  -f, --file FILE        path to Taskfile.pkl (default: ./Taskfile.pkl)
`)
}

func parseFile(args []string) (string, []string, error) {
	fs := flag.NewFlagSet("pkf", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	file := fs.String("f", "Taskfile.pkl", "path to Taskfile.pkl")
	fs.StringVar(file, "file", "Taskfile.pkl", "path to Taskfile.pkl")
	if err := fs.Parse(args); err != nil {
		return "", nil, err
	}
	abs, err := filepath.Abs(*file)
	if err != nil {
		return "", nil, err
	}
	return abs, fs.Args(), nil
}

func cmdList(args []string, stdout, _ io.Writer) error {
	file, rest, err := parseFile(args)
	if err != nil {
		return err
	}
	if len(rest) > 0 {
		return fmt.Errorf("list takes no positional args, got %v", rest)
	}
	tf, err := config.Load(context.Background(), file)
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
	file, rest, err := parseFile(args)
	if err != nil {
		return err
	}
	if len(rest) != 1 {
		return fmt.Errorf("run requires exactly one task name")
	}
	target := rest[0]

	ctx := context.Background()
	tf, err := config.Load(ctx, file)
	if err != nil {
		return err
	}

	nodes := make([]graph.Node, 0, len(tf.Tasks))
	for name, t := range tf.Tasks {
		nodes = append(nodes, graph.Node{Name: name, Deps: append([]string(nil), t.Deps...)})
	}
	g, err := graph.Build(nodes)
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

	r := runner.New(runner.Options{
		Stdout:  stdout,
		Stderr:  stderr,
		Workdir: filepath.Dir(file),
	})
	return r.RunAll(ctx, order, tf.Tasks, &tf.Defaults)
}
