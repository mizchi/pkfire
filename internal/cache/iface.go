package cache

// Backend is the contract every cache implementation honors. The local CAS
// (`*Cache`), the HTTP remote (`*Remote`), and the layered combination
// (`*Layered`) all satisfy it. Orchestrator code is written against this
// interface so it does not care which backend it is talking to.
type Backend interface {
	// Has reports whether `key` is present in the cache.
	Has(key [32]byte) bool
	// Restore extracts the cached outputs for `key` into `root`.
	Restore(key [32]byte, root string) error
	// Store archives the listed outputs (relative to `root`) under `key`.
	Store(key [32]byte, root string, outputs []string) error
}
