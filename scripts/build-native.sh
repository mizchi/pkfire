#!/usr/bin/env bash
# Build the native pkf binary reproducibly.
#
# pkf uses mizchi/zlib's pure-MoonBit deflate/inflate (not the native C-FFI
# variant), so the build needs no system zlib (no zlib.h, no -lz) — only the
# moon toolchain and a C compiler for the MoonBit→C→cc native backend. The
# resulting binary links only libc.
#
# Prints the built binary path on success.
set -euo pipefail
cd "$(dirname "$0")/.."

moon build src/cmd/pkf --target native --release "$@"

echo "built: $(pwd)/_build/native/release/build/src/cmd/pkf/pkf.exe"
