package graph_test

import (
	"errors"
	"reflect"
	"testing"

	"github.com/mizchi/pkfire/internal/graph"
)

func mustBuild(t *testing.T, nodes []graph.Node) *graph.Graph {
	t.Helper()
	g, err := graph.Build(nodes)
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	return g
}

func TestOrderLinearChain(t *testing.T) {
	g := mustBuild(t, []graph.Node{
		{Name: "a", Deps: []string{"b"}},
		{Name: "b", Deps: []string{"c"}},
		{Name: "c"},
	})
	got := g.Order()
	want := []string{"c", "b", "a"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("Order = %v, want %v", got, want)
	}
}

func TestOrderDiamondAndAlphabeticalTieBreak(t *testing.T) {
	// d depends on b and c; b and c both depend on a.
	g := mustBuild(t, []graph.Node{
		{Name: "a"},
		{Name: "b", Deps: []string{"a"}},
		{Name: "c", Deps: []string{"a"}},
		{Name: "d", Deps: []string{"b", "c"}},
	})
	got := g.Order()
	want := []string{"a", "b", "c", "d"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("Order = %v, want %v", got, want)
	}
}

func TestSubgraphIncludesOnlyTransitiveDeps(t *testing.T) {
	g := mustBuild(t, []graph.Node{
		{Name: "lint"},
		{Name: "build", Deps: []string{"lint"}},
		{Name: "test", Deps: []string{"build"}},
		{Name: "deploy", Deps: []string{"test"}}, // unrelated to a `build` invocation
	})
	got, err := g.Subgraph("build")
	if err != nil {
		t.Fatalf("Subgraph: %v", err)
	}
	want := []string{"lint", "build"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("Subgraph(build) = %v, want %v", got, want)
	}
}

func TestSubgraphRejectsUnknownTarget(t *testing.T) {
	g := mustBuild(t, []graph.Node{{Name: "a"}})
	if _, err := g.Subgraph("missing"); err == nil {
		t.Fatal("expected error for unknown target")
	}
}

func TestBuildRejectsDuplicate(t *testing.T) {
	_, err := graph.Build([]graph.Node{
		{Name: "a"},
		{Name: "a"},
	})
	if err == nil {
		t.Fatal("expected duplicate error")
	}
}

func TestBuildRejectsMissingDep(t *testing.T) {
	_, err := graph.Build([]graph.Node{
		{Name: "a", Deps: []string{"ghost"}},
	})
	if err == nil {
		t.Fatal("expected unknown-dep error")
	}
}

func TestBuildRejectsCycle(t *testing.T) {
	_, err := graph.Build([]graph.Node{
		{Name: "a", Deps: []string{"b"}},
		{Name: "b", Deps: []string{"a"}},
	})
	if !errors.Is(err, graph.ErrCycle) {
		t.Fatalf("expected ErrCycle, got %v", err)
	}
}

func TestNamesIsSorted(t *testing.T) {
	g := mustBuild(t, []graph.Node{
		{Name: "c"},
		{Name: "a"},
		{Name: "b"},
	})
	got := g.Names()
	want := []string{"a", "b", "c"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("Names = %v, want %v", got, want)
	}
}
