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

// Scalar type divergence (number vs string, bool vs string, null vs
// string) is the exact Go-vs-MoonBit JSON drift this harness must catch.
// A %v-stringifying differ would falsely treat these as equal.
func TestJSONEqualScalarTypeMismatch(t *testing.T) {
	cases := []struct {
		name string
		a, b string
	}{
		{"number-vs-string", `{"x":1}`, `{"x":"1"}`},
		{"bool-vs-string", `{"x":true}`, `{"x":"true"}`},
		{"null-vs-string", `{"x":null}`, `{"x":"<nil>"}`},
		{"bool-vs-number", `{"x":true}`, `{"x":1}`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if diff := DiffJSON([]byte(c.a), []byte(c.b), nil); diff == "" {
				t.Errorf("%s: type mismatch reported equal (%s vs %s)", c.name, c.a, c.b)
			}
		})
	}
}
