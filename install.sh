#!/usr/bin/env bash
#
# install.sh — build gh-wallpaper from source and install it into the
# user's Homebrew prefix (or /usr/local/bin as a fallback).
#
# Usage:  ./install.sh
#
# This is the source-install path documented in SPEC.md §4. The primary
# install path is `brew install Numbatt/tap/gh-wallpaper`; this script
# exists for contributors and source-readers who'd rather build locally.

set -euo pipefail

# ---------------------------------------------------------------------------
# Pretty output helpers
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
    BOLD=$(printf '\033[1m')
    DIM=$(printf '\033[2m')
    RED=$(printf '\033[31m')
    GREEN=$(printf '\033[32m')
    YELLOW=$(printf '\033[33m')
    RESET=$(printf '\033[0m')
else
    BOLD=""
    DIM=""
    RED=""
    GREEN=""
    YELLOW=""
    RESET=""
fi

info() { printf '%s==>%s %s\n' "${BOLD}" "${RESET}" "$*"; }
warn() { printf '%s==>%s %s\n' "${YELLOW}${BOLD}" "${RESET}" "$*" >&2; }
err()  { printf '%s==>%s %s\n' "${RED}${BOLD}"    "${RESET}" "$*" >&2; }
ok()   { printf '%s==>%s %s\n' "${GREEN}${BOLD}"  "${RESET}" "$*"; }

# ---------------------------------------------------------------------------
# Sanity: macOS only
# ---------------------------------------------------------------------------

if [ "$(uname -s)" != "Darwin" ]; then
    err "gh-wallpaper is macOS-only. Detected: $(uname -s)."
    exit 1
fi

# ---------------------------------------------------------------------------
# Sanity: Swift toolchain present
# ---------------------------------------------------------------------------

if ! command -v swift >/dev/null 2>&1; then
    err "Swift toolchain not found."
    cat >&2 <<EOF

gh-wallpaper builds with the Swift compiler that ships with the Xcode
Command Line Tools. Install them with:

    xcode-select --install

…then re-run ./install.sh.

EOF
    exit 1
fi

info "Swift toolchain: $(swift --version | head -n1)"

# ---------------------------------------------------------------------------
# Sanity: resvg on PATH (offer to brew install if missing)
# ---------------------------------------------------------------------------

if ! command -v resvg >/dev/null 2>&1; then
    warn "resvg not found on PATH."
    if command -v brew >/dev/null 2>&1; then
        info "Installing resvg via Homebrew..."
        brew install resvg
    else
        err "Homebrew is also missing, so we can't auto-install resvg."
        cat >&2 <<EOF

Install Homebrew first (https://brew.sh/) and then run:

    brew install resvg

…or install resvg some other way and put it on your PATH. Re-run
./install.sh once resvg is reachable.

EOF
        exit 1
    fi
else
    info "resvg: $(command -v resvg)"
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_ROOT}"

info "Building gh-wallpaper (release)..."
swift build -c release

BINARY_SRC="${REPO_ROOT}/.build/release/gh-wallpaper"
if [ ! -x "${BINARY_SRC}" ]; then
    err "Build succeeded but ${BINARY_SRC} is missing or not executable."
    exit 1
fi

# ---------------------------------------------------------------------------
# Choose install destination
# ---------------------------------------------------------------------------
#
# Preference order:
#   1. $HOMEBREW_PREFIX/bin if HOMEBREW_PREFIX is set (respects user override)
#   2. /opt/homebrew/bin    on Apple Silicon if it exists
#   3. /usr/local/bin       on Intel / fallback

DEST_DIR=""
if [ -n "${HOMEBREW_PREFIX:-}" ] && [ -d "${HOMEBREW_PREFIX}/bin" ]; then
    DEST_DIR="${HOMEBREW_PREFIX}/bin"
elif [ -d "/opt/homebrew/bin" ]; then
    DEST_DIR="/opt/homebrew/bin"
elif [ -d "/usr/local/bin" ]; then
    DEST_DIR="/usr/local/bin"
else
    err "Couldn't find a sensible install directory."
    cat >&2 <<EOF

None of these exist:
  - \$HOMEBREW_PREFIX/bin (HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-unset}")
  - /opt/homebrew/bin
  - /usr/local/bin

Create one of those, or copy ${BINARY_SRC} somewhere on your PATH manually.

EOF
    exit 1
fi

DEST="${DEST_DIR}/gh-wallpaper"

info "Installing to ${DEST}..."

# If the destination directory isn't writable by the current user, use sudo.
if [ -w "${DEST_DIR}" ]; then
    cp "${BINARY_SRC}" "${DEST}"
else
    warn "${DEST_DIR} is not writable by $(id -un); using sudo."
    sudo cp "${BINARY_SRC}" "${DEST}"
fi

# Re-sign ad-hoc after the copy. macOS Sequoia/Tahoe attaches a
# `com.apple.provenance` xattr to copied binaries; combined with the
# linker-emitted ad-hoc signature, amfid will SIGKILL the process at
# launch ("zsh: killed gh-wallpaper") on first run. Re-signing in place
# generates a fresh ad-hoc signature that satisfies amfi's checks.
# Idempotent and a no-op if nothing's wrong.
if [ -w "${DEST}" ]; then
    codesign --force --sign - "${DEST}" 2>/dev/null || true
else
    sudo codesign --force --sign - "${DEST}" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

ok "Installed gh-wallpaper to ${DEST}"
cat <<EOF

${DIM}Next steps:${RESET}

  Run:

      gh-wallpaper

  to walk through the setup wizard. It'll ask for your GitHub username,
  theme, and which displays to use, preview the result, set the
  wallpaper, and register a background daemon that keeps it in sync.

  See ${BOLD}gh-wallpaper --help${RESET} for the full subcommand list.

EOF
