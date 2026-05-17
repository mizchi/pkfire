// Package cache implements a content-addressed local cache for task outputs.
//
// Layout (rooted at Cache.Dir):
//
//	cas/<key[0:2]>/<key[2:]>/outputs.tar.zst
//
// The directory existence itself signals a cache hit. `Store` writes the
// archive atomically (temp dir + rename) so concurrent runs cannot observe
// half-written entries.
package cache

import (
	"archive/tar"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/klauspost/compress/zstd"
	"github.com/mizchi/pkfire/internal/hash"
)

const archiveName = "outputs.tar.zst"

// Cache is a handle to a content-addressed cache rooted at `Dir`.
type Cache struct {
	Dir string
}

// New returns a Cache at `dir` (which is created on demand).
func New(dir string) *Cache { return &Cache{Dir: dir} }

// DefaultDir resolves the user's cache root, honoring `PKFIRE_CACHE_DIR`
// and falling back to `$XDG_CACHE_HOME/pkfire` (or `~/.cache/pkfire`).
func DefaultDir() (string, error) {
	if d := os.Getenv("PKFIRE_CACHE_DIR"); d != "" {
		return d, nil
	}
	base, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(base, "pkfire"), nil
}

func (c *Cache) entryDir(key [32]byte) string {
	hex := hash.FormatKey(key)
	return filepath.Join(c.Dir, "cas", hex[:2], hex[2:])
}

// ArchivePath returns the on-disk path of the tar.zst archive for `key`,
// regardless of whether the entry exists yet. Used by `*Layered` to push
// a freshly stored archive to a remote backend.
func (c *Cache) ArchivePath(key [32]byte) string {
	return filepath.Join(c.entryDir(key), archiveName)
}

// WriteRawArchive places `body` into the cache as the archive for `key`,
// performing the same atomic tempdir+rename dance as `Store`. This is what
// `*Layered.Restore` calls when fetching from a remote backend so the
// cache hit also warms the local CAS.
func (c *Cache) WriteRawArchive(key [32]byte, body io.Reader) error {
	target := c.entryDir(key)
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	tmp, err := os.MkdirTemp(filepath.Dir(target), ".tmp-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)

	archivePath := filepath.Join(tmp, archiveName)
	f, err := os.Create(archivePath)
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, body); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, target); err != nil {
		if errors.Is(err, os.ErrExist) {
			return nil
		}
		return err
	}
	return nil
}

// Has reports whether an entry exists for `key`.
func (c *Cache) Has(key [32]byte) bool {
	_, err := os.Stat(filepath.Join(c.entryDir(key), archiveName))
	return err == nil
}

// Restore extracts the cached outputs for `key` into `root`.
// It overwrites existing files with the same path.
func (c *Cache) Restore(key [32]byte, root string) error {
	archivePath := filepath.Join(c.entryDir(key), archiveName)
	f, err := os.Open(archivePath)
	if err != nil {
		return fmt.Errorf("open cache entry: %w", err)
	}
	defer f.Close()
	return extract(f, root)
}

// Store archives the listed `outputs` (relative to `root`) under `key`.
// Missing outputs are ignored; that is intentional — `cache.json` style
// strictness gets in the way of common patterns like optional artifacts.
//
// An empty `outputs` slice is also valid: the entry is still created (with
// an empty archive) so that subsequent runs can detect a cache hit and
// skip execution. This is what makes `pkf` work for tasks like `go vet`
// that produce no artifacts but should still be incremental.
func (c *Cache) Store(key [32]byte, root string, outputs []string) error {
	target := c.entryDir(key)
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	tmp, err := os.MkdirTemp(filepath.Dir(target), ".tmp-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)

	archivePath := filepath.Join(tmp, archiveName)
	f, err := os.Create(archivePath)
	if err != nil {
		return err
	}
	if err := writeArchive(f, root, outputs); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, target); err != nil {
		// If `target` already exists (race with another runner) treat the
		// pre-existing entry as authoritative — content is keyed by hash so
		// they should be byte-equivalent.
		if errors.Is(err, os.ErrExist) {
			return nil
		}
		return err
	}
	return nil
}

func writeArchive(w io.Writer, root string, outputs []string) error {
	zw, err := zstd.NewWriter(w)
	if err != nil {
		return err
	}
	tw := tar.NewWriter(zw)

	expanded, err := hash.ExpandOutputs(root, outputs)
	if err != nil {
		return err
	}
	for _, rel := range expanded {
		full := filepath.Join(root, rel)
		info, err := os.Lstat(full)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				continue
			}
			return err
		}
		switch {
		case info.Mode()&os.ModeSymlink != 0:
			if err := writeSymlink(tw, root, rel, info); err != nil {
				return err
			}
		case info.IsDir():
			if err := walkDir(tw, root, rel); err != nil {
				return err
			}
		default:
			if err := writeFile(tw, root, rel, info); err != nil {
				return err
			}
		}
	}
	if err := tw.Close(); err != nil {
		return err
	}
	return zw.Close()
}

