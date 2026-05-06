#!/usr/bin/env bash
# Sway (wlroots Wayland compositor).
# Use as ExecStartPost= in your gh-wallpaper.service drop-in:
#   ExecStartPost=%h/.local/bin/set-wallpaper-swaybg.sh
#
# DO NOT spawn `swaybg` from this oneshot — it daemonizes and dies on
# the next render, leaving you with a black wallpaper.
#
# Required setup: add this line to ~/.config/sway/config (once):
#     output * bg ~/.cache/gh-wallpaper/wallpaper.png fill
# Sway re-reads the file on `swaymsg reload`, which is what this script
# triggers. The path is fixed in the sway config; the timer just refreshes
# the file at the same path and asks sway to re-read it.
#
# For Hyprland, use hyprpaper instead:
#     hyprctl hyprpaper reload ,$HOME/.cache/gh-wallpaper/wallpaper.png

set -euo pipefail

swaymsg reload
