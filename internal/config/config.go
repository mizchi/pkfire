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
	ShellFlags             []string          `pkl:"shellFlags"`
	Inputs                 []string          `pkl:"inputs"`
	Outputs                []string          `pkl:"outputs"`
	Deps                   []string          `pkl:"deps"`
	Env                    map[string]string `pkl:"env"`
	Tools                  map[string]string `pkl:"tools"`
	Cache                  bool              `pkl:"cache"`
	Workdir                *string           `pkl:"workdir"`
	Description            *string           `pkl:"description"`
	Visibility             string            `pkl:"visibility"`
	Quiet                  bool              `pkl:"quiet"`
	Service                bool              `pkl:"service"`
	ShutdownTimeoutSeconds int               `pkl:"shutdownTimeoutSeconds"`
	Services               []string          `pkl:"services"`
	ReadyPort              int               `pkl:"readyPort"`
	ReadyCmd               string            `pkl:"readyCmd"`
	ReadyTimeoutSeconds    int               `pkl:"readyTimeoutSeconds"`
	InheritEnv             bool              `pkl:"inheritEnv"`
	AcceptsArgs            bool              `pkl:"acceptsArgs"`
	Params                 []*Param          `pkl:"params"`
}

// Param mirrors `pkfire.Taskfile#Param`. A param's resolved value is
// exposed to `cmd` as $NAME (uppercased) at run time.
type Param struct {
	Name        string   `pkl:"name"`
	Type        string   `pkl:"type"`
	Choices     []string `pkl:"choices"`
	Default     *string  `pkl:"default"`
	Description *string  `pkl:"description"`
}

// WorkflowTest mirrors `pkfire.Taskfile#WorkflowTest`. It lets a Taskfile
// assert how simulated changed files should map to an affected run plan.
type WorkflowTest struct {
	Name    string   `pkl:"name"`
	Changed []string `pkl:"changed"`
	Tasks   []string `pkl:"tasks"`
	Direct  []string `pkl:"direct"`
}

// Defaults mirrors `pkfire.Taskfile#Defaults`.
type Defaults struct {
	Shell      string            `pkl:"shell"`
	ShellFlags []string          `pkl:"shellFlags"`
	Env        map[string]string `pkl:"env"`
}

// Taskfile is the decoded top-level module.
//
// `Canonical` is populated by Load with the Pkl module's canonical form
// (PCF). It is not decoded from Pkl — the field tag is empty so pkl-go
// skips it. Phase 3 hashes this as part of the task action key so any
// change to the underlying Pkl invalidates caches.
type Taskfile struct {
	Defaults      *Defaults        `pkl:"defaults"`
	TaskOrder     []string         `pkl:"taskOrder"`
	Tasks         map[string]*Task `pkl:"tasks"`
	WorkflowTests []*WorkflowTest  `pkl:"workflowTests"`
	Canonical     []byte           `pkl:"-"`
}

// pkl-go decodes typed Pkl values into Go structs by class-name lookup;
// `EvaluateOutputValue` rejects anonymous targets, so we explicitly map
// each schema class. Keep this in sync with `pkl/Taskfile.pkl`.
func init() {
	pkl.RegisterMapping("pkfire.Taskfile#Rendered", Taskfile{})
	pkl.RegisterMapping("pkfire.Taskfile#Defaults", Defaults{})
	pkl.RegisterMapping("pkfire.Taskfile#RenderedTask", Task{})
	pkl.RegisterMapping("pkfire.Taskfile#RenderedParam", Param{})
	pkl.RegisterMapping("pkfire.Taskfile#RenderedWorkflowTest", WorkflowTest{})
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

// ResolveShell returns the shell binary a task should use after applying
// Go-side fallbacks for hand-constructed Task values in tests and tools.
func ResolveShell(task *Task, defaults *Defaults) string {
	if task != nil && task.Shell != "" {
		return task.Shell
	}
	if defaults != nil && defaults.Shell != "" {
		return defaults.Shell
	}
	return "bash"
}

// ResolveShellFlags returns a copy of the flags passed before the script
// argument. Empty means "unspecified" in Go structs, so it falls back to
// defaults and then to the schema-compatible `-c`.
func ResolveShellFlags(task *Task, defaults *Defaults) []string {
	if task != nil && len(task.ShellFlags) > 0 {
		return append([]string(nil), task.ShellFlags...)
	}
	if defaults != nil && len(defaults.ShellFlags) > 0 {
		return append([]string(nil), defaults.ShellFlags...)
	}
	return []string{"-c"}
}
