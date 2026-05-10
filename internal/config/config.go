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
	Cmd         string            `pkl:"cmd"`
	Shell       string            `pkl:"shell"`
	Inputs      []string          `pkl:"inputs"`
	Outputs     []string          `pkl:"outputs"`
	Deps        []string          `pkl:"deps"`
	Env         map[string]string `pkl:"env"`
	Tools       map[string]string `pkl:"tools"`
	Cache       bool              `pkl:"cache"`
	Workdir     *string           `pkl:"workdir"`
	Description *string           `pkl:"description"`
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
// skips it during EvaluateModule. Phase 3 hashes this as part of the
// task action key so any change to the underlying Pkl invalidates caches.
type Taskfile struct {
	Defaults  Defaults         `pkl:"defaults"`
	Tasks     map[string]*Task `pkl:"tasks"`
	Canonical []byte           `pkl:"-"`
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

	var tf Taskfile
	src := pkl.FileSource(path)
	if err := ev.EvaluateModule(ctx, src, &tf); err != nil {
		return nil, fmt.Errorf("evaluate %s: %w", path, err)
	}
	if len(tf.Tasks) == 0 {
		return nil, errors.New("Taskfile declares no tasks")
	}
	canonical, err := ev.EvaluateOutputBytes(ctx, src)
	if err != nil {
		return nil, fmt.Errorf("canonicalize %s: %w", path, err)
	}
	tf.Canonical = canonical
	return &tf, nil
}
