#!/usr/bin/env bash
# gh-wallpaper Linux installer (beta).
#
# What this does:
#   1. Detects your distro (Debian/Ubuntu, Fedora, Arch).
#   2. Installs `resvg` via the distro package manager. Falls back to a
#      prebuilt release binary if the distro package is missing.
#   3. Installs the Swift toolchain via swiftly if `swift` isn't already
#      on PATH.
#   4. Builds gh-wallpaper from source (release config) and copies the binary
#      to ~/.local/bin/.
#   5. Drops the systemd user unit + timer at ~/.config/systemd/user/.
#   6. Prints the next steps (set GH_USER, pick a wallpaper-setter shim,
#      enable the timer).
#
# Idempotent: re-running upgrades the binary and re-syncs the units.
# Does NOT enable the timer or set GH_USER for you — that's intentional.

set -euo pipefail

LOCAL_BIN="${HOME}/.local/bin"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
REPO_URL="https://github.com/Numbatt/github-heatmap-wallpaper"
RESVG_VERSION="0.47.0"

die()   { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info()  { printf '\033[34m→\033[0m %s\n' "$*"; }
done_() { printf '\033[32m✓\033[0m %s\n' "$*"; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

# 1. Detect distro
[ -r /etc/os-release ] || die "no /etc/os-release; can't detect distro"
# shellcheck disable=SC1091
. /etc/os-release
DISTRO="${ID:-unknown}"
DISTRO_LIKE="${ID_LIKE:-}"
info "distro: ${PRETTY_NAME:-$DISTRO}"

case "$DISTRO" in
    ubuntu|debian)                            PKG=apt ;;
    fedora|rhel|centos)                       PKG=dnf ;;
    arch|manjaro|endeavouros|cachyos)         PKG=pacman ;;
    *)
        case "$DISTRO_LIKE" in
            *debian*|*ubuntu*) PKG=apt ;;
            *fedora*|*rhel*)   PKG=dnf ;;
            *arch*)            PKG=pacman ;;
            *) die "unsupported distro: $DISTRO. File an issue at $REPO_URL/issues with your /etc/os-release contents." ;;
        esac
        ;;
esac

# 2. Install resvg (try distro package first, then prebuilt binary fallback)
install_resvg() {
    if command -v resvg >/dev/null 2>&1; then
        done_ "resvg already installed: $(resvg --version 2>&1 | head -1)"
        return 0
    fi
    info "installing resvg…"
    case "$PKG" in
        apt)
            sudo apt-get update -q
            # `resvg` exists in Debian sid + Ubuntu 24.04+; fall through to
            # binary if not packaged.
            if sudo apt-get install -y resvg 2>/dev/null; then
                return 0
            fi
            info "resvg not in apt repos; using upstream binary"
            ;;
        dnf)
            if sudo dnf install -y resvg 2>/dev/null; then
                return 0
            fi
            info "resvg not in dnf repos; using upstream binary"
            ;;
        pacman)
            sudo pacman -Sy --noconfirm --needed resvg && return 0
            info "resvg not in pacman repos; using upstream binary"
            ;;
    esac

    # Binary fallback — pinned version, x86_64 only. Users on aarch64
    # need to install resvg manually.
    require_cmd curl
    if [ "$(uname -m)" != "x86_64" ]; then
        die "no resvg distro package and no prebuilt binary for $(uname -m). Install manually: $REPO_URL"
    fi
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL -o "$tmp/resvg.tar.gz" \
        "https://github.com/RazrFalcon/resvg/releases/download/v${RESVG_VERSION}/resvg-linux-x86_64.tar.gz"
    tar -xzf "$tmp/resvg.tar.gz" -C "$tmp"
    install -Dm755 "$tmp/resvg" "${LOCAL_BIN}/resvg"
    done_ "installed resvg ${RESVG_VERSION} to ${LOCAL_BIN}/resvg"
}
install_resvg

# 3. Install Swift toolchain if absent (~80MB, ~30s on a fast connection)
install_swift() {
    if command -v swift >/dev/null 2>&1; then
        done_ "swift already installed: $(swift --version 2>&1 | head -1)"
        return 0
    fi
    info "installing Swift via swiftly (https://www.swift.org/install/linux/)…"
    require_cmd curl
    curl -fsSL https://swift-server.github.io/swiftly/swiftly-install.sh | bash -s -- --quiet-shell-followup
    # swiftly puts itself on PATH via shell rc; source it for this script.
    if [ -r "${HOME}/.local/share/swiftly/env.sh" ]; then
        # shellcheck disable=SC1091
        . "${HOME}/.local/share/swiftly/env.sh"
    fi
    swiftly install latest
    swiftly use latest
    command -v swift >/dev/null 2>&1 || die "swift install failed; install manually from https://www.swift.org/install/linux/"
    done_ "installed swift: $(swift --version 2>&1 | head -1)"
}
install_swift

# 4. Build + install gh-wallpaper
build_and_install() {
    info "building gh-wallpaper (release)…"
    swift build -c release
    install -Dm755 .build/release/gh-wallpaper "${LOCAL_BIN}/gh-wallpaper"
    done_ "installed ${LOCAL_BIN}/gh-wallpaper"
}
build_and_install

# 5. Install systemd user units
install_units() {
    install -Dm644 contrib/linux/gh-wallpaper.service "${SYSTEMD_USER_DIR}/gh-wallpaper.service"
    install -Dm644 contrib/linux/gh-wallpaper.timer   "${SYSTEMD_USER_DIR}/gh-wallpaper.timer"
    # Install all wallpaper-setter shims so the user can pick the right one
    # without needing to run install.sh again.
    for example in contrib/linux/examples/set-wallpaper-*.sh; do
        [ -e "$example" ] || continue
        install -Dm755 "$example" "${LOCAL_BIN}/$(basename "$example")"
    done
    systemctl --user daemon-reload
    done_ "installed systemd units to ${SYSTEMD_USER_DIR}/"
}
install_units

# 6. Next steps (don't auto-enable — user has to set GH_USER first)
cat <<EOF

────────────────────────────────────────────────────
Installed. Three more steps before the wallpaper updates:

1. Set your GitHub username:
     systemctl --user edit gh-wallpaper.service
   In the editor, add (substituting your username):
     [Service]
     Environment=GH_USER=your-github-username

2. Pick a wallpaper-setter for your desktop and add it as ExecStartPost:
     # GNOME / Cinnamon / MATE
     ExecStartPost=%h/.local/bin/set-wallpaper-gnome.sh
     # KDE Plasma
     ExecStartPost=%h/.local/bin/set-wallpaper-kde.sh
     # XFCE
     ExecStartPost=%h/.local/bin/set-wallpaper-xfce.sh
     # sway / Hyprland — see contrib/linux/README.md (different pattern)

3. Enable the timer + render once now:
     systemctl --user enable --now gh-wallpaper.timer
     systemctl --user start gh-wallpaper.service
     journalctl --user-unit=gh-wallpaper.service -n 50

If anything misbehaves, run \`gh-wallpaper diagnose\` and paste the output
into a bug report at: ${REPO_URL}/issues/new?template=linux-bug.md

Docs: ${REPO_URL}/blob/main/contrib/linux/README.md
EOF
