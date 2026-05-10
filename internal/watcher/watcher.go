// Package watcher tracks filesystem changes that should re-trigger the
// runner. It receives a list of paths (files and directories under a root),
// expands directories recursively, and emits a single deduplicated event on
// `Events()` per debounce window.
package watcher

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/fsnotify/fsnotify"
)

// Watcher debounces filesystem notifications under a fixed set of roots.
//
// Each entry in `paths` is treated as either a file (watch its parent dir
// and accept events whose name equals the file) or a directory (watch the
// directory recursively and accept events for any path under it). Events
// for paths outside the allow set are dropped — that prevents siblings
// like a redirected `> log.txt` from firing spurious re-runs.
type Watcher struct {
	fsw      *fsnotify.Watcher
	allowed  []string
	events   chan struct{}
	debounce time.Duration
}

// New attaches an fsnotify watcher to the parent directory of each entry in
// `paths` (or the directory itself when an entry is a directory). `debounce`
// is how long to wait after the last change before emitting an event. Use
// `Close` to release resources. Missing paths are ignored.
func New(paths []string, debounce time.Duration) (*Watcher, error) {
	if debounce <= 0 {
		debounce = 200 * time.Millisecond
	}
	fsw, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, fmt.Errorf("init fsnotify: %w", err)
	}

	dirs := make(map[string]struct{})
	allowed := make(map[string]struct{})
	for _, p := range paths {
		clean := filepath.Clean(p)
		info, err := os.Stat(clean)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				// Tolerate missing inputs: only register a watch on the
				// parent if it exists, so the file can still be detected
				// when it is later created.
				parent := filepath.Dir(clean)
				if _, parentErr := os.Stat(parent); parentErr == nil {
					dirs[parent] = struct{}{}
				}
				allowed[clean] = struct{}{}
				continue
			}
			fsw.Close()
			return nil, fmt.Errorf("stat %q: %w", clean, err)
		}
		if info.IsDir() {
			err := filepath.WalkDir(clean, func(path string, d os.DirEntry, err error) error {
				if err != nil {
					if errors.Is(err, os.ErrNotExist) {
						return nil
					}
					return err
				}
				if d.IsDir() {
					dirs[path] = struct{}{}
				}
				return nil
			})
			if err != nil {
				fsw.Close()
				return nil, fmt.Errorf("walk %q: %w", clean, err)
			}
			allowed[clean] = struct{}{}
		} else {
			allowed[clean] = struct{}{}
			dirs[filepath.Dir(clean)] = struct{}{}
		}
	}
	for d := range dirs {
		if err := fsw.Add(d); err != nil {
			fsw.Close()
			return nil, fmt.Errorf("watch %q: %w", d, err)
		}
	}
	allowedList := make([]string, 0, len(allowed))
	for p := range allowed {
		allowedList = append(allowedList, p)
	}
	return &Watcher{fsw: fsw, allowed: allowedList, events: make(chan struct{}, 1), debounce: debounce}, nil
}

// Run pumps events until ctx is cancelled. Filesystem events arrive at any
// rate; Run coalesces them into a single notification on `Events()` after
// `debounce` of quiet. Returns ctx.Err() on shutdown.
func (w *Watcher) Run(ctx context.Context) error {
	var timer *time.Timer
	stopTimer := func() {
		if timer != nil {
			timer.Stop()
			timer = nil
		}
	}
	defer stopTimer()

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case ev, ok := <-w.fsw.Events:
			if !ok {
				return errors.New("watcher closed")
			}
			if isNoise(ev) {
				continue
			}
			if !w.matches(ev.Name) {
				continue
			}
			stopTimer()
			timer = time.AfterFunc(w.debounce, func() {
				select {
				case w.events <- struct{}{}:
				default:
				}
			})
		case err, ok := <-w.fsw.Errors:
			if !ok {
				return errors.New("watcher errors closed")
			}
			return err
		}
	}
}

// Events returns the coalesced event channel.
func (w *Watcher) Events() <-chan struct{} { return w.events }

// Close releases the underlying fsnotify watcher.
func (w *Watcher) Close() error { return w.fsw.Close() }

// matches reports whether `path` is one of the allow-listed entries or
// lives inside an allow-listed directory.
func (w *Watcher) matches(path string) bool {
	clean := filepath.Clean(path)
	for _, a := range w.allowed {
		if clean == a {
			return true
		}
		if strings.HasPrefix(clean, a+string(filepath.Separator)) {
			return true
		}
	}
	return false
}

// isNoise filters editor-noise events that would otherwise cause spurious
// re-runs. Chmod-only events are common during atomic writes; we still want
// to fire on Create/Write/Remove/Rename.
func isNoise(ev fsnotify.Event) bool {
	return ev.Op&(fsnotify.Create|fsnotify.Write|fsnotify.Remove|fsnotify.Rename) == 0
}
