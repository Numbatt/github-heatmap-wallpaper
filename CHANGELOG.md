# Changelog

All notable changes to `gh-wallpaper` are recorded here. The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows semver.

## [0.2.0] — unreleased

### Added
- Five new built-in themes: `tokyo-night`, `dracula`, `nord`, `gruvbox-dark`, and `catppuccin-mocha`.
- **Custom themes**: drop a JSON file in `~/Library/Application Support/gh-wallpaper/themes/`, then run `gh-wallpaper theme <id>`. Schema mirrors the built-in `Theme` struct (`id`, `background`, `cellRamp` [5 colors], `headlineColor`, optional `backgroundIsGradient` + `gradientSVG`). Validation rejects malformed files with a logged warning rather than crashing the daemon. See README for the schema.
- **Visual theme editor** — opens a native macOS SwiftUI window with system color pickers (one per slot), a dim slider, an image-background picker, and a live preview that re-renders from the same SVG pipeline the daemon uses. Three entry points:
  - `gh-wallpaper themes new <name>` — start from scratch (or `--from <id>` to seed from any existing theme).
  - `gh-wallpaper theme <id> --edit` — edit a custom in place, or fork a built-in (built-ins force a rename on save since they're immutable).
  - The Save button label updates as you type ("Save as custom theme 'my-theme'") so the commit moment is unambiguous. **Save & apply** applies the new theme as your wallpaper immediately. The editor only loads on these subcommands; the daemon stays headless.
- New `gh-wallpaper themes <verb>` CRUD: `delete <name>`, `export <name>` (JSON to stdout, works for built-ins too), `import` (read JSON from stdin). `themes export dracula > my-dracula.json` then editing + `themes import < my-dracula.json` is the full share-a-theme loop.
- **Image backgrounds** — custom themes can carry `backgroundImagePath` (PNG/JPEG, relative to the theme JSON or absolute) and `backgroundDimAlpha` (0–1 overlay for contrast). The image is rendered via SVG `<image>` and the daemon hashes the file's mtime + size so swapping the photo on disk invalidates the cache automatically. The editor's image picker copies your chosen file into `themes/images/<theme-id>.<ext>` so the theme stays portable.
- Daily install-analytics snapshot: `docs/install-stats.ndjson` accumulates per-day GitHub release-asset bottle download counts; `docs/INSTALL_STATS.md` and a README block are regenerated from it. Server-side only — no client telemetry was added. See [`docs/INSTALL_STATS.md`](docs/INSTALL_STATS.md) for methodology and the counting-model caveats.
- **Linux community recipe** — `contrib/linux/` ships a ~180-line shell renderer (`curl` + `rsvg-convert`), a systemd user oneshot + hourly timer, and per-DE wallpaper-setter snippets (GNOME/KDE/XFCE/Sway/Hyprland/X11). Heatmap-only (no headline), 5 curated themes (`github-dark`, `github-light`, `catppuccin-mocha`, `dracula`, `tokyo-night`), render-only (BYO wallpaper-set per DE). Best-effort, community-maintained — see [`contrib/linux/README.md`](contrib/linux/README.md). The macOS app and release pipeline are unchanged.

### Removed
- Themes `sunset` and `forest` — capping built-ins at 12 to keep the picker manageable. Users on those ids will fall back to `github-dark` automatically on the next refresh; switch with `gh-wallpaper theme <id>` to pick a replacement (`paper` is the closest warm-light alternative; `ocean` covers the cool-light slot).

### Notes
- Custom theme ids cannot shadow a built-in. Built-ins always win in `Themes.byId(_:)`.
- The `themes/` directory is read on demand and cached per-process; restart the daemon (`gh-wallpaper pause && gh-wallpaper start`) after adding or editing custom theme files.

## [0.1.3] — 2026-05-04

- Added `catppuccin-frappe` theme.
- Listed `catppuccin-frappe` in `gh-wallpaper --help` theme ids.

## [0.1.2] and earlier

See git history.
