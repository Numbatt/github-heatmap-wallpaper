#!/usr/bin/env bash
# GNOME / Cinnamon / MATE (gsettings-based desktops).
# Use as ExecStartPost= in your gh-wallpaper.service drop-in:
#   ExecStartPost=%h/.local/bin/set-wallpaper-gnome.sh
#
# Sets both the dark and light keys to the same image so the wallpaper
# applies regardless of the user's appearance preference.

set -euo pipefail

IMAGE="${1:-${HOME}/.cache/gh-wallpaper/wallpaper.png}"
URI="file://${IMAGE}"

gsettings set org.gnome.desktop.background picture-uri "${URI}"
gsettings set org.gnome.desktop.background picture-uri-dark "${URI}"
gsettings set org.gnome.desktop.background picture-options "zoom"
