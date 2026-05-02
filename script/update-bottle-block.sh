#!/usr/bin/env bash
#
# update-bottle-block.sh — after the Bottle workflow finishes for a tag,
# run this locally to:
#   1. Download bottle .tar.gz files from the release
#   2. Compute sha256 for each
#   3. Compose the `bottle do` block
#   4. Update Formula/gh-wallpaper.rb in this repo + push to main
#   5. Mirror the formula to Numbatt/homebrew-tap + push
#
# Usage:  script/update-bottle-block.sh v0.1.1
#
# Requires: gh CLI authenticated, write access to both
# Numbatt/github-heatmap-wallpaper and Numbatt/homebrew-tap.

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "usage: $0 <tag>" >&2
    echo "example: $0 v0.1.1" >&2
    exit 1
fi

TAG="$1"
REPO="Numbatt/github-heatmap-wallpaper"
TAP="Numbatt/homebrew-tap"
FORMULA="Formula/gh-wallpaper.rb"
ROOT_URL="https://github.com/${REPO}/releases/download/${TAG}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "error: release ${TAG} not found in ${REPO}" >&2
    echo "did you push the tag and let the Bottle workflow finish?" >&2
    exit 1
fi

# 1. Download all bottle .tar.gz from the release
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
echo "→ downloading bottles from release ${TAG}…"

TARBALLS=$(gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name' \
    | grep -E '^gh-wallpaper-[^-].*\.bottle.*\.tar\.gz$' \
    || true)
if [ -z "$TARBALLS" ]; then
    echo "error: no bottle .tar.gz assets in release ${TAG}" >&2
    echo "the Bottle workflow may not have run; check Actions tab." >&2
    exit 1
fi

while IFS= read -r tb; do
    gh release download "$TAG" --repo "$REPO" --pattern "$tb" --dir "$TMPDIR" --clobber
done <<< "$TARBALLS"

# 2. Compose bottle block from filenames + sha256s
#    Filename pattern: gh-wallpaper-<version>.<platform>.bottle[.<rebuild>].tar.gz
echo "→ computing sha256 + composing bottle block…"

# Detect a single rebuild number, if any. All bottles for a single tag should
# share the same rebuild count; if not, take the highest.
REBUILD=0
for f in "$TMPDIR"/*.tar.gz; do
    name=$(basename "$f")
    # Extract trailing .N before .tar.gz, if present.
    if [[ "$name" =~ \.bottle\.([0-9]+)\.tar\.gz$ ]]; then
        n="${BASH_REMATCH[1]}"
        if (( n > REBUILD )); then REBUILD="$n"; fi
    fi
done

BOTTLE_BLOCK_FILE="$TMPDIR/bottle_block.txt"
{
    echo "  bottle do"
    echo "    root_url \"${ROOT_URL}\""
    if (( REBUILD > 0 )); then
        echo "    rebuild ${REBUILD}"
    fi
    for f in "$TMPDIR"/*.tar.gz; do
        name=$(basename "$f")
        # Extract platform tag: between gh-wallpaper-<version>. and .bottle
        platform=$(echo "$name" | sed -E 's/^gh-wallpaper-[0-9]+\.[0-9]+\.[0-9]+\.([a-z0-9_]+)\.bottle.*$/\1/')
        sha=$(shasum -a 256 "$f" | awk '{print $1}')
        echo "    sha256 cellar: :any_skip_relocation, ${platform}: \"${sha}\""
    done | sort
    echo "  end"
} > "$BOTTLE_BLOCK_FILE"

echo "→ block:"
sed 's/^/    /' "$BOTTLE_BLOCK_FILE"

# 3. Splice into Formula/gh-wallpaper.rb
echo
echo "→ updating ${FORMULA}…"

python3 - "$FORMULA" "$BOTTLE_BLOCK_FILE" <<'PY'
import re, sys, pathlib
formula_path, block_path = sys.argv[1], sys.argv[2]
src = pathlib.Path(formula_path).read_text()
block = pathlib.Path(block_path).read_text().rstrip() + "\n"

# Strip any existing bottle do…end block.
new = re.sub(
    r'\n\s*bottle do\n(?:.*\n)*?\s*end\n',
    '\n',
    src,
    count=1
)

# Insert right after the `head` line.
new = re.sub(
    r'(\n\s*head\s+"[^"]*",\s*branch:\s*"[^"]*"\n)',
    lambda m: m.group(1) + "\n" + block + "\n",
    new,
    count=1
)

pathlib.Path(formula_path).write_text(new)
PY

# 4. Sanity check
brew style "$FORMULA" || {
    echo "error: brew style failed on the updated formula; aborting" >&2
    git checkout -- "$FORMULA"
    exit 1
}

# 5. Commit + push to this repo
git add "$FORMULA"
if git diff --staged --quiet; then
    echo "→ formula already up-to-date in ${REPO}"
else
    git commit -m "feat(formula): bottles for ${TAG}"
    git push origin main
    echo "→ pushed formula to ${REPO}"
fi

# 6. Mirror to the tap repo
echo "→ mirroring to ${TAP}…"
TAP_DIR="$(mktemp -d)/homebrew-tap"
gh repo clone "$TAP" "$TAP_DIR" -- --quiet
cp "$FORMULA" "$TAP_DIR/$FORMULA"
(
    cd "$TAP_DIR"
    git add "$FORMULA"
    if git diff --staged --quiet; then
        echo "→ tap already up-to-date"
    else
        git commit -m "feat: bottles for ${TAG}"
        git push origin main
        echo "→ pushed formula to ${TAP}"
    fi
)

echo
echo "✓ done. test with:"
echo "    brew untap ${TAP%/*}/tap"
echo "    brew install ${TAP%/*}/tap/gh-wallpaper"
