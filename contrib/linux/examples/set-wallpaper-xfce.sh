#!/usr/bin/env bash
# XFCE (xfce4-desktop / xfconf).
# Use as ExecStartPost= in your gh-wallpaper.service drop-in:
#   ExecStartPost=%h/.local/bin/set-wallpaper-xfce.sh
#
# XFCE keys vary per monitor name and workspace. This script discovers
# all last-image properties and sets each. To inspect manually:
#   xfconf-query -c xfce4-desktop -lv | grep last-image

set -euo pipefail

IMAGE="${1:-${HOME}/.cache/gh-wallpaper/wallpaper.png}"

xfconf-query -c xfce4-desktop -l \
    | grep -E '/backdrop/screen[0-9]+/monitor[^/]+/workspace[0-9]+/last-image$' \
    | while read -r prop; do
        xfconf-query -c xfce4-desktop -p "${prop}" -s "${IMAGE}"
    done
