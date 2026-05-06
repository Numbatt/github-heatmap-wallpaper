#!/usr/bin/env bash
# shellcheck shell=bash
#
# gh-wallpaper Linux community recipe — render a GitHub contribution heatmap
# to PNG. Companion to the macOS app (https://github.com/Numbatt/github-heatmap-wallpaper).
#
# This is NOT a port. It's a parallel implementation in shell that reproduces
# the heatmap grid only — no headline, no custom themes, no image backgrounds.
# See contrib/linux/README.md for the full caveats.
#
# Usage: heatmap.sh --user <github-username> [options]

set -euo pipefail

VERSION="0.2.0 (linux contrib recipe)"
USER_AGENT="gh-wallpaper-linux/0.2.0 (+https://github.com/Numbatt/github-heatmap-wallpaper)"

# --- themes ---------------------------------------------------------------
# Source of truth for built-in themes. To add a theme: add one row here AND
# update the palette table in contrib/linux/README.md. Format is TSV:
#   id<TAB>background<TAB>L0<TAB>L1<TAB>L2<TAB>L3<TAB>L4
# Values mirror Sources/GhWallpaper/Render/Themes.swift. Keep in sync.
THEMES_TSV=$(cat <<'TSV'
github-dark	#0d1117	#161b22	#0e4429	#006d32	#26a641	#39d353
github-light	#ffffff	#ebedf0	#9be9a8	#40c463	#30a14e	#216e39
catppuccin-mocha	#1e1e2e	#313244	#5d8268	#a6e3a1	#b8e9b1	#caf0c1
dracula	#282a36	#44475a	#3a5a40	#50fa7b	#8aff9c	#b4ffc7
tokyo-night	#1a1b26	#16161e	#3d59a1	#7aa2f7	#9d7cd8	#bb9af7
TSV
)

# --- defaults --------------------------------------------------------------
USER=""
THEME="github-dark"
CANVAS="2560x1440"
OUTPUT="${XDG_CACHE_HOME:-${HOME}/.cache}/gh-wallpaper/wallpaper.png"
SVG_ONLY=0

# --- helpers --------------------------------------------------------------
err() { printf 'gh-wallpaper: %s\n' "$*" >&2; }
die() { err "$2"; exit "$1"; }

usage() {
    cat <<EOF
gh-wallpaper Linux recipe — render GitHub contribution heatmap to PNG.

Usage: heatmap.sh --user <github-username> [options]

Required:
  --user USERNAME     GitHub username to fetch contributions for

Options:
  --theme ID          theme id (default: github-dark)
  --canvas WxH        canvas size in pixels (default: 2560x1440)
  --output PATH       output PNG path (default: \$XDG_CACHE_HOME/gh-wallpaper/wallpaper.png)
  --svg-only          print SVG to stdout, skip rasterization
  --themes            list available themes and exit
  --version           print version and exit
  -h, --help          show this help

Available themes: $(printf '%s' "${THEMES_TSV}" | cut -f1 | paste -sd, -)

Exit codes: 1 user-error · 2 missing-dep · 3 parse-failure · 4 network · 5 render
EOF
}

list_themes() {
    printf 'Available themes:\n'
    printf '%s\n' "${THEMES_TSV}" | cut -f1 | sed 's/^/  /'
}

# Look up a theme by id; prints "background<TAB>L0<TAB>L1<TAB>L2<TAB>L3<TAB>L4"
# or returns nonzero if not found.
lookup_theme() {
    local id="$1"
    printf '%s\n' "${THEMES_TSV}" | awk -F'\t' -v id="${id}" '$1==id { print $2"\t"$3"\t"$4"\t"$5"\t"$6"\t"$7; found=1 } END { exit !found }'
}

# --- arg parse ------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --user)     USER="${2:-}";    shift 2 ;;
        --theme)    THEME="${2:-}";   shift 2 ;;
        --canvas)   CANVAS="${2:-}";  shift 2 ;;
        --output)   OUTPUT="${2:-}";  shift 2 ;;
        --svg-only) SVG_ONLY=1;       shift ;;
        --themes)   list_themes;      exit 0 ;;
        --version)  printf '%s\n' "${VERSION}"; exit 0 ;;
        -h|--help)  usage;            exit 0 ;;
        *)          die 1 "unknown flag: $1 (try --help)" ;;
    esac
done

# --- validation -----------------------------------------------------------
[ -n "${USER}" ] || { usage >&2; die 1 "--user is required"; }

# Username sanity: GitHub usernames are 1–39 chars, alphanumeric + hyphen.
case "${USER}" in
    *[!A-Za-z0-9-]*|-*|*-) die 1 "invalid username: ${USER}" ;;
esac
[ "${#USER}" -le 39 ] || die 1 "invalid username (>39 chars): ${USER}"

# Theme lookup.
THEME_ROW=$(lookup_theme "${THEME}") || {
    err "unknown theme: ${THEME}"
    list_themes >&2
    exit 1
}
IFS=$'\t' read -r BG L0 L1 L2 L3 L4 <<<"${THEME_ROW}"
RAMP=("${L0}" "${L1}" "${L2}" "${L3}" "${L4}")

# Canvas: WxH, both positive integers, sane upper bound.
case "${CANVAS}" in
    *[!0-9x]*|x*|*x) die 1 "invalid --canvas: ${CANVAS} (expected WxH, e.g. 2560x1440)" ;;
esac
CW="${CANVAS%x*}"
CH="${CANVAS#*x}"
{ [ "${CW}" -gt 0 ] && [ "${CH}" -gt 0 ] && [ "${CW}" -le 8192 ] && [ "${CH}" -le 8192 ]; } \
    || die 1 "invalid --canvas: ${CANVAS} (each dimension must be 1..8192)"

