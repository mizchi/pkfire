#!/bin/sh
# pkfire installer — download the prebuilt `pkf` binary for this host.
#
#   curl -fsSL https://raw.githubusercontent.com/mizchi/pkfire/main/install.sh | sh
#
# Options (env vars or flags):
#   PKF_VERSION      / --version <v>   version to install (default: latest).
#                                      Accepts 0.12.0, v0.12.0, pkfire@0.12.0.
#   PKF_INSTALL_DIR  / --dir <path>    install directory (default: ~/.local/bin)
#   PKF_NO_VERIFY    / --no-verify     skip the sha256 checksum check
#
# `pkf` also needs the Pkl CLI (`pkl`) on PATH:
#   https://pkl-lang.org/main/current/pkl-cli/
#
# Supported platforms: linux-amd64, linux-arm64, darwin-arm64.
# Intel macOS (darwin-amd64) and Windows are not supported — the MoonBit
# toolchain pkf is built with has no x86_64 macOS / Windows target.
set -eu

REPO="mizchi/pkfire"
VERSION="${PKF_VERSION:-latest}"
INSTALL_DIR="${PKF_INSTALL_DIR:-$HOME/.local/bin}"
NO_VERIFY="${PKF_NO_VERIFY:-}"

err() {
  echo "pkfire install: $*" >&2
  exit 1
}

usage() {
  sed -n '2,18p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --version=*) VERSION="${1#*=}"; shift ;;
    --dir) INSTALL_DIR="${2:?--dir needs a value}"; shift 2 ;;
    --dir=*) INSTALL_DIR="${1#*=}"; shift ;;
    --no-verify) NO_VERIFY=1; shift ;;
    -h|--help) usage ;;
    *) err "unknown argument: $1 (try --help)" ;;
  esac
done

# --- detect platform -------------------------------------------------------
os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
  Linux) os_part=linux ;;
  Darwin) os_part=darwin ;;
  *) err "unsupported OS: $os (supported: Linux, Darwin)" ;;
esac
case "$arch" in
  x86_64 | amd64) arch_part=amd64 ;;
  aarch64 | arm64) arch_part=arm64 ;;
  *) err "unsupported architecture: $arch" ;;
esac
plat="${os_part}-${arch_part}"
case "$plat" in
  linux-amd64 | linux-arm64 | darwin-arm64) ;;
  darwin-amd64)
    err "Intel macOS (darwin-amd64) is not supported — the MoonBit toolchain has no x86_64 macOS build. Use an Apple Silicon Mac." ;;
  *) err "unsupported platform: $plat" ;;
esac

# --- resolve download URL --------------------------------------------------
asset="pkf-${plat}.tar.gz"
if [ "$VERSION" = "latest" ]; then
  base="https://github.com/${REPO}/releases/latest/download"
  pretty="latest"
else
  # Normalize 0.12.0 / v0.12.0 / pkfire@0.12.0 → the pkfire@<ver> release tag.
  ver="${VERSION#pkfire@}"
  ver="${ver#v}"
  base="https://github.com/${REPO}/releases/download/pkfire@${ver}"
  pretty="pkfire@${ver}"
fi
url="${base}/${asset}"

# --- pick a downloader -----------------------------------------------------
if command -v curl >/dev/null 2>&1; then
  dl() { curl -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
  dl() { wget -qO "$2" "$1"; }
else
  err "need curl or wget on PATH"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

echo "pkfire install: downloading ${asset} (${pretty}) for ${plat}" >&2
dl "$url" "$tmp/$asset" || err "download failed: $url"

# --- verify checksum (best effort) -----------------------------------------
if [ -z "$NO_VERIFY" ]; then
  if dl "${url}.sha256" "$tmp/${asset}.sha256" 2>/dev/null; then
    expected="$(awk '{print $1}' "$tmp/${asset}.sha256")"
    if command -v sha256sum >/dev/null 2>&1; then
      actual="$(sha256sum "$tmp/$asset" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
      actual="$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')"
    else
      actual=""
    fi
    if [ -n "$actual" ] && [ "$expected" != "$actual" ]; then
      err "checksum mismatch: expected $expected, got $actual"
    fi
    [ -n "$actual" ] && echo "pkfire install: sha256 ok" >&2
  else
    echo "pkfire install: no .sha256 published, skipping checksum" >&2
  fi
fi

# --- extract + install -----------------------------------------------------
tar -xzf "$tmp/$asset" -C "$tmp" || err "failed to extract $asset"
[ -f "$tmp/pkf" ] || err "archive did not contain a 'pkf' binary"

mkdir -p "$INSTALL_DIR"
install -m 0755 "$tmp/pkf" "$INSTALL_DIR/pkf" 2>/dev/null \
  || { cp "$tmp/pkf" "$INSTALL_DIR/pkf" && chmod 0755 "$INSTALL_DIR/pkf"; } \
  || err "failed to install into $INSTALL_DIR (set PKF_INSTALL_DIR to a writable dir)"

echo "pkfire install: installed pkf → ${INSTALL_DIR}/pkf" >&2
"${INSTALL_DIR}/pkf" version >/dev/null 2>&1 \
  && echo "pkfire install: $("${INSTALL_DIR}/pkf" version) ready" >&2 || true

# --- PATH + pkl guidance ---------------------------------------------------
case ":${PATH}:" in
  *":${INSTALL_DIR}:"*) ;;
  *) echo "pkfire install: add ${INSTALL_DIR} to PATH, e.g. export PATH=\"${INSTALL_DIR}:\$PATH\"" >&2 ;;
esac
command -v pkl >/dev/null 2>&1 \
  || echo "pkfire install: also install the Pkl CLI — https://pkl-lang.org/main/current/pkl-cli/" >&2
