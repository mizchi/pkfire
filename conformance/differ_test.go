package conformance

import "testing"

func TestJSONEqualIdentical(t *testing.T) {
	a := []byte(`{"tasks":[{"name":"a"},{"name":"b"}]}`)
	if diff := DiffJSON(a, a, nil); diff != "" {
		t.Errorf("identical JSON reported diff: %s", diff)
	}
}

func TestJSONEqualOrderSensitiveByDefault(t *testing.T) {
	a := []byte(`{"tasks":[{"name":"a"},{"name":"b"}]}`)
	b := []byte(`{"tasks":[{"name":"b"},{"name":"a"}]}`)
	if diff := DiffJSON(a, b, nil); diff == "" {
		t.Error("reordered array should differ when path not in unorderedPaths")
	}
}

func TestJSONEqualUnorderedPath(t *testing.T) {
	a := []byte(`{"edges":[{"from":"a"},{"from":"b"}]}`)
	b := []byte(`{"edges":[{"from":"b"},{"from":"a"}]}`)
	if diff := DiffJSON(a, b, []string{"edges"}); diff != "" {
		t.Errorf("reordered array under unordered path reported diff: %s", diff)
	}
}

func TestJSONEqualValueMismatch(t *testing.T) {
	a := []byte(`{"cache":true}`)
	b := []byte(`{"cache":false}`)
	if diff := DiffJSON(a, b, nil); diff == "" {
		t.Error("value mismatch should produce a diff")
	}
}
