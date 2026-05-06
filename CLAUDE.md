# Claude / agent guidance for this repo

Quick orientation for future agents (or future you) walking in cold.

## What this is

`gh-wallpaper` — desktop wallpaper that mirrors your GitHub contribution heatmap. macOS is the primary target (distributed via the personal Homebrew tap `Numbatt/homebrew-tap`). A Linux beta also exists — the Swift binary compiles on swift-corelibs-foundation, driven by a systemd timer + per-DE shell shims (see `contrib/linux/`). Source is here; the tap repo is separate.

Design + scope rationale: [`SPEC.md`](SPEC.md).

## Architecture at a glance

- **Library**: `Sources/GhWallpaper/` (the actual code — scraper, daemon, render, themes, config). Cross-platform: render path is pure Foundation; macOS-only modules (`Daemon/`, `Wallpaper/`, `UI/`, `CLI/Wizard.swift`, parts of `CLI/Commands.swift`) are gated behind `#if os(macOS)` / `#if canImport(AppKit)`.
- **CLI shell**: `Sources/GhWallpaperCLI/` (thin `@main` that dispatches into the library)
- **Dev tool**: `Sources/SnapshotGen/` (regenerates committed SVG snapshots; NOT shipped to users)
- **Tests**: `Tests/GhWallpaperTests/` — XCTest, requires full Xcode on macOS (Command Line Tools' XCTest is partial). On Linux runs via `swift test` in the CI container.
- **Formula**: `Formula/gh-wallpaper.rb` mirrored to the tap repo (macOS only — Linux users `git clone + ./contrib/linux/install.sh`).
- **Linux contrib**: `contrib/linux/` — `install.sh`, systemd units, per-DE wallpaper-setter shims, the legacy `heatmap.sh` no-toolchain fallback.

## How to ship a release

**Read [`docs/RELEASING.md`](docs/RELEASING.md) before doing any release work.** `/ship` only handles the git side — it does not tag a release, build bottles, or update the tap. The runbook covers the full Homebrew dance, the gotchas that have bitten us before, and a TL;DR command sequence.

For the manual smoke checklist (separate from release): [`docs/RELEASE_TESTING.md`](docs/RELEASE_TESTING.md).

## How to regenerate SVG snapshots

After any intentional change to layout, glyph data, theme colors, or anything else that legitimately alters `SVGBuilder` output:

```sh
script/refresh-snapshots.sh   # wraps `swift run SnapshotGen`
```

Review the diff in your PR — that's the human signal for visual changes.

## Local dev workflow

```sh
swift build                # debug, fast (~1-3 sec incremental); cross-platform
swift build -c release     # release, slow (~30 sec); what brew install runs
./install.sh               # macOS: build release + install to /opt/homebrew/bin/gh-wallpaper
                           # auto-codesigns post-copy to avoid SIGKILL on Sequoia/Tahoe

# Linux contributors:
contrib/linux/install.sh   # installs resvg, Swift via swiftly, builds, drops systemd units
```

Linux work without a Linux box: push to a branch and let `.github/workflows/linux-ci.yml` validate. The container build + smoke render against octocat is the substitute for local validation.

## Things to know before touching anything

- **The two formula copies must stay in sync.** `Formula/gh-wallpaper.rb` in this repo and `Formula/gh-wallpaper.rb` in `Numbatt/homebrew-tap`. If you edit one, edit both. `script/update-bottle-block.sh` does the sync automatically.
- **`com.apple.provenance` xattr → SIGKILL.** On Sequoia/Tahoe, copying a freshly-built ad-hoc-signed binary attaches a provenance xattr that makes amfi kill the process at launch (`zsh: killed gh-wallpaper`). The formula and `install.sh` both run `codesign --force --sign -` after copy to work around this. Don't remove that step.
- **`launchctl bootstrap` race.** On Sequoia/Tahoe, `bootstrap` after `bootout` can return exit 5 if launchd hasn't fully torn down the prior PID. `LaunchAgent.install()` handles this with a 200ms sleep + retry.
- **Default-username fallback was removed deliberately.** Don't add it back. If a user has no config, the daemon should log + skip (not silently render someone else's heatmap).
- **`auto` theme is polled per refresh tick, not event-driven.** Per `SPEC.md` §234. Don't add an `AppleInterfaceThemeChangedNotification` observer; the polling design is intentional.
- **Custom themes load from `~/Library/Application Support/gh-wallpaper/themes/*.json`.** Each file decodes directly into a `Theme` (already `Codable`). Validation lives in `CustomThemes.swift`; failures log a warning and skip the file rather than crashing the daemon. User theme ids cannot shadow a built-in — built-ins always win in `Themes.byId(_:)`. Custom themes can carry `backgroundImagePath` (relative paths resolve against the JSON file's directory) and `backgroundDimAlpha` for image backgrounds; the renderHash includes image mtime/size so disk-swapped images invalidate cleanly.
- **Theme editor lives in `Sources/GhWallpaper/UI/`.** Three CLI entry points open it: `themes new <name>`, `theme <id> --edit`, and the from-scratch case via `themes new`. Only these subcommands import SwiftUI; the daemon never enters the UI code path. Bootstrapping pattern: `NSApplication.shared.run()` from the subcommand handler, blocks until the window closes, returns the outcome (`.saved` or `.cancelled`). After the editor exits, the binary resets `NSApp.activationPolicy = .prohibited` so the rest of the CLI runs as a background utility again.

### Linux gotchas (added 2026-05-05)

- **`String(format:)` and `LC_NUMERIC`.** swift-corelibs-foundation honors the user's locale; in a comma-decimal locale (de_DE, fr_FR…) `%.3f` would emit `1,234` and produce invalid SVG. Both render-path call sites (`SVGBuilder.round3`, `Headline.fmt`) pass `Locale(identifier: "en_US_POSIX")` explicitly. Don't drop those without thinking.
- **`URLSession` lives in `FoundationNetworking` on Linux** (not the Foundation umbrella). `Scraper.swift` has `#if canImport(FoundationNetworking) @preconcurrency import FoundationNetworking #endif`. The `@preconcurrency` is intentional — swift-corelibs-foundation's `URLSession` isn't `Sendable` yet.
- **`URLSession.data(for:)` async isn't in older swift-corelibs-foundation.** `Scraper.fetchData` is a `withCheckedThrowingContinuation` wrapper around `URLSession.dataTask` for portability. If you switch to the native async API, gate it on platform/Swift version.
- **`Paths.swift` follows XDG on Linux** (`$XDG_CONFIG_HOME` / `$XDG_CACHE_HOME` / `$XDG_STATE_HOME`). On macOS, `cacheDir` and `stateDir` collapse to `supportDir` for layout compatibility — don't add new files that assume the three roots are different on macOS.
- **Linux CI runs in a container** (`swift:5.10-jammy`) on GitHub-hosted runners. `actions/cache` doesn't work with that combo (host can't `hashFiles` files the container mounts as root) — that's why the cache step is intentionally absent from `linux-ci.yml`.
- **`heatmap.sh` is the no-toolchain fallback, not the supported Linux path.** The Swift binary is what `contrib/linux/install.sh` installs and what the systemd unit invokes. Don't grow `heatmap.sh`'s feature set; if it bitrots, fix or retire — the Swift binary is the maintained path.

## What's stale vs what's live

- `image-1.png` was deleted in cleanup; if you see it referenced anywhere, that's stale.
- "Wave 1/2/3", "M1 spike", "FROZEN INTERFACE" comments were swept in Phase 3. If they reappear, drop them.
- The `worktree-agent-*` worktrees under `.claude/worktrees/` are Claude Code's tooling territory. Don't try to clean them.
- `docs/install-stats.ndjson` and `docs/INSTALL_STATS.md` are auto-generated by `script/install-stats.sh` (run daily by `.github/workflows/install-stats.yml`). The README block between `<!-- install-stats:start -->` / `<!-- install-stats:end -->` is also rewritten by that script. Don't hand-edit any of the three — re-run the script instead.
