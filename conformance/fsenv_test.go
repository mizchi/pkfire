package conformance

import "testing"

func TestFSDeltaDetectsWrite(t *testing.T) {
	before := map[string]string{"a.txt": "h1"}
	after := map[string]string{"a.txt": "h1", "b.txt": "h2"}
	got := DeltaPaths(before, after)
	if len(got) != 1 || got[0] != "b.txt" {
		t.Errorf("delta = %v, want [b.txt]", got)
	}
}

func TestFSDeltaDetectsModify(t *testing.T) {
	before := map[string]string{"a.txt": "h1"}
	after := map[string]string{"a.txt": "h2"}
	got := DeltaPaths(before, after)
	if len(got) != 1 || got[0] != "a.txt" {
		t.Errorf("delta = %v, want [a.txt]", got)
	}
}
