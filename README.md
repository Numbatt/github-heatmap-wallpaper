# gh-wallpaper

Your GitHub contribution heatmap as your macOS desktop wallpaper. Refreshes itself in the background so your desktop always reflects what you've shipped this year.

![Wallpaper preview](image.png)

<!-- install-stats:start -->
**Installs of latest release (v0.1.3):** 7 · [full stats & methodology](docs/INSTALL_STATS.md)
<!-- install-stats:end -->

---

## Install

```sh
brew install Numbatt/tap/gh-wallpaper
```

That's it. Or, equivalently:

```sh
brew tap Numbatt/tap
brew install gh-wallpaper
```

### From source

If you'd rather build locally (e.g. you don't use Homebrew):

```sh
git clone https://github.com/Numbatt/github-heatmap-wallpaper
cd github-heatmap-wallpaper
./install.sh
```

`install.sh` checks for the Swift toolchain and `resvg`, builds the release binary, and copies it into your Homebrew prefix (or `/usr/local/bin`).

Then run the wizard:

```sh
gh-wallpaper
```

It'll ask for your GitHub username, theme, and which displays to use; preview the result; set the wallpaper; and register a background daemon. From that point on, your wallpaper updates itself.

---

## Themes

Twelve themes ship plus an `auto` mode that follows your macOS appearance setting:

<table>
  <tr>
    <td align="center"><b>github-dark</b><br><img src="images/torvalds-github-dark.png" alt="github-dark theme — torvalds's contribution heatmap on graphite" /></td>
    <td align="center"><b>github-light</b><br><img src="images/torvalds-github-light.png" alt="github-light theme — torvalds's contribution heatmap on white" /></td>
  </tr>
  <tr>
    <td align="center"><b>tokyo-night</b><br><img src="images/torvalds-tokyo-night.png" alt="tokyo-night theme — blue→magenta ramp with a cyan headline on midnight blue" /></td>
    <td align="center"><b>dracula</b><br><img src="images/torvalds-dracula.png" alt="dracula theme — neon green ramp with a hot pink headline on selection grey" /></td>
  </tr>
  <tr>
    <td align="center"><b>nord</b><br><img src="images/torvalds-nord.png" alt="nord theme — frost-blue ramp with a snow headline on polar-night base" /></td>
    <td align="center"><b>gruvbox-dark</b><br><img src="images/torvalds-gruvbox-dark.png" alt="gruvbox-dark theme — yellow→orange retro ramp with a cream headline" /></td>
  </tr>
  <tr>
    <td align="center"><b>catppuccin-frappe</b><br><img src="images/torvalds-catppuccin-frappe.png" alt="catppuccin-frappe theme — pink headline and green ramp on Catppuccin Frappé base" /></td>
    <td align="center"><b>catppuccin-mocha</b><br><img src="images/torvalds-catppuccin-mocha.png" alt="catppuccin-mocha theme — pink headline and green ramp on Catppuccin Mocha base" /></td>
  </tr>
  <tr>
    <td align="center"><b>midnight</b><br><img src="images/torvalds-midnight.png" alt="midnight theme — torvalds's contribution heatmap on a blue-purple gradient" /></td>
    <td align="center"><b>paper</b><br><img src="images/torvalds-paper.png" alt="paper theme — torvalds's contribution heatmap in deep navy on cream" /></td>
  </tr>
  <tr>
    <td align="center"><b>blossom</b><br><img src="images/torvalds-blossom.png" alt="blossom theme — torvalds's contribution heatmap in purple on pastel pink" /></td>
    <td align="center"><b>ocean</b><br><img src="images/torvalds-ocean.png" alt="ocean theme — torvalds's contribution heatmap in teal on pale aqua" /></td>
  </tr>
</table>

- `auto` — sync with system appearance (default; switches between `github-light` and `github-dark` based on macOS Light/Dark Mode).
- `github-dark` / `github-light` — the canonical GitHub palettes.
- `tokyo-night` — deep midnight-blue with a blue→magenta ramp and a cyan headline.
- `dracula` — neon-green ramp anchored on `#50fa7b`, hot-pink headline.
- `nord` — cool polar-night base with a frost-blue ramp and a snow headline.
- `gruvbox-dark` — warm retro palette: yellow→orange ramp on a soft brown base, cream headline.
- `catppuccin-frappe` / `catppuccin-mocha` — Catppuccin palette with a pink headline and green ramp on each flavor's base.
- `midnight` — deep blue-purple gradient with a custom green ramp.
- `paper` — single-ink deep navy on textured off-white.
- `blossom` — purple ramp on pastel pink, rich rose headline.
- `ocean` — teal→navy ramp on pale aqua, slate headline.

Switch any time:

```sh
gh-wallpaper theme tokyo-night
gh-wallpaper themes              # list built-in + custom themes
```

The wallpaper re-renders immediately and the new theme persists.

### Custom themes

Drop a JSON file into `~/Library/Application Support/gh-wallpaper/themes/`. The file name doesn't matter; the `id` field is what `gh-wallpaper theme <id>` uses.

```json
{
  "id": "aurora",
  "background": "#0b0f1a",
  "backgroundIsGradient": false,
  "cellRamp": ["#1a2333", "#2e7d6b", "#56c596", "#8af3c5", "#c9ffe5"],
  "headlineColor": "#a78bfa"
}
```

