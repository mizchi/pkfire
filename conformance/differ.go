package conformance

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// DiffJSON parses want and got as JSON and returns "" if they are
// deep-equal, or a human-readable description of the first difference.
// Arrays located at a dotted path in unorderedPaths are compared as
// multisets; all other arrays are compared in order.
func DiffJSON(want, got []byte, unorderedPaths []string) string {
	var wv, gv any
	if err := json.Unmarshal(want, &wv); err != nil {
		return fmt.Sprintf("golden is not valid JSON: %v", err)
	}
	if err := json.Unmarshal(got, &gv); err != nil {
		return fmt.Sprintf("candidate stdout is not valid JSON: %v", err)
	}
	set := map[string]bool{}
	for _, p := range unorderedPaths {
		set[p] = true
	}
	return jsonDiff("", wv, gv, set)
}

func jsonDiff(path string, want, got any, unordered map[string]bool) string {
	switch w := want.(type) {
	case map[string]any:
		g, ok := got.(map[string]any)
		if !ok {
			return fmt.Sprintf("%s: type object != %T", pathOrRoot(path), got)
		}
		for k, wval := range w {
			gval, present := g[k]
			if !present {
				return fmt.Sprintf("%s: missing key %q", pathOrRoot(path), k)
			}
			if d := jsonDiff(join(path, k), wval, gval, unordered); d != "" {
				return d
			}
		}
		for k := range g {
			if _, present := w[k]; !present {
				return fmt.Sprintf("%s: unexpected key %q", pathOrRoot(path), k)
			}
		}
		return ""
	case []any:
		g, ok := got.([]any)
		if !ok {
			return fmt.Sprintf("%s: type array != %T", pathOrRoot(path), got)
		}
		if len(w) != len(g) {
			return fmt.Sprintf("%s: array len %d != %d", pathOrRoot(path), len(w), len(g))
		}
		if unordered[path] {
			ws := canonSorted(w)
			gs := canonSorted(g)
			for i := range ws {
				if ws[i] != gs[i] {
					return fmt.Sprintf("%s: unordered element %d differs: %s != %s", pathOrRoot(path), i, ws[i], gs[i])
				}
			}
			return ""
		}
		for i := range w {
			if d := jsonDiff(fmt.Sprintf("%s[%d]", path, i), w[i], g[i], unordered); d != "" {
				return d
			}
		}
		return ""
	default:
		if fmt.Sprintf("%v", want) != fmt.Sprintf("%v", got) {
			return fmt.Sprintf("%s: %v != %v", pathOrRoot(path), want, got)
		}
		return ""
	}
}

func canonSorted(arr []any) []string {
	out := make([]string, len(arr))
	for i, e := range arr {
		b, _ := json.Marshal(e)
		out[i] = string(b)
	}
	sort.Strings(out)
	return out
}

func join(path, key string) string {
	if path == "" {
		return key
	}
	return path + "." + key
}

func pathOrRoot(path string) string {
	if path == "" {
		return "(root)"
	}
	return path
}

// Compare applies a scenario's contract to a candidate Result against a
// Golden, returning "" on match or the first failure description.
func Compare(s Scenario, want Golden, got Result) string {
	if s.Contract.Exit && want.Exit != got.Exit {
		return fmt.Sprintf("exit: want %d, got %d", want.Exit, got.Exit)
	}
	if s.Contract.JSON {
		if d := DiffJSON(want.Stdout, got.Stdout, s.Contract.UnorderedPaths); d != "" {
			return "json: " + d
		}
	}
	for _, sub := range s.Contract.MustContain {
		if !containsNormalized(got.Stdout, sub) {
			return fmt.Sprintf("mustContain: %q not found in normalized stdout", sub)
		}
	}
	return ""
}

// containsNormalized reports whether normalized stdout contains sub.
// Normalization collapses runs of whitespace to a single space and trims
// each line, so wording/spacing/color differences do not cause failures.
func containsNormalized(stdout []byte, sub string) bool {
	return strings.Contains(normalizeText(string(stdout)), normalizeText(sub))
}

func normalizeText(s string) string {
	return strings.Join(strings.Fields(s), " ")
}
