package cache

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/mizchi/pkfire/internal/hash"
)

// Remote is an HTTP-backed cache backend that speaks the protocol defined
// in `examples/remote-cache-worker/README.md`:
//
//	GET  <base>/v1/cas/<hex64>   → 200 + tar.zst | 404
//	HEAD <base>/v1/cas/<hex64>   → 200 | 404
//	PUT  <base>/v1/cas/<hex64>   → 201 (or 200 if already present)
//
// `Restore` and `Store` are not implemented — they would each need a local
// scratch dir to materialize the archive. Layered handles that; Remote on
// its own only exposes `Has`, `Fetch`, and `Push`.
type Remote struct {
	base   string
	token  string
	client *http.Client
}

// NewRemote returns a Remote pointed at `base` (e.g. "https://cache.example.com").
// `token` is sent as `Authorization: Bearer ...` when non-empty.
func NewRemote(base, token string) *Remote {
	return &Remote{
		base:   strings.TrimRight(base, "/"),
		token:  token,
		client: &http.Client{Timeout: 30 * time.Second},
	}
}

func (r *Remote) url(key [32]byte) string {
	return r.base + "/v1/cas/" + hash.FormatKey(key)
}

func (r *Remote) decorate(req *http.Request) {
	if r.token != "" {
		req.Header.Set("Authorization", "Bearer "+r.token)
	}
}

// Has reports whether the remote has an entry for `key`.
func (r *Remote) Has(key [32]byte) bool {
	req, err := http.NewRequest(http.MethodHead, r.url(key), nil)
	if err != nil {
		return false
	}
	r.decorate(req)
	resp, err := r.client.Do(req)
	if err != nil {
		return false
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

// Fetch returns the remote's archive body for `key`. The caller closes it.
func (r *Remote) Fetch(key [32]byte) (io.ReadCloser, error) {
	req, err := http.NewRequest(http.MethodGet, r.url(key), nil)
	if err != nil {
		return nil, err
	}
	r.decorate(req)
	resp, err := r.client.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode == http.StatusNotFound {
		resp.Body.Close()
		return nil, errCacheMiss
	}
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		return nil, fmt.Errorf("remote GET %s: %s", r.url(key), resp.Status)
	}
	return resp.Body, nil
}

// Push uploads `body` as the archive for `key`. The caller may reuse `body`
// after Push returns (Push reads it to completion).
func (r *Remote) Push(key [32]byte, body io.Reader, size int64) error {
	req, err := http.NewRequest(http.MethodPut, r.url(key), body)
	if err != nil {
		return err
	}
	if size >= 0 {
		req.ContentLength = size
	}
	req.Header.Set("Content-Type", "application/zstd")
	r.decorate(req)
	resp, err := r.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)
	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusOK {
		return fmt.Errorf("remote PUT %s: %s", r.url(key), resp.Status)
	}
	return nil
}

// errCacheMiss is the sentinel returned by Fetch when the remote does not
// have the requested key. Layered uses it to fall through to "run + store".
var errCacheMiss = errors.New("cache miss")

// IsCacheMiss reports whether `err` is a cache-miss sentinel from this
// package (returned by Remote.Fetch).
func IsCacheMiss(err error) bool { return errors.Is(err, errCacheMiss) }
