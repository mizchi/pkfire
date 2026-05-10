// Package config loads `Taskfile.pkl` via pkl-go and exposes typed values
// to the rest of the runner.
//
// The Go structs mirror the Pkl `Task` / `Defaults` schema in
// `pkl/Taskfile.pkl`. Field tags use pkl-go's `pkl:"..."` form.
package config

import (
	"context"
	"errors"
	"fmt"

	"github.com/apple/pkl-go/pkl"
)

// Task mirrors `pkfire.Taskfile#Task` from `pkl/Taskfile.pkl`.
type Task struct {
	Cmd                    string            `pkl:"cmd"`
	Shell                  string            `pkl:"shell"`
	Inputs                 []string          `pkl:"inputs"`
	Outputs                []string          `pkl:"outputs"`
	Deps                   []string          `pkl:"deps"`
	Env                    map[string]string `pkl:"env"`
	Tools                  map[string]string `pkl:"tools"`
	Cache                  bool              `pkl:"cache"`
	Workdir                *string           `pkl:"workdir"`
	Description            *string           `pkl:"description"`
	Service                bool              `pkl:"service"`
	ShutdownTimeoutSeconds int               `pkl:"shutdownTimeoutSeconds"`
	Services               []string          `pkl:"services"`
}

// Defaults mirrors `pkfire.Taskfile#Defaults`.
type Defaults struct {
	Shell string            `pkl:"shell"`
	Env   map[string]string `pkl:"env"`
}

// Taskfile is the decoded top-level module.
//
// `Canonical` is populated by Load with the Pkl module's canonical form
// (PCF). It is not decoded from Pkl — the field tag is empty so pkl-go
// skips it. Phase 3 hashes this as part of the task action key so any
// change to the underlying Pkl invalidates caches.
type Taskfile struct {
	Defaults  *Defaults        `pkl:"defaults"`
	Tasks     map[string]*Task `pkl:"tasks"`
	Canonical []byte           `pkl:"-"`
}

// pkl-go decodes typed Pkl values into Go structs by class-name lookup;
// `EvaluateOutputValue` rejects anonymous targets, so we explicitly map
// each schema class. Keep this in sync with `pkl/Taskfile.pkl`.
func init() {
	pkl.RegisterMapping("pkfire.Taskfile#Rendered", Taskfile{})
	pkl.RegisterMapping("pkfire.Taskfile#Defaults", Defaults{})
	pkl.RegisterMapping("pkfire.Taskfile#RenderedTask", Task{})
}

// Load evaluates the Pkl module at `path` and decodes it into a Taskfile.
// An empty `tasks` mapping is rejected here (the Pkl schema deliberately
// allows it to keep evaluation possible even before the user has filled
// anything in).
func Load(ctx context.Context, path string) (*Taskfile, error) {
	ev, err := pkl.NewEvaluator(ctx, pkl.PreconfiguredOptions)
	if err != nil {
		return nil, fmt.Errorf("init pkl evaluator: %w", err)
	}
	defer ev.Close()

	src := pkl.FileSource(path)
	// The schema renders `output.value` as a `Rendered` instance. pkl-go
	// looks up the matching Go type via the package-level RegisterMapping
	// (Rendered → Taskfile) and constructs a *Taskfile, so we receive it
	// through a **Taskfile target rather than passing a value.
	var tf *Taskfile
	if err := ev.EvaluateOutputValue(ctx, src, &tf); err != nil {
		return nil, fmt.Errorf("evaluate %s: %w", path, err)
	}
	if tf == nil {
		return nil, errors.New("Taskfile evaluation returned no value")
	}
	if len(tf.Tasks) == 0 {
		return nil, errors.New("Taskfile declares no tasks")
	}
	canonical, err := ev.EvaluateOutputBytes(ctx, src)
	if err != nil {
		return nil, fmt.Errorf("canonicalize %s: %w", path, err)
	}
	tf.Canonical = canonical
	return tf, nil
}
