#!/usr/bin/env bash
# Synchronize release-derived checksums after all platform artifacts exist.
#
# Usage:
#   scripts/sync-release-metadata.sh VERSION LINUX_AMD64_SHA LINUX_ARM64_SHA DARWIN_ARM64_SHA
set -euo pipefail

version="${1:?usage: $0 VERSION LINUX_AMD64_SHA LINUX_ARM64_SHA DARWIN_ARM64_SHA}"
linux_amd64="${2:?missing linux-amd64 sha256}"
linux_arm64="${3:?missing linux-arm64 sha256}"
darwin_arm64="${4:?missing darwin-arm64 sha256}"

nix_file="${PKF_NIX_RELEASE_FILE:-nix/pkf-release.json}"
formula_file="${PKF_HOMEBREW_FORMULA_FILE:-Formula/pkf.rb}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "sync-release-metadata: invalid version: $version" >&2
  exit 2
fi

for checksum in "$linux_amd64" "$linux_arm64" "$darwin_arm64"; do
  if [[ ! "$checksum" =~ ^[0-9a-f]{64}$ ]]; then
    echo "sync-release-metadata: invalid sha256: $checksum" >&2
    exit 2
  fi
done

[ -f "$formula_file" ] || {
  echo "sync-release-metadata: formula not found: $formula_file" >&2
  exit 2
}

mkdir -p "$(dirname "$nix_file")"
jq -n \
  --arg v "$version" \
  --arg la "$linux_amd64" \
  --arg lr "$linux_arm64" \
  --arg da "$darwin_arm64" \
  '{
    version: $v,
    platforms: {
      "x86_64-linux":  { plat: "linux-amd64",  sha256: $la },
      "aarch64-linux": { plat: "linux-arm64",  sha256: $lr },
      "aarch64-darwin": { plat: "darwin-arm64", sha256: $da }
    }
  }' >"$nix_file"

ruby - "$formula_file" "$version" "$darwin_arm64" <<'RUBY'
path, version, checksum = ARGV
source = File.read(path)

replacements = {
  %r{^  url "https://github\.com/mizchi/pkfire/releases/download/pkfire@[^/]+/pkf-darwin-arm64\.tar\.gz"$} =>
    %(  url "https://github.com/mizchi/pkfire/releases/download/pkfire@#{version}/pkf-darwin-arm64.tar.gz"),
  /^  version "[^"]+"$/ => %(  version "#{version}"),
  /^  sha256 "[0-9a-f]{64}"$/ => %(  sha256 "#{checksum}"),
}

replacements.each do |pattern, replacement|
  unless source.sub!(pattern, replacement)
    warn "sync-release-metadata: Formula pattern did not match: #{pattern.inspect}"
    exit 2
  end
end

File.write(path, source)
RUBY

ruby -c "$formula_file" >/dev/null
echo "sync-release-metadata: updated Nix and Homebrew metadata for pkfire@$version"
