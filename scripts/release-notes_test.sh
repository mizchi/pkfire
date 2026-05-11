#!/usr/bin/env bash
#
# Lightweight test for scripts/release-notes.sh. Runs against a
# synthetic CHANGELOG.md in a temp dir so the project's real one
# stays the source of truth for the actual release.
#
# Exit non-zero on any failure; print PASS/FAIL per case.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/release-notes.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [1.2.0] - 2026-06-01

Headline paragraph.

### Added
- feature foo
- feature bar

## [1.1.0] - 2026-05-15

### Added
- earlier thing
EOF

pass() { echo "  PASS  $1"; }
fail() { echo "  FAIL  $1"; echo "    $2" >&2; failed=1; }
failed=0

run_case() {
  local name="$1" version="$2"
  shift 2
  local expected_substrings=("$@")
  local got
  got=$(cd "$tmp" && "$script" "$version") || {
    fail "$name" "script exited non-zero"
    return
  }
  for needle in "${expected_substrings[@]}"; do
    if ! printf '%s' "$got" | grep -qF -- "$needle"; then
      fail "$name" "missing expected substring: $needle"
      return
    fi
  done
  pass "$name"
}

run_neg_case() {
  local name="$1" version="$2" unwanted="$3"
  local got
  got=$(cd "$tmp" && "$script" "$version") || true
  if printf '%s' "$got" | grep -qF -- "$unwanted"; then
    fail "$name" "should not contain: $unwanted"
    return
  fi
  pass "$name"
}

run_case "extracts target section"     1.2.0 "Headline paragraph." "feature foo" "feature bar"
run_neg_case "stops at next section"   1.2.0 "earlier thing"
run_neg_case "skips own heading"       1.2.0 "## [1.2.0]"
run_case "later section also works"    1.1.0 "earlier thing"
run_neg_case "leaks no future section" 1.1.0 "feature foo"

# Missing version → empty output, exit 0 (caller falls back).
got=$(cd "$tmp" && "$script" 9.9.9 || true)
if [ -z "$got" ]; then
  pass "missing version returns empty"
else
  fail "missing version returns empty" "got non-empty: $got"
fi

if [ "$failed" -eq 0 ]; then
  echo "release-notes: all tests passed"
else
  exit 1
fi
