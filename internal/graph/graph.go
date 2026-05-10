// Package graph builds and traverses the task dependency DAG.
//
// A Graph captures the acyclic dependency relationship between named tasks.
// `Order` returns a topological order (deps before dependents); `Subgraph`
// projects the graph onto a single target plus its transitive dependencies.
package graph

import (
	"errors"
	"fmt"
	"sort"
)

// Node is the minimal task shape the DAG cares about. Concrete task data
// (cmd, env, …) lives in the config package; the graph only needs an id and
// its declared dependencies.
type Node struct {
	Name string
	Deps []string
}

// Graph is an immutable view of a validated DAG.
type Graph struct {
	nodes map[string]Node
}

// ErrCycle is returned when the input contains a dependency cycle.
var ErrCycle = errors.New("cycle detected")

// Build validates `nodes` (no duplicate names, no missing deps, no cycles)
// and returns a Graph ready for traversal.
func Build(nodes []Node) (*Graph, error) {
	idx := make(map[string]Node, len(nodes))
	for _, n := range nodes {
		if _, dup := idx[n.Name]; dup {
			return nil, fmt.Errorf("duplicate task: %q", n.Name)
		}
		idx[n.Name] = n
	}
	for _, n := range nodes {
		for _, d := range n.Deps {
			if _, ok := idx[d]; !ok {
				return nil, fmt.Errorf("task %q depends on unknown task %q", n.Name, d)
			}
		}
	}
	if _, err := topoSort(idx); err != nil {
		return nil, err
	}
	return &Graph{nodes: idx}, nil
}

// Names returns all task names in stable (alphabetical) order.
func (g *Graph) Names() []string {
	names := make([]string, 0, len(g.nodes))
	for n := range g.nodes {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// Has reports whether `name` is a task in the graph.
func (g *Graph) Has(name string) bool {
	_, ok := g.nodes[name]
	return ok
}

// Order returns a full topological order over every task in the graph.
// Deps appear before dependents. Among siblings, ordering is alphabetical
// for reproducibility.
func (g *Graph) Order() []string {
	order, _ := topoSort(g.nodes)
	return order
}

// Subgraph returns the topological order of `target` plus all its transitive
// dependencies. Returns an error when the target does not exist.
func (g *Graph) Subgraph(target string) ([]string, error) {
	if _, ok := g.nodes[target]; !ok {
		return nil, fmt.Errorf("unknown task: %q", target)
	}
	keep := make(map[string]Node)
	var walk func(string)
	walk = func(name string) {
		if _, seen := keep[name]; seen {
			return
		}
		n := g.nodes[name]
		keep[name] = n
		for _, d := range n.Deps {
			walk(d)
		}
	}
	walk(target)
	return topoSort(keep)
}

// topoSort returns a deterministic topological order of `nodes` (Kahn's
// algorithm with alphabetical tie-breaking) or ErrCycle if impossible.
func topoSort(nodes map[string]Node) ([]string, error) {
	indeg := make(map[string]int, len(nodes))
	revDeps := make(map[string][]string, len(nodes))
	for name := range nodes {
		indeg[name] = 0
	}
	for name, n := range nodes {
		for _, d := range n.Deps {
			indeg[name]++
			revDeps[d] = append(revDeps[d], name)
		}
	}
	var ready []string
	for name, deg := range indeg {
		if deg == 0 {
			ready = append(ready, name)
		}
	}
	sort.Strings(ready)

	out := make([]string, 0, len(nodes))
	for len(ready) > 0 {
		head := ready[0]
		ready = ready[1:]
		out = append(out, head)
		dependents := append([]string(nil), revDeps[head]...)
		sort.Strings(dependents)
		for _, dep := range dependents {
			indeg[dep]--
			if indeg[dep] == 0 {
				ready = append(ready, dep)
				sort.Strings(ready)
			}
		}
	}
	if len(out) != len(nodes) {
		return nil, ErrCycle
	}
	return out, nil
}
