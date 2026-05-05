# gh-wallpaper

A macOS desktop wallpaper that mirrors your GitHub contribution heatmap, refreshed automatically. Drop in a GitHub username and your desktop becomes a living poster of your last year of shipping.

---

## 1. Concept

The wallpaper is composed of two elements, stacked vertically and centered horizontally:

1. A bold headline: **`DESIGN.  BUILD.  SHIP.`** (single line, fixed copy, never editable per-user) drawn as hand-designed rectangle letterforms — pure SVG shapes, no font.
2. The user's GitHub contribution heatmap for the last ~53 weeks, rendered as oversized rounded cells styled as art rather than as a faithful UI clone.

The headline is dominant; the heatmap sits beneath it as a tighter band of grid art. The whole wallpaper reads like a poster.

---

## 2. How it works (architecture overview)

A single long-running Swift daemon runs in the background of the user's Mac:

1. Started by `launchd` at user login (`KeepAlive=true`, restarted automatically if it ever exits).
2. Fetches the user's contribution data by scraping their public profile page (no auth, no PAT — see §5).
3. Hashes the response and the active config (theme, displays, etc.) so we only re-render when something actually changed.
4. When data or config has changed, generates an SVG describing the wallpaper, then rasterizes it to a PNG at each connected display's native resolution via the `resvg` rasterizer.
5. Calls `NSWorkspace.shared.setDesktopImageURL(_:for:options:)` once per display.
6. Sleeps until the next poll tick or system event.

The daemon is event-driven *and* timer-driven: it reacts to wake-from-sleep, network reconnect, and display reconfiguration, and on top of that runs an adaptive poll for "your latest commit just darkened a cell" responsiveness.

---

## 3. Polling cadence

Refresh is by polling, not webhooks. GitHub cannot push events to a process behind home/coffee-shop NAT, so a hosted webhook relay is out of scope for a 100% local tool. Polling at the cadences below is well under the anonymous rate limit (≤60 requests/hour vs. a typical limit of ~1000+ for the contributions endpoint per IP).

Cadence is **adaptive**, picked at each tick based on system state:

| State | Interval |
| --- | --- |
| Plugged in, network reachable | 120 seconds |
| On battery, network reachable | 5 minutes |
| Network unreachable | paused; resume immediately when reachable again |

Plus instant triggers:

- **Wake from sleep** → refresh immediately
- **Network reachable transition** → refresh immediately
- **Display configuration change** (monitor plugged/unplugged) → refresh immediately
- **Login / daemon launch** → refresh immediately

A 30-second debounce prevents any of these triggers from firing more than once per half-minute regardless of source.

End-to-end "I pushed a commit and saw it land on my wallpaper" latency on AC: median ~75 seconds (≈30s GitHub pipeline lag for the public contributions graph + ≈45s average wait for the next poll tick), worst case ≈150 seconds.

**Why 120s and not faster:** GitHub's own contribution-graph pipeline takes ~15–30 seconds to update after a push, so polling faster than that is wasted work. Hash-based change detection means most no-op polls cost nothing on our side, but they still hit github.com. 120s gives us 720 requests/day per user — feels live without making us a noisy citizen — and leaves headroom before any anonymous rate-limiting kicks in.

**Display sleep is not a separate state.** v0.1 keeps polling at the AC/battery rate even when the display is asleep but the system is awake. macOS already pauses the daemon entirely during system sleep, so the only window where this matters is brief (lid closed without external display, screen-saver active, idle dimming). The savings are tiny and the detection adds a real failure surface (a buggy detector could pause the daemon forever). Revisit if real-world battery telemetry shows it matters.

---

## 4. Audience & distribution

- **Anyone can use it.** No signup, no accounts, no hosted backend. 100% local.
- **macOS only** for v1. Targets macOS 13 (Ventura) or newer. No Windows, no Linux.
- **Public OSS, repo only.** GitHub repo with a README. No separate landing page (yet).
- **License:** MIT.
- **Code signing:** none. The binary is unsigned. We rely on Homebrew's quarantine-flag exemption to avoid Gatekeeper friction (see below). No Apple Developer Program membership required from the maintainer.

### Install paths