func walkDir(tw *tar.Writer, root, rel string) error {
	full := filepath.Join(root, rel)
	// filepath.Walk does not follow symlinks, so a symlinked subtree shows
	// up here as one entry of mode ModeSymlink — exactly what we want for
	// pnpm-style node_modules (we serialize the link, not the link target).
	return filepath.Walk(full, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		nestedRel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		switch {
		case info.Mode()&os.ModeSymlink != 0:
			return writeSymlink(tw, root, nestedRel, info)
		case info.IsDir():
			hdr, err := tar.FileInfoHeader(info, "")
			if err != nil {
				return err
			}
			hdr.Name = filepath.ToSlash(nestedRel) + "/"
			return tw.WriteHeader(hdr)
		default:
			return writeFile(tw, root, nestedRel, info)
		}
	})
}

// writeSymlink emits a tar header of type Symlink whose Linkname is what
// `os.Readlink` reports — relative or absolute, exactly as authored.
// Validation of absolute targets happens at extract time, not here.
func writeSymlink(tw *tar.Writer, root, rel string, info os.FileInfo) error {
	full := filepath.Join(root, rel)
	link, err := os.Readlink(full)
	if err != nil {
		return fmt.Errorf("readlink %q: %w", full, err)
	}
	hdr, err := tar.FileInfoHeader(info, link)
	if err != nil {
		return err
	}
	hdr.Name = filepath.ToSlash(rel)
	hdr.Typeflag = tar.TypeSymlink
	hdr.Linkname = link
	return tw.WriteHeader(hdr)
}

func writeFile(tw *tar.Writer, root, rel string, info os.FileInfo) error {
	full := filepath.Join(root, rel)
	hdr, err := tar.FileInfoHeader(info, "")
	if err != nil {
		return err
	}
	hdr.Name = filepath.ToSlash(rel)
	if err := tw.WriteHeader(hdr); err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return nil
	}
	f, err := os.Open(full)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = io.Copy(tw, f)
	return err
}

func extract(r io.Reader, root string) error {
	zr, err := zstd.NewReader(r)
	if err != nil {
		return err
	}
	defer zr.Close()
	tr := tar.NewReader(zr)
	cleanRoot := filepath.Clean(root)

	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		target := filepath.Join(root, filepath.FromSlash(hdr.Name))
		if !strings.HasPrefix(target, cleanRoot+string(filepath.Separator)) && target != cleanRoot {
			return fmt.Errorf("entry escapes root: %q", hdr.Name)
		}
		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, hdr.FileInfo().Mode()); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return err
			}
			f, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, hdr.FileInfo().Mode())
			if err != nil {
				return err
			}
			if _, err := io.Copy(f, tr); err != nil {
				f.Close()
				return err
			}
			if err := f.Close(); err != nil {
				return err
			}
		case tar.TypeSymlink:
			if err := restoreSymlink(target, cleanRoot, hdr.Linkname); err != nil {
				return fmt.Errorf("symlink %q -> %q: %w", hdr.Name, hdr.Linkname, err)
			}
		default:
			// devices, fifos, etc. are deliberately ignored — task outputs in
			// normal projects are regular files, directories, and symlinks.
		}
	}
}

// restoreSymlink writes a symlink at `target` pointing to `linkname`.
// Absolute targets are rejected — they would let a malicious archive
// publish a path that resolves outside the cache root after extraction.
// Relative targets are accepted but the resolved destination is also
// confined to `cleanRoot`, which is what blocks `../../../etc/passwd`-
// style escapes from a relative link.
func restoreSymlink(target, cleanRoot, linkname string) error {
	if linkname == "" {
		return fmt.Errorf("empty linkname")
	}
	if filepath.IsAbs(linkname) {
		return fmt.Errorf("absolute symlink targets are rejected")
	}
	resolved := filepath.Clean(filepath.Join(filepath.Dir(target), linkname))
	if resolved != cleanRoot && !strings.HasPrefix(resolved, cleanRoot+string(filepath.Separator)) {
		return fmt.Errorf("symlink target escapes cache root: resolves to %q", resolved)
	}
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	// `os.Symlink` fails if the target already exists; clear it first so
	// repeated restores do not leave a stale entry behind.
	if _, err := os.Lstat(target); err == nil {
		if err := os.Remove(target); err != nil {
			return err
		}
	}
	return os.Symlink(linkname, target)
}
