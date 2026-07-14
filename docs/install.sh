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
# Official Linux release binaries are built on Ubuntu 22.04 (B190).
# Hosts older than glibc 2.35 get a clear error instead of a dynamic-linker
# "GLIBC_X.Y not found" failure after download. Ubuntu 20.04 / glibc 2.31
# still needs a local `just install-all` build (or a future manylinux/static
# artifact). macOS is unaffected.
MIN_LINUX_GLIBC="2.35"

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

# version_lt A B → exit 0 if A is strictly older than B (sort -V).
version_lt() {
  _a="$1"
  _b="$2"
  _newest="$(printf '%s\n%s\n' "$_a" "$_b" | sort -Vu | tail -n 1)"
  [ "$_newest" = "$_b" ] && [ "$_a" != "$_b" ]
}

# host_glibc_version → prints X.Y on glibc Linux, empty otherwise.
host_glibc_version() {
  if ! command -v ldd >/dev/null 2>&1; then
    return 0
  fi
  # First line: "ldd (GNU libc) 2.35" or "ldd (Ubuntu GLIBC 2.35-0ubuntu3) 2.35"
  # Reject musl early — official releases are glibc-linked.
  _ldd_line="$(ldd --version 2>&1 | head -n 1 || true)"
  case "$_ldd_line" in
    *musl*|*Musl*|*MUSL*)
      printf 'musl'
      return 0
      ;;
  esac
  printf '%s' "$_ldd_line" | sed -n 's/.* \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p'
}

# Fail fast on Linux hosts that cannot run the official release binary.
check_linux_glibc_floor() {
  case "$(uname -s)" in
    Linux*) ;;
    *) return 0 ;;
  esac
  _glibc="$(host_glibc_version)"
  if [ "$_glibc" = "musl" ]; then
    error "official Linux releases are glibc-linked and do not run on musl (e.g. Alpine). Build from source on this host ('just install-all' in a checkout) or use a glibc-based distro (Ubuntu 22.04+, Debian 12+, RHEL 9+)."
  fi
  if [ -n "$_glibc" ] && version_lt "$_glibc" "$MIN_LINUX_GLIBC"; then
    error "host glibc ${_glibc} is older than the minimum supported by official Linux releases (glibc ≥ ${MIN_LINUX_GLIBC} / Ubuntu 22.04+). Build c2c from source on this host ('just install-all' in a checkout), or upgrade the OS. Ubuntu 20.04 (glibc 2.31) is below this floor until a manylinux/static artifact ships. Runtime shared libs also required: libsqlite3, libgmp."
  fi
  if [ -n "$_glibc" ]; then
    info "host glibc ${_glibc} meets release floor (≥ ${MIN_LINUX_GLIBC})"
  fi
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

# ---- Linux glibc floor before any download / self-update (B190) ---------
# Must run before self-update delegation: a host-built c2c on Ubuntu 20.04
# can self-update into an official release binary that will not start.

check_linux_glibc_floor

# ---- delegate to self-update if c2c exists and supports it --------------
#
# B092: Some older c2c binaries (notably the @clanker-code/c2c npm wrapper
# before self-update landed) don't ship the `self-update` subcommand.
# Delegating blindly made install.sh die with "unknown command self-update"
# and left the user with no working install. Probe for the subcommand; if
# it's missing, fall through to the fresh standalone install path below so
# we still produce a working binary.

c2c_has_self_update() {
  # Probe the existing c2c's --help output for the 'self-update' subcommand.
  # grep -w matches whole words so other subcommands containing 'self-update'
  # (e.g. a hypothetical 'self-update-alias') won't false-positive. Exit 1
  # when the word isn't present; redirect both streams so binaryes that
  # print help to either fd are still inspected.
  c2c --help 2>&1 | grep -qw 'self-update'
}

# Track *why* we ended up in the standalone install path so we can log it.
#   0 = no c2c on PATH
#   1 = c2c present but lacks 'self-update'
#   2 = c2c present, advertised self-update, but the delegation failed
FALLTHROUGH_REASON=0

if command -v c2c >/dev/null 2>&1; then
  C2C_PATH="$(command -v c2c)"
  info "existing c2c found on PATH: ${C2C_PATH}"
  if c2c_has_self_update; then
    info "delegating to 'c2c self-update'..."
    # Run (not exec) so we can detect delegation failures and fall through
    # to a fresh standalone install. A successful self-update replaces the
    # binary in place; a failure leaves the old one in place and we replace
    # it with the fresh standalone download below.
    if c2c self-update "$@"; then
      exit 0
    fi
    info "'c2c self-update' failed; falling through to fresh standalone install."
    FALLTHROUGH_REASON=2
  else
    info "existing c2c at ${C2C_PATH} lacks the 'self-update' subcommand."
    info "falling through to fresh standalone install."
    FALLTHROUGH_REASON=1
  fi
fi

# ---- main install path ----------------------------------------------------

case "$FALLTHROUGH_REASON" in
  0) info "c2c not found on PATH — performing fresh install." ;;
  1) info "performing fresh standalone install (existing c2c lacks self-update)." ;;
  2) info "performing fresh standalone install (existing c2c self-update failed)." ;;
esac

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

# Smoke-test the extracted binary before replacing anything on PATH.
# Catches glibc / missing shared-lib failures with a clear message (B190).
if ! VERIFY_OUT="$("${EXTRACT_DIR}/c2c" --version 2>&1)"; then
  if printf '%s\n' "$VERIFY_OUT" | grep -q 'GLIBC_'; then
    error "downloaded binary cannot start (glibc too old for this host): ${VERIFY_OUT}. Official Linux releases need glibc ≥ ${MIN_LINUX_GLIBC} (Ubuntu 22.04+). Build from source on this host ('just install-all'), or upgrade the OS. Also ensure libsqlite3 and libgmp are installed."
  fi
  if printf '%s\n' "$VERIFY_OUT" | grep -Eq 'libsqlite3|libgmp|error while loading shared libraries'; then
    error "downloaded binary cannot start (missing shared library): ${VERIFY_OUT}. Install runtime deps: libsqlite3 and libgmp (Debian/Ubuntu: libsqlite3-0 libgmp10)."
  fi
  error "downloaded binary failed to start: ${VERIFY_OUT}"
fi

mv "${EXTRACT_DIR}/c2c" "${INSTALL_DIR}/c2c"

info "installed c2c ${VERSION} to ${INSTALL_DIR}/c2c"
info "verified: ${VERIFY_OUT}"

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
