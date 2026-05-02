#!/usr/bin/env bash
#
# refresh-snapshots.sh — regenerates the committed SVG snapshots under
# Tests/GhWallpaperTests/snapshots/ from the HTML fixtures under
# Tests/GhWallpaperTests/fixtures/.
#
# Run this after any intentional change to layout, glyph data, theme colors,
# or anything else that legitimately alters SVGBuilder output. Review the
# resulting diff in your PR — that's the signal humans verify on visual changes.

set -euo pipefail

cd "$(dirname "$0")/.."

swift run SnapshotGen
