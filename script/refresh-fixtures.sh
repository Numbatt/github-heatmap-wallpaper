#!/usr/bin/env bash
# Re-download the HTML fixtures used by HTMLParserTests from live GitHub.
#
# Usernames must match the ones documented in
# Tests/GhWallpaperTests/HTMLParserTests.swift. The script is idempotent — run it
# any time you want to refresh the captured HTML and review the diff.
#
# Run from the repo root:
#     bash script/refresh-fixtures.sh
set -euo pipefail

UA="gh-wallpaper-fixture-refresh/0.1"
DEST="Tests/GhWallpaperTests/fixtures"

if [ ! -d "$DEST" ]; then
    echo "error: $DEST not found; run from repo root" >&2
    exit 1
fi

fetch() {
    local user="$1"
    local file="$2"
    echo "fetching $user -> $DEST/$file"
    curl -sSfL -A "$UA" -o "$DEST/$file" "https://github.com/users/$user/contributions"
}

fetch torvalds active.html
fetch mojombo  sparse.html
fetch defunkt  empty.html

echo "done. review diff with: git diff -- $DEST"
