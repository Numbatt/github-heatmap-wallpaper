#!/usr/bin/env bash
# X11 generic — i3, dwm, openbox, bspwm, awesome.
# Use as ExecStartPost= in your gh-wallpaper.service drop-in:
#   ExecStartPost=%h/.local/bin/set-wallpaper-feh.sh
#
# feh writes ~/.fehbg as a "restore" script — your WM's autostart can
# call ~/.fehbg to re-set the wallpaper at login.

set -euo pipefail

IMAGE="${1:-${HOME}/.cache/gh-wallpaper/wallpaper.png}"

feh --no-fehbg --bg-fill "${IMAGE}"
