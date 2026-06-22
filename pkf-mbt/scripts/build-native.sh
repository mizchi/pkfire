#!/usr/bin/env bash
# Build the native pkf-mbt binary reproducibly.
#
# The mizchi/zlib FFI dependency needs zlib C headers + lib at build time.
# On Linux CI these come from `zlib1g-dev`. On a macOS/nix setup the system
# clang (/usr/bin/cc) does not see nix headers, and `nix shell nixpkgs#zlib`
# does NOT export CPATH — so we resolve the zlib dev/lib store paths
# explicitly and pass them via CPATH / LIBRARY_PATH.
#
# Prints the built binary path on success.
set -euo pipefail
cd "$(dirname "$0")/.."

build() { moon build --target native --release "$@"; }

# Can the system compiler already find + link zlib? (Linux CI with
# zlib1g-dev, or any host with zlib on the default search path.)
if printf '#include <zlib.h>\nint main(void){return 0;}\n' | cc -x c - -lz -o /dev/null >/dev/null 2>&1; then
  build
elif command -v nix >/dev/null 2>&1; then
  zdev=$(nix build nixpkgs#zlib.dev --print-out-paths --no-link)
  zlib=$(nix build nixpkgs#zlib --print-out-paths --no-link)
  CPATH="${CPATH:+$CPATH:}$zdev/include" \
  LIBRARY_PATH="${LIBRARY_PATH:+$LIBRARY_PATH:}$zlib/lib" \
    build
else
  echo "build-native.sh: zlib.h not found and nix unavailable; install zlib dev headers (e.g. zlib1g-dev)" >&2
  exit 1
fi

echo "built: $(pwd)/_build/native/release/build/src/cmd/pkf/pkf.exe"
