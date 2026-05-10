package cache_test

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/mizchi/pkfire/internal/cache"
)

// fakeRemote is an in-memory blob store with a worker-like HTTP surface.
// It speaks the same protocol as `examples/remote-cache-worker`.
type fakeRemote struct {
	mu   sync.Mutex
	data map[string][]byte
}

func newFakeRemote() *fakeRemote { return &fakeRemote{data: map[string][]byte{}} }

func (f *fakeRemote) handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		const prefix = "/v1/cas/"
		if !strings.HasPrefix(path, prefix) || len(path) != len(prefix)+64 {
			http.NotFound(w, r)
			return
		}
		key := path[len(prefix):]
		f.mu.Lock()
		body, ok := f.data[key]
		f.mu.Unlock()
		switch r.Method {
		case http.MethodHead:
			if ok {
				w.WriteHeader(http.StatusOK)
			} else {
				w.WriteHeader(http.StatusNotFound)
			}
		case http.MethodGet:
			if !ok {
				w.WriteHeader(http.StatusNotFound)
				return
			}
			w.Header().Set("Content-Type", "application/zstd")
			w.Write(body)
		case http.MethodPut:
			b, _ := io.ReadAll(r.Body)
			f.mu.Lock()
			alreadyHad := ok
			f.data[key] = b
			f.mu.Unlock()
			if alreadyHad {
				w.WriteHeader(http.StatusOK)
			} else {
				w.WriteHeader(http.StatusCreated)
			}
		default:
			w.Header().Set("Allow", "GET, HEAD, PUT")
			w.WriteHeader(http.StatusMethodNotAllowed)
		}
	})
}

func TestLayeredStorePushesToRemote(t *testing.T) {
	fake := newFakeRemote()
	srv := httptest.NewServer(fake.handler())
	t.Cleanup(srv.Close)

	src := t.TempDir()
	mustWrite(t, filepath.Join(src, "bin/app"), "BIN-PAYLOAD")

	local := cache.New(t.TempDir())
	remote := cache.NewRemote(srv.URL, "")
	layered := cache.NewLayered(local, remote)

	key := [32]byte{0xab, 0xcd}
	if err := layered.Store(key, src, []string{"bin"}); err != nil {
		t.Fatalf("Store: %v", err)
	}
	if !local.Has(key) {
		t.Error("local should have the entry after Store")
	}
	if !remote.Has(key) {
		t.Error("remote should have received the push")
	}
}

func TestLayeredRestoreFallsBackToRemote(t *testing.T) {
	// 1. Set up a Layered with local A + shared remote, store something.
	fake := newFakeRemote()
	srv := httptest.NewServer(fake.handler())
	t.Cleanup(srv.Close)

	src := t.TempDir()
	mustWrite(t, filepath.Join(src, "out/file.txt"), "PAYLOAD")
	localA := cache.New(t.TempDir())
	remote := cache.NewRemote(srv.URL, "")
	layeredA := cache.NewLayered(localA, remote)

	key := [32]byte{0x01, 0x02}
	if err := layeredA.Store(key, src, []string{"out"}); err != nil {
		t.Fatalf("Store via A: %v", err)
	}

	// 2. Fresh Layered with a *different* local but the same remote.
	localB := cache.New(t.TempDir())
	layeredB := cache.NewLayered(localB, remote)
	if localB.Has(key) {
		t.Fatal("fresh local must not already have the entry")
	}
	if !layeredB.Has(key) {
		t.Fatal("Layered.Has should see the remote entry")
	}

	dst := t.TempDir()
	if err := layeredB.Restore(key, dst); err != nil {
		t.Fatalf("Restore via B: %v", err)
	}
	got, err := os.ReadFile(filepath.Join(dst, "out/file.txt"))
	if err != nil {
		t.Fatalf("ReadFile after restore: %v", err)
	}
	if string(got) != "PAYLOAD" {
		t.Errorf("restored content = %q, want PAYLOAD", got)
	}

	// 3. The remote pull warmed the local cache, so a second Restore should
	// be a pure local hit (no remote roundtrip is observable here, but the
	// Has check confirms warming).
	if !localB.Has(key) {
		t.Error("local B should have been warmed by the remote fetch")
	}
}

func TestLayeredAuthHeaderIsForwarded(t *testing.T) {
	got := make(chan string, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case got <- r.Header.Get("Authorization"):
		default:
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(srv.Close)

	r := cache.NewRemote(srv.URL, "secret-token")
	r.Has([32]byte{})

	select {
	case h := <-got:
		if h != "Bearer secret-token" {
			t.Errorf("auth header = %q", h)
		}
	default:
		t.Fatal("server received no request")
	}
}

func TestRemoteFetchReturnsCacheMissOn404(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(srv.Close)
	r := cache.NewRemote(srv.URL, "")
	_, err := r.Fetch([32]byte{})
	if !cache.IsCacheMiss(err) {
		t.Errorf("expected cache miss, got %v", err)
	}
}

func TestRemotePushSendsBody(t *testing.T) {
	var captured bytes.Buffer
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(&captured, r.Body)
		w.WriteHeader(http.StatusCreated)
	}))
	t.Cleanup(srv.Close)
	r := cache.NewRemote(srv.URL, "")
	body := bytes.NewReader([]byte("ARCHIVE-BYTES"))
	if err := r.Push([32]byte{0x10}, body, int64(body.Len())); err != nil {
		t.Fatalf("Push: %v", err)
	}
	if captured.String() != "ARCHIVE-BYTES" {
		t.Errorf("server received %q", captured.String())
	}
}
