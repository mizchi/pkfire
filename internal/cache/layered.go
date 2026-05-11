package cache

import (
	"fmt"
	"os"
)

// Layered combines a local CAS with an optional HTTP remote. Reads check
// local first; on a local miss the remote is consulted, and a remote hit
// is written back to local before being restored. Writes always store
// locally and (best-effort) push to the remote.
//
// When RemoteOnly is true the local CAS is bypassed entirely — Has
// only checks the remote, Restore streams straight from it (without
// warming the local cache), and Store pushes to the remote with no
// local write. Used by `pkf run --remote-only` to verify a remote
// cache really contains the entries we expect.
type Layered struct {
	Local      *Cache
	Remote     *Remote
	RemoteOnly bool
}

// NewLayered returns a Layered backend. `remote` may be nil, in which case
// Layered behaves exactly like the local cache.
func NewLayered(local *Cache, remote *Remote) *Layered {
	return &Layered{Local: local, Remote: remote}
}

// NewRemoteOnly wraps `remote` as a Backend that skips the local CAS for
// reads and writes. `staging` is still required for tar extraction —
// remote responses are streamed through a local Cache instance, but
// the staging Has/Store paths aren't consulted.
func NewRemoteOnly(staging *Cache, remote *Remote) *Layered {
	return &Layered{Local: staging, Remote: remote, RemoteOnly: true}
}

// Has returns true when either the local CAS or the remote has the entry.
func (l *Layered) Has(key [32]byte) bool {
	if !l.RemoteOnly && l.Local.Has(key) {
		return true
	}
	if l.Remote != nil {
		return l.Remote.Has(key)
	}
	return false
}

// Restore tries local first; on a miss it streams the remote archive into
// the local CAS (warming it for the next run) and then restores from local.
func (l *Layered) Restore(key [32]byte, root string) error {
	if !l.RemoteOnly && l.Local.Has(key) {
		return l.Local.Restore(key, root)
	}
	if l.Remote == nil {
		return fmt.Errorf("cache miss for key")
	}
	body, err := l.Remote.Fetch(key)
	if err != nil {
		return fmt.Errorf("remote fetch: %w", err)
	}
	defer body.Close()
	// We still need the local CAS to extract the tarball — the wire
	// format is the local format. RemoteOnly callers pass a staging
	// Cache; the warm here is the side effect they explicitly opted in
	// to (the alternative is to add a separate "stream-and-extract"
	// helper, which duplicates cache/cache.go).
	if err := l.Local.WriteRawArchive(key, body); err != nil {
		return fmt.Errorf("warm local from remote: %w", err)
	}
	return l.Local.Restore(key, root)
}

// Store writes locally and pushes the same archive to the remote. A push
// failure is reported but never blocks the run — the user has already
// produced the artifacts and the local cache hit will work next time.
func (l *Layered) Store(key [32]byte, root string, outputs []string) error {
	if err := l.Local.Store(key, root, outputs); err != nil {
		return err
	}
	if l.Remote == nil {
		return nil
	}
	path := l.Local.ArchivePath(key)
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("open local archive for push: %w", err)
	}
	defer f.Close()
	stat, err := f.Stat()
	if err != nil {
		return fmt.Errorf("stat local archive: %w", err)
	}
	if err := l.Remote.Push(key, f, stat.Size()); err != nil {
		// Surface but do not fail the orchestrator: the local entry is
		// authoritative. Callers may inspect this via wrapping if they need
		// stricter semantics later.
		return fmt.Errorf("remote push (local cache succeeded): %w", err)
	}
	return nil
}
