#!/bin/sh
# install.sh — curl-bootstrap installer for c2c
#
# Usage:
#   curl -fsSL https://c2c.im/install.sh | sh
#   curl -fsSL https://c2c.im/install.sh | sh -s -- --check
#
# This script:
#   1. Detects an existing c2c on PATH and delegates to `c2c self-update`
#   2. Otherwise, downloads the matching release asset from GitHub
#   3. Verifies the SHA-256 checksum against published SHA256SUMS
#   4. Installs to ~/.local/bin/c2c (chmod +x)
#
# Asset naming convention (shared with c2c self-update):
#   https://github.com/clankercode/c2c/releases/download/v<VER>/c2c-<VER>-<os>-<arch>.tar.gz
#   os ∈ {linux, darwin}, arch ∈ {x64, arm64}

set -eu

# ---- configuration --------------------------------------------------------

REPO="clankercode/c2c"
INSTALL_DIR="${HOME}/.local/bin"
GITHUB_API="https://api.github.com/repos/${REPO}"

# ---- helpers --------------------------------------------------------------

info() {
  printf 'c2c install: %s\n' "$*" >&2
}

error() {
  printf 'c2c install: error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || error "required command '$1' not found"
}

# ---- root guard -----------------------------------------------------------

if [ "$(id -u)" -eq 0 ]; then
  error "do not run this script as root. Run as your normal user — c2c installs to ~/.local/bin which is user-owned."
fi

# ---- platform detection ---------------------------------------------------

detect_os() {
  case "$(uname -s)" in
    Linux*)  echo "linux" ;;
    Darwin*) echo "darwin" ;;
    *)       error "unsupported OS: $(uname -s). Only Linux and macOS are supported." ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)   echo "x64" ;;
    aarch64|arm64)   echo "arm64" ;;
    *)               error "unsupported architecture: $(uname -m). Only x86_64 and arm64 are supported." ;;
  esac
}

# ---- dependency check -----------------------------------------------------

need_cmd uname
need_cmd mktemp
need_cmd rm
need_cmd chmod
need_cmd mv
need_cmd mkdir

# We need a downloader: prefer curl, fallback to wget
HAS_CURL=0
HAS_WGET=0
if command -v curl >/dev/null 2>&1; then
  HAS_CURL=1
elif command -v wget >/dev/null 2>&1; then
  HAS_WGET=1
else
  error "neither 'curl' nor 'wget' found. Install one and retry."
fi

# We need tar for extraction
need_cmd tar

# We need sha256sum or shasum for checksum verification
HAS_SHA256SUM=0
HAS_SHASUM=0
if command -v sha256sum >/dev/null 2>&1; then
  HAS_SHA256SUM=1
elif command -v shasum >/dev/null 2>&1; then
  HAS_SHASUM=1
else
  info "warning: neither 'sha256sum' nor 'shasum' found — skipping checksum verification."
fi

# ---- download helper ------------------------------------------------------

download() {
  # download URL > stdout
  if [ "$HAS_CURL" -eq 1 ]; then
    curl -fsSL "$1"
  else
    wget -qO- "$1"
  fi
}

download_to() {
  # download URL FILE
  if [ "$HAS_CURL" -eq 1 ]; then
    curl -fsSL "$1" -o "$2"
  else
    wget -qO "$2" "$1"
  fi
}

# ---- checksum verification ------------------------------------------------

verify_sha256() {
  # verify_sha256 FILE EXPECTED_HEX
  _file="$1"
  _expected="$2"
  if [ "$HAS_SHA256SUM" -eq 1 ]; then
    _actual="$(sha256sum "$_file" | cut -d' ' -f1)"
  elif [ "$HAS_SHASUM" -eq 1 ]; then
    _actual="$(shasum -a 256 "$_file" | cut -d' ' -f1)"
  else
    info "skipping checksum verification (no sha256 tool available)"
    return 0
  fi
  if [ "$_actual" = "$_expected" ]; then
    info "checksum OK"
    return 0
  else
    error "checksum mismatch: expected $_expected, got $_actual"
  fi
}

# ---- resolve latest version from GitHub -----------------------------------

resolve_latest_version() {
  _json="$(download "${GITHUB_API}/releases/latest")"
  # Extract tag_name from JSON without jq (POSIX grep/sed)
  _tag="$(printf '%s' "$_json" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"//;s/".*//')"
  if [ -z "$_tag" ]; then
    error "could not resolve latest release tag from GitHub API"
  fi
  # Strip leading 'v'
  printf '%s' "$_tag" | sed 's/^v//'
}