| Path | Friction | Notes |
| --- | --- | --- |
| `brew install Numbatt/tap/gh-wallpaper` | None — Homebrew downloads bypass the macOS quarantine flag, so the unsigned binary launches without Gatekeeper warnings | Primary recommended path. |
| `git clone && ./install.sh` | Requires Swift toolchain (Xcode CLT) — builds locally, no quarantine flag | For contributors and source-readers. |

We do **not** ship a "download the binary from the website and double-click" path, because that would hit Gatekeeper's "this app is damaged" wall on an unsigned binary, and we don't want to either confuse users or document a `xattr` incantation as a normal step. If the project ever needs that path, we can revisit purchasing an Apple Developer ID ($99/yr) for signing + notarization.

---

## 5. Data source — scraping the public profile

We do **not** use a GitHub Personal Access Token. We do **not** use the GraphQL API. The contribution data is fetched by HTTP-GETting:

```
https://github.com/users/<username>/contributions
```

This is the same endpoint GitHub itself uses to render the contribution graph on the public profile. It returns HTML containing a `<table role="grid" class="ContributionCalendar-grid">` whose `<td>` cells (one per day, ~371 total) carry `data-date="YYYY-MM-DD"` and `data-level="0|1|2|3|4"` attributes, plus a sibling `<tool-tip>` with human-readable text like *"1 contribution on April 27th"* (useful as a parser sanity-check). The CSS selector for the parser is `td.ContributionCalendar-day[data-date][data-level]`. No authentication required. The endpoint has been stable enough for years to power dozens of third-party tools (`ghchart.rshah.org`, `github-readme-stats`, etc.).

### Why not a PAT?

- The user's "Include private contributions on my profile" GitHub setting is the right place to control whether private commits show up — it's a setting the user already understands and already controls.
- When that setting is on, the public profile endpoint returns a heatmap that already includes private contributions. We get the right data with zero scopes granted.
- No token to generate, store, rotate, or leak. No Keychain. No "did you check the right boxes?" wizard step. No risk of an OSS tool ever holding a high-value secret.
- The "private contributions on wallpaper but *not* on public profile" niche is unsupported in v0.1. If a real user ever asks for it, we can add a PAT-based opt-in path in a later version.

### Parsing

A small Swift HTML parser walks the response, selects `td.ContributionCalendar-day[data-date][data-level]`, and reads `data-date` and `data-level` from each match. Failure modes:

- **Markup change:** the parser logs a clear "couldn't parse the contribution graph; GitHub may have changed their page structure" error and triggers the failure flow (§10). Doesn't crash, doesn't blank the wallpaper.
- **Username not found:** GitHub returns a 404 page. Parser detects this and the setup wizard rejects the username on entry; runtime detection falls into the failure flow.
- **Profile is private (rare — possible for org-locked accounts):** profile page returns no contribution graph. Parser detects empty grid. Surfaced via `gh-wallpaper diagnose`.

### Edge cases

| Case | Behavior |
| --- | --- |
| Brand-new account, mostly empty | Render the empty grid as-is. The wallpaper still looks intentional — a poster about future shipping. |
| Username doesn't exist / typo | Setup wizard validates by HEAD-requesting `https://github.com/<username>` and rejecting on non-200. |
| Long account inactivity (365 empty days) | Same as new account — empty grid renders. |
| Account renamed while installed | Subsequent fetches return 404 → failure flow → after persistent failure, macOS notification asks user to re-run setup. |
| Rate limit (anonymous IP burst) | Treat as soft failure; back off, try next tick. Anonymous polling at our cadence is far under the limit, so this should be exceedingly rare. |

---

## 6. Setup wizard

Re-runnable. The wizard is the canonical way to (re)configure. CLI subcommands exist as escape hatches but the wizard is the front door.

### Steps, in order

