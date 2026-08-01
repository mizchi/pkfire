#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
formula="$root/Formula/pkf.rb"
sync="$root/scripts/sync-release-metadata.sh"

fail() {
  echo "homebrew-test: $*" >&2
  exit 1
}

[ -f "$formula" ] || fail "missing Formula/pkf.rb"
[ -x "$sync" ] || fail "missing executable scripts/sync-release-metadata.sh"

ruby -c "$formula" >/dev/null
grep -q '^class Pkf < Formula$' "$formula" || fail "formula class must be Pkf"
grep -q 'depends_on "pkl"' "$formula" || fail "formula must install the Pkl CLI"
grep -q 'depends_on arch: :arm64' "$formula" || fail "formula must reject Intel macOS"
grep -q 'depends_on :macos' "$formula" || fail "formula must be macOS-only"
grep -q 'bin.install "pkf"' "$formula" || fail "formula must install pkf"
grep -q 'shell_output("#{bin}/pkf version")' "$formula" || fail "formula must smoke-test pkf version"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

cp "$formula" "$tmp/pkf.rb"
cat >"$tmp/pkf-release.json" <<'JSON'
{
  "version": "0.0.1",
  "platforms": {}
}
JSON

linux_amd64=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
linux_arm64=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
darwin_arm64=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc

PKF_NIX_RELEASE_FILE="$tmp/pkf-release.json" \
PKF_HOMEBREW_FORMULA_FILE="$tmp/pkf.rb" \
  "$sync" 9.8.7 "$linux_amd64" "$linux_arm64" "$darwin_arm64"

[ "$(jq -r .version "$tmp/pkf-release.json")" = "9.8.7" ] || fail "Nix version was not updated"
[ "$(jq -r '.platforms["x86_64-linux"].sha256' "$tmp/pkf-release.json")" = "$linux_amd64" ] || fail "linux-amd64 checksum was not updated"
[ "$(jq -r '.platforms["aarch64-linux"].sha256' "$tmp/pkf-release.json")" = "$linux_arm64" ] || fail "linux-arm64 checksum was not updated"
[ "$(jq -r '.platforms["aarch64-darwin"].sha256' "$tmp/pkf-release.json")" = "$darwin_arm64" ] || fail "darwin-arm64 checksum was not updated"
grep -q 'version "9.8.7"' "$tmp/pkf.rb" || fail "Formula version was not updated"
grep -q 'releases/download/pkfire@9.8.7/pkf-darwin-arm64.tar.gz' "$tmp/pkf.rb" || fail "Formula URL was not updated"
grep -q "sha256 \"$darwin_arm64\"" "$tmp/pkf.rb" || fail "Formula checksum was not updated"
ruby -c "$tmp/pkf.rb" >/dev/null

if PKF_NIX_RELEASE_FILE="$tmp/pkf-release.json" \
  PKF_HOMEBREW_FORMULA_FILE="$tmp/pkf.rb" \
  "$sync" 9.8.8 invalid "$linux_arm64" "$darwin_arm64" >/dev/null 2>&1; then
  fail "invalid checksum was accepted"
fi

echo "homebrew-test: all tests passed"