# ---- find asset URL and checksum ------------------------------------------

find_asset_url_and_checksum() {
  # find_asset_url_and_checksum VERSION OS ARCH
  # Prints: URL CHECKSUM (space-separated)
  _ver="$1"
  _os="$2"
  _arch="$3"
  _asset_name="c2c-${_ver}-${_os}-${_arch}.tar.gz"

  _release_json="$(download "${GITHUB_API}/releases/tags/v${_ver}")"

  # Extract browser_download_url for our asset
  _url="$(printf '%s' "$_release_json" | grep -A2 "\"name\": *\"${_asset_name}\"" | grep 'browser_download_url' | sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"//;s/".*//')"
  if [ -z "$_url" ]; then
    error "no binary asset found for ${_os}-${_arch} in release v${_ver}"
  fi

  # Get SHA256SUMS URL
  _sums_url="$(printf '%s' "$_release_json" | grep -A2 '"name": *"SHA256SUMS"' | grep 'browser_download_url' | sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"//;s/".*//')"

  _checksum=""
  if [ -n "$_sums_url" ]; then
    _sums_text="$(download "$_sums_url")"
    _checksum="$(printf '%s' "$_sums_text" | grep "${_asset_name}" | sed 's/ .*//' | head -1)"
  fi

  # Also try the digest field from the asset metadata
  if [ -z "$_checksum" ]; then
    _checksum="$(printf '%s' "$_release_json" | grep -A5 "\"name\": *\"${_asset_name}\"" | grep '"digest"' | sed 's/.*"sha256://;s/".*//')"
  fi

  printf '%s %s' "$_url" "$_checksum"
}

# ---- delegate to self-update if c2c exists --------------------------------

if command -v c2c >/dev/null 2>&1; then
  info "existing c2c found on PATH: $(command -v c2c)"
  info "delegating to 'c2c self-update'..."
  exec c2c self-update "$@"
fi

# ---- main install path ----------------------------------------------------

info "c2c not found on PATH — performing fresh install."

OS="$(detect_os)"
ARCH="$(detect_arch)"
VERSION="$(resolve_latest_version)"

info "latest version: ${VERSION}"
info "platform: ${OS}-${ARCH}"

# Parse optional flags
CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
  esac
done

if [ "$CHECK_ONLY" -eq 1 ]; then
  info "would install c2c ${VERSION} for ${OS}-${ARCH} to ${INSTALL_DIR}/c2c"
  exit 0
fi

# Resolve asset URL and checksum
read -r ASSET_URL ASSET_CHECKSUM <<EOF
$(find_asset_url_and_checksum "$VERSION" "$OS" "$ARCH")
EOF

if [ -z "$ASSET_URL" ]; then
  error "could not resolve download URL for c2c ${VERSION} ${OS}-${ARCH}"
fi

info "downloading: ${ASSET_URL}"

# Create temp dir
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Download tarball
TARBALL="${TMPDIR}/c2c.tar.gz"
download_to "$ASSET_URL" "$TARBALL"

# Verify checksum if available
if [ -n "$ASSET_CHECKSUM" ]; then
  info "verifying SHA-256 checksum..."
  verify_sha256 "$TARBALL" "$ASSET_CHECKSUM"
else
  info "warning: no checksum available — skipping verification"
fi

# Extract binary
EXTRACT_DIR="${TMPDIR}/extract"
mkdir -p "$EXTRACT_DIR"
tar xzf "$TARBALL" -C "$EXTRACT_DIR" c2c 2>/dev/null || \
  tar xzf "$TARBALL" -C "$EXTRACT_DIR" --strip-components=1 '*/c2c' 2>/dev/null || \
  error "c2c binary not found in downloaded tarball"

if [ ! -f "${EXTRACT_DIR}/c2c" ]; then
  error "c2c binary not found after extraction"
fi

# Install to ~/.local/bin
mkdir -p "$INSTALL_DIR"
chmod +x "${EXTRACT_DIR}/c2c"
mv "${EXTRACT_DIR}/c2c" "${INSTALL_DIR}/c2c"

info "installed c2c ${VERSION} to ${INSTALL_DIR}/c2c"

# PATH hygiene check
case ":${PATH}:" in
  *":${INSTALL_DIR}:"*)
    ;;
  *)
    info "NOTE: ${INSTALL_DIR} is not in your PATH."
    info "Add it with:  export PATH=\"${INSTALL_DIR}:\$PATH\""
    info "Or add to your shell profile (~/.bashrc, ~/.zshrc, etc.)"
    ;;
esac

info "done! Run 'c2c --version' to verify."