1. **Welcome** — one-line description, plus what we're about to ask for.
2. **GitHub username** — prompt; validate by HEAD-requesting `https://github.com/<username>`. Reject with a friendly message if not found.
3. **Theme selection** — list the 4 themes with a one-line description, plus a fifth option: "Auto-match macOS appearance (light ↔ dark)". If chosen, the `light` slot is hardcoded to `github-light` and the `dark` slot is hardcoded to `github-dark`.
4. **Multi-monitor** — *"Use this wallpaper on which displays? [a]ll / [m]ain only / [c]ustom"*. Default: `all`. Custom opens a per-display picker.
5. **Capture previous wallpaper** — for each target display, call `NSWorkspace.shared.desktopImageURL(for:)` and stash the result for uninstall (§9). Detect dynamic/system wallpapers and flag them as "restoration via deep-link required."
6. **Preview** — render the PNG to a temp path, `open -a Preview` it, prompt: *"Set as your wallpaper now? [Y/n]"*. If Y: copy to canonical path, set wallpaper, register the launchd agent, run an initial fetch. If n: save config but skip activation; tell the user how to enable later (`gh-wallpaper start`).
7. **Done** — print refresh cadence, log path, and `gh-wallpaper --help` hint.

Wizard reruns are non-destructive: pre-fill current values, blank-enter means "keep current."

### What the wizard never does

- Never hits any third-party endpoint besides GitHub's public profile pages.
- Never requests a PAT, OAuth token, or any other GitHub credential.
- Never phones home — there is no telemetry or analytics.

---

## 7. CLI surface

```
gh-wallpaper                       Re-run the setup wizard
gh-wallpaper render                Generate the PNG without setting wallpaper
gh-wallpaper render --user <name>  Render any user's heatmap (config untouched)
gh-wallpaper refresh               Force a refresh + re-set wallpaper now
gh-wallpaper theme <name>          Switch theme (github-light, github-dark, paper, midnight, auto)
gh-wallpaper pause                 Stop the daemon, keep config
gh-wallpaper start                 Re-enable the daemon
gh-wallpaper displays              Configure which displays receive the wallpaper
gh-wallpaper diagnose              Print install state, last refresh, errors, parser status
gh-wallpaper uninstall             Full clean: launchd + config + restore prior wallpaper (or deep-link)
gh-wallpaper --help
gh-wallpaper -v <subcmd>           Verbose logging
```

`uninstall` is full-clean only. There is no separate `purge` flag — `pause` already covers the "stop but keep state" case.

---

## 8. Visual design

### Layout

Headline-dominant. Title takes ~60% of vertical real estate; heatmap is a tighter band centered below it.

```
                                                               ┌─ ~10% top margin ─┐
                                                               │
                                                               ▼
                       DESIGN.  BUILD.  SHIP.
                       ─────────────── (huge headline) ───────────────


                       ▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢
                       ▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢
                       ▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢
                       ▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢
                       ▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢
                       ▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢
                       ▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢▢
                                                               ▲
                                                               │
                                                               └─ ~25% bottom margin ─┐
```

Both title and heatmap are horizontally centered. The heatmap occupies roughly the central 60% of the screen width.

### Sizing rule (handles every aspect ratio with one formula)

Naïve "scale headline width with display width" breaks on ultrawide and portrait orientations: a 49" 5120×1440 ultrawide gets a headline ~1.7× wider than a 14" laptop, overpowering the heatmap; a vertical display gets a headline that overflows. Naïve "scale with display height" breaks at the other end (5K/6K displays get monstrous headlines).

The single rule v0.1 commits to:

```
headline_height_pt = min(0.12 × min(display_width, display_height), 600)
```

That is: 12% of whichever is shorter — the display's width or its height — capped at a constant maximum. The "short edge" property is what makes one rule work for landscape, portrait, and ultrawide; the cap prevents giant text on huge displays. The heatmap then fills ~60% of display width below it, vertically centered in the lower band.

The exact constants (12% and 600pt) are tuning targets and may shift slightly during implementation as we see real renders side-by-side; the *form* of the rule is the spec commitment.

### Headline — hand-designed rectangle letterforms

The headline is rendered as pure SVG `<rect>` shapes — no font involved. It evokes a low-resolution segment-display / ASCII-art feel: each letter is constructed from horizontal bars and rectangular blocks of varying width, with sharp (un-anti-aliased) edges.

- **17 distinct letterforms required:** `D E S I G N . B U L H P` plus one or two width variants for kerning. Each letter is hand-designed once as a small list of `(x, y, width, height)` rectangles on a fixed grid (e.g. 7 rows × N columns per letter).
- **Letters are stored as data**, not as a font file. The Swift binary embeds an array per glyph. At render time, we stitch the glyphs together horizontally into the headline SVG, scaled to the target display width.
- **Color:** solid theme foreground (off-white on dark themes, deep navy on light themes). All headline rectangles share the same fill.
- **Period (`.`) handling:** a small square block, wider than tall, designed to read as a period at the chosen size.
- **Tracking & word spacing:** tight letter spacing, wider gap (visually ~2× a letter width) between words.

