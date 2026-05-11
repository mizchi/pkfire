// Package hash computes Bazel-style action keys for tasks.
//
// The action key is a BLAKE3 digest over a deterministic, line-oriented
// description of what the task is going to do: shell + cmd + sorted env +
// sorted tools + sorted (path, content-hash) pairs for declared inputs +
// the Pkl module's canonical form.
//
// Two task invocations with the same action key are guaranteed to produce
// the same outputs (assuming the user's `inputs` declaration is honest).
package hash

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"

	"github.com/bmatcuk/doublestar/v4"
	"github.com/zeebo/blake3"
)

// FileEntry pairs an input file path (relative to root) with its content
// digest. Sorted by Path before being fed into the action key.
type FileEntry struct {
	Path string
	Hash []byte
}

// Action carries everything that contributes to a task's identity.
//
// Args and Params are the per-invocation overlay: empty for non-target
// tasks (their action key is solely a function of declared inputs), and
// populated for the explicit target so `pkf run task -- foo` and
// `pkf run task -- bar` produce distinct cache entries.
//
// Profile is the run-wide profile name (`--profile=<name>` on the CLI).
// Empty when no profile is set. Distinct profiles cache as distinct
// entries by design — `pkf run --profile=ci` and `pkf run --profile=dev`
// won't share a cache slot even if every declared field is otherwise
// identical, so a profile-specific cmd branch (`if [ "$PKF_PROFILE" =
// "ci" ]; then ...; fi`) doesn't pollute the other profile's cache.
type Action struct {
	Cmd        string
	Shell      string
	Env        map[string]string
	Tools      map[string]string
	Inputs     []FileEntry
	ConfigHash []byte
	Args       []string
	Params     map[string]string
	Profile    string
}

// Key returns the 32-byte BLAKE3 digest of `a`.
func (a *Action) Key() [32]byte {
	h := blake3.New()
	fmt.Fprintf(h, "cmd:%s\n", a.Cmd)
	fmt.Fprintf(h, "shell:%s\n", a.Shell)
	writeMap(h, "env", a.Env)
	writeMap(h, "tools", a.Tools)
	entries := append([]FileEntry(nil), a.Inputs...)
	sort.Slice(entries, func(i, j int) bool { return entries[i].Path < entries[j].Path })
	for _, f := range entries {
		fmt.Fprintf(h, "in:%s:%x\n", f.Path, f.Hash)
	}
	fmt.Fprintf(h, "config:%x\n", a.ConfigHash)
	for i, v := range a.Args {
		fmt.Fprintf(h, "arg:%d:%s\n", i, v)
	}
	writeMap(h, "param", a.Params)
	if a.Profile != "" {
		fmt.Fprintf(h, "profile:%s\n", a.Profile)
	}
	var out [32]byte
	copy(out[:], h.Sum(nil))
	return out
}

func writeMap(w io.Writer, label string, m map[string]string) {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		fmt.Fprintf(w, "%s:%s=%s\n", label, k, m[k])
	}
}

// HashFile streams the file at `path` through BLAKE3.
func HashFile(path string) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	h := blake3.New()
	if _, err := io.Copy(h, f); err != nil {
		return nil, err
	}
	return h.Sum(nil), nil
}

// HashBytes returns the BLAKE3 digest of `b`.
func HashBytes(b []byte) []byte {
	h := blake3.New()
	h.Write(b)
	return h.Sum(nil)
}

// ExpandInputs resolves the given glob patterns under `root` into a sorted,
// deduplicated list of regular file paths (relative to `root`). Patterns
// support `**` via doublestar.
func ExpandInputs(root string, patterns []string) ([]string, error) {
	rootFS := os.DirFS(root)
	seen := make(map[string]struct{})
	for _, p := range patterns {
		matches, err := doublestar.Glob(rootFS, filepath.ToSlash(p))
		if err != nil {
			return nil, fmt.Errorf("glob %q: %w", p, err)
		}
		for _, m := range matches {
			full := filepath.Join(root, m)
			info, err := os.Stat(full)
			if err != nil {
				return nil, fmt.Errorf("stat %q: %w", full, err)
			}
			if info.IsDir() {
				continue
			}
			seen[m] = struct{}{}
		}
	}
	out := make([]string, 0, len(seen))
	for k := range seen {
		out = append(out, k)
	}
	sort.Strings(out)
	return out, nil
}

// HashInputs expands `patterns` under `root` and returns one FileEntry per
// matched regular file, in sorted-path order.
func HashInputs(root string, patterns []string) ([]FileEntry, error) {
	rels, err := ExpandInputs(root, patterns)
	if err != nil {
		return nil, err
	}
	out := make([]FileEntry, 0, len(rels))
	for _, rel := range rels {
		full := filepath.Join(root, rel)
		h, err := HashFile(full)
		if err != nil {
			return nil, err
		}
		out = append(out, FileEntry{Path: rel, Hash: h})
	}
	return out, nil
}

// FormatKey renders an action key as a lowercase hex string.
func FormatKey(k [32]byte) string {
	var b bytes.Buffer
	fmt.Fprintf(&b, "%x", k[:])
	return b.String()
}

// MergeEnv overlays `task` env over `defaults` env. Returns nil for empty
// inputs to keep struct comparisons stable.
func MergeEnv(defaults, task map[string]string) map[string]string {
	if len(defaults) == 0 && len(task) == 0 {
		return nil
	}
	out := make(map[string]string, len(defaults)+len(task))
	for k, v := range defaults {
		out[k] = v
	}
	for k, v := range task {
		out[k] = v
	}
	return out
}
