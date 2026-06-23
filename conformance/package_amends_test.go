package conformance

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// TestCandidatePackageAmendsOffline proves the MoonBit candidate resolves a
// `package://` amends entirely from a hand-seeded cache — no network and no
// `mpkl` subprocess — and evaluates it to the expected JSON.
//
// This is a CANDIDATE-ONLY check (frozen golden compare, not a live Go
// differential), deliberately NOT a scenarios.pkl entry. See the comment in
// scenarios.pkl: the Go oracle uses pkl-go's PreconfiguredOptions, which pins
// the package cache to ~/.pkl/cache with no env override, so the oracle
// cannot be pointed at a committed temp cache offline+hermetically. Seeding
// the real ~/.pkl/cache would mutate the dev machine and is not reproducible
// on a fresh CI runner. The candidate, by contrast, honours
// PKL_MBT_PACKAGE_CACHE, so we seed a temp cache from the committed fixture
// and assert the in-process eval-from-cache path. The download mechanism
// itself is unit-tested in pkf-mbt (download_wbtest.mbt); this test's value
// is the eval-from-cache resolution.
//
// The fixture package (conformance/fixtures/package-amends/cache-seed) is the
// pkfire schema published under a fake package://example.test/.../fixture@1.0.0
// so the consumer's single-hop amends has the full schema available offline.
func TestCandidatePackageAmendsOffline(t *testing.T) {
	bin := requireBin(t, "PKF_MBT_BIN")
	root := repoRoot(t)
	fixtureRoot := filepath.Join(root, "conformance", "fixtures", "package-amends")

	// Seed a temp cache from the committed fixture so the candidate never
	// writes into the committed tree.
	cache := t.TempDir()
	if err := copyTree(filepath.Join(fixtureRoot, "cache-seed"), cache); err != nil {
		t.Fatalf("seed cache: %v", err)
	}

	// Stage the consumer Taskfile in its own work dir.
	work := t.TempDir()
	consumer, err := os.ReadFile(filepath.Join(fixtureRoot, "consumer", "Taskfile.pkl"))
	if err != nil {
		t.Fatalf("read consumer: %v", err)
	}
	if err := os.WriteFile(filepath.Join(work, "Taskfile.pkl"), consumer, 0o644); err != nil {
		t.Fatalf("write consumer: %v", err)
	}

	cmd := exec.Command(bin, "list", "--json")
	cmd.Dir = work
	// Offline by construction: PKL_MBT_PACKAGE_CACHE points at the seeded
	// temp cache. No live network host is reachable for example.test, so a
	// regression that bypasses the cache would fail loudly rather than pass.
	cmd.Env = append(os.Environ(),
		"PKL_MBT_PACKAGE_CACHE="+cache,
		"PKFIRE_CACHE_DIR="+filepath.Join(work, ".pkfire-cache"),
	)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("candidate run failed: %v\nstderr:\n%s", err, stderr.String())
	}

	want, err := os.ReadFile(filepath.Join(fixtureRoot, "expected-list.json"))
	if err != nil {
		t.Fatalf("read expected: %v", err)
	}
	if d := DiffJSON(want, stdout.Bytes(), nil); d != "" {
		t.Errorf("package:// amends eval diverged from expected golden: %s\ngot:\n%s", d, stdout.String())
	}
}
