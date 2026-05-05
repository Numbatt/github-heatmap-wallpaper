#!/usr/bin/env bash
# KDE Plasma 6 (and Plasma 5 with QDBUS=qdbus).
# Use as ExecStartPost= in your gh-wallpaper.service drop-in:
#   ExecStartPost=%h/.local/bin/set-wallpaper-kde.sh
#
# Plasma's wallpaper API is a JS snippet evaluated by plasmashell over DBus.

set -euo pipefail

IMAGE="${1:-${HOME}/.cache/gh-wallpaper/heatmap.png}"

# qdbus6 on Plasma 6, qdbus on Plasma 5.
QDBUS="${QDBUS:-qdbus6}"
command -v "${QDBUS}" >/dev/null 2>&1 || QDBUS=qdbus

"${QDBUS}" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "
var allDesktops = desktops();
for (var i = 0; i < allDesktops.length; i++) {
    var d = allDesktops[i];
    d.wallpaperPlugin = 'org.kde.image';
    d.currentConfigGroup = ['Wallpaper', 'org.kde.image', 'General'];
    d.writeConfig('Image', 'file://${IMAGE}');
    d.writeConfig('FillMode', '2');
}
"
