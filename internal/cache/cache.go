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
func (c *Cache) Store(key [32]byte, root string, outputs []string) error {
	if len(outputs) == 0 {
		return nil
	}
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

	for _, rel := range outputs {
		full := filepath.Join(root, rel)
		info, err := os.Lstat(full)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				continue
			}
			return err
		}
		if info.IsDir() {
			if err := walkDir(tw, root, rel); err != nil {
				return err
			}
			continue
		}
		if err := writeFile(tw, root, rel, info); err != nil {
			return err
		}
	}
	if err := tw.Close(); err != nil {
		return err
	}
	return zw.Close()
}

func walkDir(tw *tar.Writer, root, rel string) error {
	full := filepath.Join(root, rel)
	return filepath.Walk(full, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		nestedRel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		if info.IsDir() {
			hdr, err := tar.FileInfoHeader(info, "")
			if err != nil {
				return err
			}
			hdr.Name = filepath.ToSlash(nestedRel) + "/"
			return tw.WriteHeader(hdr)
		}
		return writeFile(tw, root, nestedRel, info)
	})
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
		default:
			// symlinks, devices, etc. are deliberately ignored — task outputs
			// in normal projects are regular files and directories.
		}
	}
}