# Dependency check.
need_dep() {
    command -v "$1" >/dev/null 2>&1 || {
        err "missing required tool: $1"
        err "install with one of:"
        err "  Debian/Ubuntu:  sudo apt install -y $2"
        err "  Fedora:         sudo dnf install -y $3"
        err "  Arch:           sudo pacman -S $4"
        exit 2
    }
}
need_dep curl curl curl curl
[ "${SVG_ONLY}" -eq 1 ] || need_dep rsvg-convert librsvg2-bin librsvg2-tools librsvg

# --- workspace ------------------------------------------------------------
TMPDIR_X=$(mktemp -d -t gh-wallpaper.XXXXXX)
trap 'rm -rf "${TMPDIR_X}"' EXIT

HTML="${TMPDIR_X}/contributions.html"
DAYS="${TMPDIR_X}/days.tsv"
SVG="${TMPDIR_X}/heatmap.svg"

# --- fetch ----------------------------------------------------------------
URL="https://github.com/users/${USER}/contributions"
if ! curl --fail --silent --show-error --location \
        --max-time 20 \
        --user-agent "${USER_AGENT}" \
        --output "${HTML}" \
        "${URL}"; then
    die 4 "failed to fetch ${URL} (network error or user not found)"
fi

# --- parse ----------------------------------------------------------------
# Match every <td> tag carrying both data-date and data-level (in either
# attribute order), then extract each attribute independently. Mirrors the
# dedup-by-iso-date contract in Sources/GhWallpaper/Data/HTMLParser.swift.
grep -oE '<td[^>]*data-(date|level)="[^"]*"[^>]*data-(date|level)="[^"]*"[^>]*>' "${HTML}" \
    | while read -r tag; do
        date=$(printf '%s' "${tag}" | grep -oE 'data-date="[0-9]{4}-[0-9]{2}-[0-9]{2}"' | head -n1 | cut -d'"' -f2)
        level=$(printf '%s' "${tag}" | grep -oE 'data-level="[0-4]"' | head -n1 | cut -d'"' -f2)
        if [ -n "${date}" ] && [ -n "${level}" ]; then
            printf '%s\t%s\n' "${date}" "${level}"
        fi
    done | sort -u > "${DAYS}.raw"

# Drop future days (matches Scraper.dropFutureDays — UTC + lexicographic).
TODAY=$(date -u +%Y-%m-%d)
awk -F'\t' -v t="${TODAY}" '$1<=t' "${DAYS}.raw" > "${DAYS}"

ROWS_COUNT=$(wc -l < "${DAYS}" | tr -d ' ')
[ "${ROWS_COUNT}" -gt 0 ] || die 3 "no contribution cells found at ${URL} (markup may have changed — file an issue)"

# --- layout + svg emit ----------------------------------------------------
# Mirrors HeatmapLayout (rows=7, columns=ceil(N/7), cellWidth=W*0.75/(cols+(cols-1)*0.25),
# gap=cellWidth*0.25, radius=cellWidth*0.25, vertically centered without headline).
awk -F'\t' \
    -v cw="${CW}" -v ch="${CH}" \
    -v bg="${BG}" \
    -v r0="${RAMP[0]}" -v r1="${RAMP[1]}" -v r2="${RAMP[2]}" -v r3="${RAMP[3]}" -v r4="${RAMP[4]}" \
    '
    BEGIN {
        rows = 7
        ramp[0] = r0; ramp[1] = r1; ramp[2] = r2; ramp[3] = r3; ramp[4] = r4
    }
    { dates[NR] = $1; levels[NR] = $2 + 0 }
    END {
        n = NR
        cols = int((n + rows - 1) / rows)
        if (cols < 1) cols = 1
        target_w = cw * 0.75
        cell = target_w / (cols + (cols - 1) * 0.25)
        gap = cell * 0.25
        radius = cell * 0.25
        total_w = target_w
        total_h = rows * cell + (rows - 1) * gap
        origin_x = cw / 2 - total_w / 2
        origin_y = (ch - total_h) / 2

        printf "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        printf "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\">\n", cw, ch, cw, ch
        printf "  <rect x=\"0\" y=\"0\" width=\"100%%\" height=\"100%%\" fill=\"%s\"/>\n", bg
        for (i = 1; i <= n; i++) {
            col = int((i - 1) / rows)
            row = (i - 1) % rows
            x = origin_x + col * (cell + gap)
            y = origin_y + row * (cell + gap)
            lvl = levels[i]
            if (lvl < 0 || lvl > 4) continue
            printf "  <rect x=\"%.3f\" y=\"%.3f\" width=\"%.3f\" height=\"%.3f\" rx=\"%.3f\" ry=\"%.3f\" fill=\"%s\" shape-rendering=\"crispEdges\"/>\n", x, y, cell, cell, radius, radius, ramp[lvl]
        }
        printf "</svg>\n"
    }
    ' "${DAYS}" > "${SVG}"

# --- output ---------------------------------------------------------------
if [ "${SVG_ONLY}" -eq 1 ]; then
    cat "${SVG}"
    exit 0
fi

mkdir -p "$(dirname "${OUTPUT}")"
TMP_OUT="${OUTPUT}.tmp.$$"
if ! rsvg-convert --width "${CW}" --height "${CH}" --output "${TMP_OUT}" "${SVG}"; then
    rm -f "${TMP_OUT}"
    die 5 "rsvg-convert failed"
fi
mv "${TMP_OUT}" "${OUTPUT}"

printf '%s\n' "${OUTPUT}"
