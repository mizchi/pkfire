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

// A nil (no-change) delta and an empty-slice delta must marshal to the
// same JSON so an fsDelta scenario does not fail on a phantom nil-vs-[]
// type mismatch between golden and candidate.
func TestMarshalDeltaNilAndEmptyEqual(t *testing.T) {
	if got := string(MarshalDelta(nil)); got != "[]" {
		t.Errorf("MarshalDelta(nil) = %q, want []", got)
	}
	if d := DiffJSON(MarshalDelta(nil), MarshalDelta([]string{}), nil); d != "" {
		t.Errorf("nil vs empty delta reported diff: %s", d)
	}
}
