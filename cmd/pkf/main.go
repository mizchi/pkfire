// Command pkf is the pkfire CLI: a typed task runner that loads `Taskfile.pkl`
// and executes tasks with Bazel-style content-addressed caching.
//
// This is the Phase 0 skeleton — only `version` and `list` are wired.
// Real evaluation (pkl-go), DAG construction, and CAS land in later phases.
package main

import (
	"fmt"
	"os"
)

const version = "0.0.0"

func main() {
	args := os.Args[1:]
	if len(args) == 0 {
		usage(os.Stdout)
		return
	}
	switch args[0] {
	case "version", "--version", "-v":
		fmt.Println(version)
	case "help", "--help", "-h":
		usage(os.Stdout)
	case "list":
		fmt.Fprintln(os.Stderr, "list: not implemented yet (phase 1)")
		os.Exit(2)
	case "run":
		fmt.Fprintln(os.Stderr, "run: not implemented yet (phase 1)")
		os.Exit(2)
	default:
		fmt.Fprintf(os.Stderr, "pkf: unknown command %q\n\n", args[0])
		usage(os.Stderr)
		os.Exit(2)
	}
}

func usage(w *os.File) {
	fmt.Fprint(w, `pkf — pkfire task runner

usage:
  pkf <command> [args]

commands:
  run <task>   run a task and its dependencies (phase 1)
  list         list declared tasks            (phase 1)
  version      print pkf version
  help         show this message
`)
}