- `cellRamp` must have exactly 5 colors (level 0 → level 4, low → high contributions).
- Colors are CSS hex (`#RGB`, `#RGBA`, `#RRGGBB`, or `#RRGGBBAA` — the alpha forms render translucent on top of the background).
- `backgroundIsGradient: true` lets you pass a `url(#id)` reference in `background` and an `<linearGradient>`/`<radialGradient>` block in `gradientSVG`. See the built-in `midnight` for an example.
- Files that fail validation are logged once and skipped; they don't break the daemon.

`gh-wallpaper themes` will list any custom themes alongside the built-ins.

---

## How the background daemon works

`gh-wallpaper` installs a per-user launchd agent (`~/Library/LaunchAgents/dev.numbatt.gh-wallpaper.plist`) that runs `gh-wallpaper --daemon` and stays alive in the background.

**Adaptive polling:**
- Every ~2 minutes when your Mac is plugged in.
- Every ~5 minutes on battery (to save power).
- Paused entirely when offline; resumes the moment your network comes back.

**Instant triggers** (debounced to 30s):
- Wake from sleep.
- Network reachability change.
- Display configuration change (monitor plugged/unplugged).
- Login.

Each tick fetches your contribution data, hashes it together with theme + display geometry + system appearance, and only re-renders when something actually changed. A no-op tick costs nothing on your side.

Control the daemon:

```sh
gh-wallpaper pause       # stop the daemon, keep config
gh-wallpaper start       # resume
gh-wallpaper refresh     # force an immediate refresh
gh-wallpaper diagnose    # install state, last refresh, errors
gh-wallpaper uninstall   # full clean: stops daemon, restores prior wallpaper, deletes config
```

Logs live at `~/Library/Logs/gh-wallpaper/agent.log` (rotating, 1 MB max).

---

## How it gets your contribution data

`gh-wallpaper` reads the **public** contribution graph from `https://github.com/users/<you>/contributions` — the exact endpoint that renders your profile to anyone visiting `github.com/<you>`.

- No GitHub Personal Access Token.
- No OAuth, no login, no API key.
- No telemetry, no analytics. The binary talks to `github.com` and your local filesystem. That's it.

If you want private contributions on the wallpaper, toggle GitHub's "Include private contributions on my profile" setting. The endpoint we read honors it automatically.

---

## Linux (community recipe)

The macOS app doesn't run on Linux — it's built on AppKit and launchd. But the heatmap render is portable enough that a ~180-line shell script (`curl` + `rsvg-convert`) plus a systemd user timer gets you the spirit of the project: your wallpaper is your GitHub heatmap, and it refreshes itself hourly.

**What you get:** the 53×7 heatmap grid in 5 themes (`github-dark`, `github-light`, `catppuccin-mocha`, `dracula`, `tokyo-night`); a render-only systemd oneshot + hourly timer; per-DE wallpaper-setter snippets for GNOME, KDE Plasma 6, XFCE, Sway, Hyprland, and X11.

**What you don't get:** the "DESIGN BUILD SHIP" headline (the heatmap is the iconic part — porting hand-designed glyphs to shell isn't worth the maintenance cost), custom JSON themes, image backgrounds, multi-display awareness, the visual editor, or any kind of support contract. This is a community recipe — best-effort.

Quickstart (Debian/Ubuntu, GNOME):

```sh
sudo apt install -y curl librsvg2-bin
git clone https://github.com/Numbatt/github-heatmap-wallpaper
cd github-heatmap-wallpaper
install -Dm755 contrib/linux/heatmap.sh                      ~/.local/bin/heatmap.sh
install -Dm755 contrib/linux/examples/set-wallpaper-gnome.sh ~/.local/bin/set-wallpaper-gnome.sh
install -Dm644 contrib/linux/gh-wallpaper.{service,timer}    ~/.config/systemd/user/
systemctl --user edit gh-wallpaper.service
# in the editor, paste:
#   [Service]
#   Environment=GH_USER=your-github-username
#   ExecStartPost=%h/.local/bin/set-wallpaper-gnome.sh
systemctl --user daemon-reload
systemctl --user enable --now gh-wallpaper.timer
```

For KDE / XFCE / Sway / Hyprland / X11, see [`contrib/linux/README.md`](contrib/linux/README.md) — it has the per-DE walkthroughs, troubleshooting tips, and one important Wayland gotcha (don't run `swaybg` from a oneshot — see the contrib README for the right pattern).

---

## Requirements

**macOS app:**
- macOS 14 (Sonoma) or newer
- [`resvg`](https://github.com/RazrFalcon/resvg) on your `PATH` (`brew install resvg` — Homebrew installs this transitively)
- If building from source: Swift 5.7+ (Apple's Command Line Tools are enough — `xcode-select --install`; no full Xcode required)

**Linux recipe:** see [`contrib/linux/README.md`](contrib/linux/README.md). Just `curl` + `librsvg2-bin` (or your distro's equivalent) + systemd.

---

## Design notes

Architecture, scope, and tradeoffs live in [`SPEC.md`](SPEC.md). Licensed under [MIT](LICENSE).