Because the rectangles are axis-aligned and the rasterizer never anti-aliases axis-aligned rectangle edges, the headline always renders crisp at any size — that's the desired aesthetic.

### Heatmap rendering

- **Up to 53 columns × 7 rows.** GitHub's grid spans whichever full Sun→Sat weeks fall in the trailing year window (typically 53 columns; sometimes 52 depending on the calendar). Cells outside the actual contribution window (the partial first/last week) render fully transparent — they exist only as grid placeholders.
- **No labels.** No M/W/F day labels. No month labels. No "Less / More" legend. No "Learn how we count contributions" link. The grid is treated as art.
- **Cell style:** oversized (relative to github.com) rounded squares with proportionally larger gaps. Corner radius ~25% of cell size.
- **Color scale:** GitHub's standard 5-step scale (level 0 through 4). Each theme defines its own 5-color ramp; the underlying contribution-level mapping is whatever the scraped page reports as `data-level`.

### Themes

Twelve built-in themes ship plus an `auto` mode. The full list (with palettes) lives in [`Sources/GhWallpaper/Render/Themes.swift`](Sources/GhWallpaper/Render/Themes.swift) — the source of truth. The user-facing breakdown is in the [README's Themes section](README.md#themes).

| Theme | Background | Cell ramp (level 0 → 4) | Headline color |
| --- | --- | --- | --- |
| `github-light` | `#ffffff` | `#ebedf0` → `#9be9a8` → `#40c463` → `#30a14e` → `#216e39` | `#0d1117` |
| `github-dark` | `#0d1117` | `#161b22` → `#0e4429` → `#006d32` → `#26a641` → `#39d353` | `#f0f6fc` |
| `paper` | Off-white textured `#f4f1ea` | Single-ink scale of deep navy `#0a1538` (5 alpha steps) | `#0a1538` |
| `midnight` | Deep blue→purple radial gradient `#0a0a1f → #1e0a30` | Custom green ramp on the dark base | `#f0e7ff` |
| `auto` | Switches between `github-light` and `github-dark` based on `defaults read -g AppleInterfaceStyle`. Re-evaluated on each refresh tick — no live listener (the daemon polls system appearance as part of its tick). | — | — |

User-defined themes live in `~/Library/Application Support/gh-wallpaper/themes/*.json`. Each file is decoded directly into a `Theme` (the same `Codable` struct as the built-ins) and registered alongside them. Validation: 5-color ramp, `#RGB`/`#RGBA`/`#RRGGBB`/`#RRGGBBAA` colors, non-empty id that doesn't collide with a built-in. Bad files are logged and skipped — never crash the daemon. See `Sources/GhWallpaper/Render/CustomThemes.swift`.

Custom themes can additionally specify `backgroundImagePath` (PNG/JPEG file behind the heatmap) and `backgroundDimAlpha` (0–1 black overlay for contrast). The image is rendered via SVG `<image>` so the existing resvg pipeline stays unchanged. The daemon's render hash includes image mtime + size so swapping the file on disk triggers a re-render.

The visual editor (`gh-wallpaper theme-edit <name>`) opens a SwiftUI window with system color pickers, an image picker, dim slider, and a live preview rendered from the same `SVGBuilder` + `Rasterizer` pipeline as the daemon. The editor only loads on the `theme-edit` code path — the daemon never imports `Sources/GhWallpaper/UI/`, so the launchd-loaded process stays headless.

---

## 9. Rendering pipeline

```
contribution data + theme + display geometry
        ↓
generate SVG in Swift (heatmap rectangles + headline rectangles, all hand-positioned)
        ↓
hand SVG to resvg, target = display.frame * display.backingScaleFactor
        ↓
resvg rasterizes to PNG at native pixel resolution
        ↓
write PNG to ~/Library/Application Support/gh-wallpaper/wallpaper-<displayUUID>.png
        ↓
NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
```

- **Why SVG → resvg:** vector-first means the same description rasterizes correctly to a 14" laptop and a 5K external display from one source of truth. resvg is small (~5 MB), fast (rasterizes a 5K image in a few hundred ms), Rust-core, deliberately not a browser. Headless Chromium would add ~200 MB of dependency for features we don't use.
- **Why no font dependency:** the headline is rectangles, and the heatmap cells are rectangles. resvg's font database is irrelevant. There's no `.otf` file to bundle, no font-loading step, no risk of the font missing on the user's machine.
- **Per-display rendering:** the Swift code generates one SVG (resolution-independent) per refresh, then rasterizes it N times — once per connected display, at each display's native pixel dimensions.
- **Render time budget:** target <500 ms per display on Apple Silicon. Hashing config + data lets us skip rendering entirely when nothing has changed.

### Change detection

The daemon hashes a tuple of `(scraped_data, theme, headline_color, displays_config, system_appearance)` and compares to the last successful render's hash. If unchanged, skip render and skip wallpaper-set entirely. This makes the 120-second polling cycle effectively free when the user isn't committing.

---

## 10. Failure handling

The daemon never crashes the user's setup. Failures are absorbed silently up to a threshold, then surfaced.

- **First N failures (where N = 3 consecutive):** keep the last good wallpaper. Log to `~/Library/Logs/gh-wallpaper/agent.log` with timestamp + error. No user-visible disruption.
- **Persistent failure (3+ consecutive):** send a single macOS user notification via `UNUserNotificationCenter`: *"gh-wallpaper: can't refresh your heatmap. Run `gh-wallpaper diagnose` for details."* Don't re-notify until a successful refresh resets the counter.
- **Network errors:** exponential backoff within a single tick (3 retries: 1s, 4s, 16s) before counting as a failure.
- **HTML parser failure (markup changed):** treated as a hard failure. `diagnose` prints a clear "GitHub may have changed their page structure" message with a link to the issue tracker. We ship a fix.
- **404 (account renamed/deleted):** notify the user immediately (it won't fix itself).

The wallpaper image on disk is **never** overwritten with an error state. The user keeps their last good poster.

---

## 11. Sleep, wake, and missed windows

The daemon is long-running (`KeepAlive=true`), so it can subscribe to system events directly:

- `NSWorkspace.didWakeNotification` → refresh immediately on wake from sleep
- `Network.framework` path monitor → refresh on network reachability transition
- `NSApplication.didChangeScreenParametersNotification` → re-render and re-set wallpaper when displays are added or removed

Plus the adaptive timer (§3). All triggers feed into a single refresh queue with a 30-second debounce so we don't double-fire.

---

## 12. Multi-monitor

- **Default:** set on **all displays**, with a per-display PNG rendered at each display's native resolution. Each display gets the heatmap proportioned to its aspect ratio (e.g. 16:9 vs ultrawide vs square external). The headline is sized per-display by the rule in §8 (12% of the short edge, capped at 600pt); the heatmap re-centers within available space.
- **Configurable** via `gh-wallpaper displays`:
  - `all` (default)
  - `main` — main display only; other displays untouched
  - `custom` — interactive picker listing connected displays, with a checkbox per display

When external displays are connected/disconnected, the daemon's display-change observer triggers a re-render so newly-connected screens get the wallpaper without waiting for the next poll tick.

---

## 13. Resolution strategy

We do not ship pre-rendered fixed sizes. Each render targets the connected display's native pixel resolution (queried via `NSScreen.frame * NSScreen.backingScaleFactor`). The SVG template is resolution-independent; resvg rasterizes to whatever px size the display reports.

A 14" MBP, an external 5K display, and an ultrawide all get correctly-sized PNGs, with no banding or stretching.

---

## 14. Wallpaper capture & restoration

### Capture (on first activation)

When the user first activates gh-wallpaper (via the setup wizard or `gh-wallpaper start`), for each target display we call `NSWorkspace.shared.desktopImageURL(for:)` and inspect the result:

- If the URL points to a regular image file (e.g. `~/Pictures/sunset.jpg`, or any plain `.heic`/`.jpg`/`.png` in user space): record the path in `~/Library/Application Support/gh-wallpaper/previous-wallpapers.json` keyed by display UUID. We can restore this on uninstall.
- If the URL points inside `/System/Library/Desktop Pictures/`, or to a known Dynamic Desktop bundle, or returns a non-file URL: record the entry as `{"display": "...", "type": "dynamic"}`. We **cannot** programmatically restore a Dynamic Desktop — there's no public API to set one. We avoid even trying, because saving a frozen frame from a time-of-day-shifting wallpaper and replaying it later would produce a worse result than just letting the user pick again.

### Restoration (on `gh-wallpaper uninstall`)

For each captured display:

- **Static image previously:** call `NSWorkspace.shared.setDesktopImageURL` with the saved path. Done.
- **Dynamic / system wallpaper previously:** open the macOS Wallpaper settings pane via deep link:
  ```
  open "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension"
  ```
  This URL is supported by the modern Settings.app extension on macOS 13+ (verified: the `Wallpaper.appex` extension declares `allowsXAppleSystemPreferencesURLScheme = true` and registers `legacyBundleIdentifier = com.apple.preference.desktopscreeneffect` for fallback on older macOS).

The uninstaller prints a clear human-readable summary either way:

```
Uninstalled gh-wallpaper.

Restored previous wallpaper on:
  - Built-in Display (sunset.jpg)
Could not restore on:
  - LG UltraFine 5K (was a Dynamic Desktop — opening Wallpaper settings so you can re-pick it)
```

---

## 15. File system layout

| Path | Contents |
| --- | --- |
| `/opt/homebrew/bin/gh-wallpaper` (Apple Silicon) or `/usr/local/bin/gh-wallpaper` (Intel) | The unsigned Swift binary, installed by Homebrew |
| `~/Library/Application Support/gh-wallpaper/wallpaper-<displayUUID>.png` | Per-display PNGs (current wallpaper) |
| `~/Library/Application Support/gh-wallpaper/config.toml` | Config (username, theme, displays config) |
| `~/Library/Application Support/gh-wallpaper/state.json` | Runtime state (last refresh, last data hash, consecutive failures) |
| `~/Library/Application Support/gh-wallpaper/previous-wallpapers.json` | Pre-install wallpaper map for restoration on uninstall |
| `~/Library/LaunchAgents/dev.numbatt.gh-wallpaper.plist` | launchd agent (KeepAlive=true, RunAtLoad=true) |
| `~/Library/Logs/gh-wallpaper/agent.log` | Rotating log (1 MB max, last 3 files retained) |

`uninstall` removes all of the above and runs the wallpaper-restoration flow described in §14. There is no Keychain entry — we never use one, since there's no PAT.

---

## 16. Phasing

### v0.1 (first ship)

- Long-running Swift daemon (`KeepAlive=true`) under launchd
- Adaptive polling (120s on AC, 5min on battery, paused offline)
- Event-driven triggers: wake, network, display-change, login
- HTML scraping of `github.com/users/<username>/contributions` — no PAT
- 12 built-in themes + `auto` mode (and user-authored JSON themes since v0.2.0)
- Multi-monitor with per-display rendering
- Hand-designed rectangle letterform headline (no font, pure SVG shapes) — included from day one
- `render` / `refresh` / `theme` / `pause` / `start` / `displays` / `diagnose` / `uninstall` CLI
- Homebrew tap as primary install path (no signing required); `git clone && ./install.sh` for source builds
- Wallpaper capture + restoration with Dynamic Desktop deep-link fallback
- README + `gh-wallpaper --help`

### v0.2 (priority follow-up)

- ✅ User-authored themes: `~/Library/Application Support/gh-wallpaper/themes/*.json` loaded on demand. (Shipped in v0.2.0; format is JSON, not TOML — JSON round-trips through `Theme`'s `Codable` shape with zero glue code.)
- "Render anyone's heatmap" web page or shareable PNG export, generated on demand.

### Out of scope (v1)

- Windows or Linux support
- Hosted / cloud-rendered version
- Account systems, OAuth flow, sign-in
- Any GitHub PAT path (revisit only if a real user wants "private contribs on wallpaper but not on profile")
- Code signing & notarization (revisit only if we add a non-Homebrew install path)
- Menu bar app or GUI preferences pane
- Tooltips, animations, or interactive elements
- GitHub Enterprise support
- Streak counts, contribution totals, username caption — none of these appear on the wallpaper

---

## 17. Testing strategy

The riskiest non-Apple surface in this project is the HTML parser — GitHub can change the contributions-page markup at any time, and breakage is invisible from a dev environment until a real user hits it. Most other code paths (SVG generation, hashing, theme resolution, wallpaper-set) are deterministic and low-risk. The testing strategy is sized accordingly: high coverage on the fragile surfaces, light coverage on the stable ones, no end-to-end Mac-runner tests in v0.1.

### What v0.1 ships with

1. **Unit tests for pure functions.** Parser, SVG generator, hashing, theme resolution, change-detection logic. Anything that takes inputs and returns outputs deterministically. Runs in CI on every commit. Catches refactor breakage cheaply.

2. **Parser fixture suite.** Three committed HTML samples captured by curling the live endpoint:
   - `fixtures/active.html` — a dense, mostly-full year (e.g. captured from a stable active account)
   - `fixtures/sparse.html` — a year with mostly empty cells
   - `fixtures/empty.html` — a brand-new account with no contributions
   
   Parser tests assert correct cell counts (≤ 53 × 7 = 371), all dates parse as valid, all levels are integers in 0–4, and totals roughly match the page's reported total. When GitHub is known to have changed markup, refresh the fixtures by re-running a small `script/refresh-fixtures.sh`.

3. **SVG snapshot tests.** For known input data + theme + display geometry → known SVG output, text-diff the generated SVG against a committed snapshot. Catches accidental visual regressions when refactoring layout code. We do **not** snapshot rasterized PNGs — binary diff noise from resvg version differences isn't worth fighting.

4. **Daily live-endpoint canary.** A scheduled GitHub Actions workflow runs once per day: fetches the contributions page for a known stable username (`torvalds` or similar), runs the parser, asserts the result has non-zero cells with valid dates and levels. If it fails, GitHub Actions emails the maintainer. Cost: one HTTP request + one CI minute per day. Benefit: we know the parser broke before the first user opens an issue.

5. **Manual release smoke checklist** (`docs/RELEASE_TESTING.md`). A 10-step list to walk through before tagging a release:
   - Install via Homebrew on a clean account
   - Run the setup wizard with a real username
   - Verify the wallpaper renders and is set on the main display
   - Switch theme via `gh-wallpaper theme <other>` and verify the wallpaper updates
   - Plug in an external display and verify a per-display PNG appears
   - Sleep the Mac, wake it, verify the wallpaper refreshes within the debounce window
   - Disable Wi-Fi, verify the daemon doesn't crash and resumes on reconnect
   - Run `gh-wallpaper diagnose` and verify all expected fields are present
   - Run `gh-wallpaper uninstall` and verify previous wallpaper is restored (or the deep-link opens for a Dynamic Desktop)
   - Confirm `~/Library/Application Support/gh-wallpaper/` and the launchd plist are gone
   
   Half a page; takes ~5 minutes per release. Skipping it before a release is the most likely way to ship something obviously broken.

### Out of scope for v0.1

- **Mac-runner end-to-end tests in CI.** Slow, brittle, expensive. Revisit if the manual smoke checklist proves insufficient (e.g. we ship two regressions in a row that the checklist would have caught but didn't because someone skipped it).
- **Visual regression tests on rasterized output.** Deferred to v0.2. resvg version drift produces sub-pixel differences that aren't actual regressions; managing that signal-to-noise isn't worth the time yet.

---

## 18. Open questions

These are real and worth revisiting but are not blockers for v0.1:

- **HTML parser robustness in practice:** the fixture suite + daily canary catches most breakage. If GitHub starts shipping markup changes more often than ~once per quarter, we may need to invest in a more robust parser (CSS-selector-based with multiple fallbacks rather than attribute-name-pinned).
- **Anonymous rate limiting:** GitHub's anonymous rate limits aren't perfectly documented. If real-world users start hitting limits at 120s polling, we drop to 180s or 300s on AC. We monitor for 429s and back off automatically as a safety net.
- **Headline letterform tuning:** how much hand-tuning do the 17 glyphs need to look right at very wide aspect ratios (ultrawide, multi-display spans)? May need per-aspect-ratio kerning tables.
- **macOS version floor:** spec targets macOS 13+. If we ever need to support older, we lose the modern Settings deep-link URL and need to fall back to the legacy `com.apple.preference.desktopscreeneffect` form (already registered as a legacy alias, so this likely works for free).
