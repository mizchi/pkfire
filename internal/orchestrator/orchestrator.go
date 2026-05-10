// Package orchestrator coordinates the cache and the runner: for each task
// in topological order it derives the action key, returns a cached result
// when present, otherwise executes the task and stores the resulting outputs.
package orchestrator

import (
	"context"
	"fmt"
	"io"

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
)

// String renders an Outcome for log lines and debugging.
func (o Outcome) String() string {
	switch o {
	case OutcomeHit:
		return "hit"
	case OutcomeUncached:
		return "ran (uncached)"
	default:
		return "ran"
	}
}

// Result records what happened for one task.
type Result struct {
	Name    string
	Key     [32]byte
	Outcome Outcome
}

// Plan is everything Execute needs that is not the orchestrator's own
// runner/cache. ConfigHash is typically `hash.HashBytes(taskfile.Canonical)`.
type Plan struct {
	Order      []string
	Tasks      map[string]*config.Task
	Defaults   *config.Defaults
	Root       string
	ConfigHash []byte
}

// Orchestrator holds the long-lived runner and (optionally) cache.
// A nil cache disables caching for the whole run.
type Orchestrator struct {
	cache  *cache.Cache
	runner *runner.Runner
	log    io.Writer
}

// New returns an Orchestrator. `log` receives one human-readable line per
// task ("hit"/"ran") and may be io.Discard.
func New(c *cache.Cache, r *runner.Runner, log io.Writer) *Orchestrator {
	if log == nil {
		log = io.Discard
	}
	return &Orchestrator{cache: c, runner: r, log: log}
}

// ComputeKey assembles a `hash.Action` for `task` and returns its action key.
// Exposed so `pkf run --print-hash` can reuse the same logic.
func ComputeKey(task *config.Task, defaults *config.Defaults, root string, configHash []byte) ([32]byte, error) {
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
	return a.Key(), nil
}

// Execute walks the plan's order. Stops on the first task error and
// returns the results gathered so far together with the error.
func (o *Orchestrator) Execute(ctx context.Context, p *Plan) ([]Result, error) {
	results := make([]Result, 0, len(p.Order))
	for _, name := range p.Order {
		task, ok := p.Tasks[name]
		if !ok {
			return results, fmt.Errorf("unknown task: %q", name)
		}
		key, err := ComputeKey(task, p.Defaults, p.Root, p.ConfigHash)
		if err != nil {
			return results, fmt.Errorf("compute key for %q: %w", name, err)
		}
		short := hash.FormatKey(key)[:12]

		if task.Cache && o.cache != nil && o.cache.Has(key) {
			if err := o.cache.Restore(key, p.Root); err != nil {
				return results, fmt.Errorf("cache restore for %q: %w", name, err)
			}
			fmt.Fprintf(o.log, "[pkf] %s: hit %s\n", name, short)
			results = append(results, Result{Name: name, Key: key, Outcome: OutcomeHit})
			continue
		}
		if err := o.runner.Run(ctx, name, task, p.Defaults); err != nil {
			return results, err
		}
		outcome := OutcomeRan
		if !task.Cache {
			outcome = OutcomeUncached
		} else if o.cache != nil && len(task.Outputs) > 0 {
			if err := o.cache.Store(key, p.Root, task.Outputs); err != nil {
				return results, fmt.Errorf("cache store for %q: %w", name, err)
			}
		}
		fmt.Fprintf(o.log, "[pkf] %s: %s %s\n", name, outcome, short)
		results = append(results, Result{Name: name, Key: key, Outcome: outcome})
	}
	return results, nil
}
