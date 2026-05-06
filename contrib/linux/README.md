# gh-wallpaper on Linux (beta)

The Swift binary that powers the macOS app now compiles on Linux too. You get the same renderer, the same DESIGN BUILD SHIP headline, and all 11 built-in themes. The systemd timer and per-DE wallpaper-setter shims wrap it so the wallpaper updates on a schedule.

**Status: beta.** The maintainer ships from macOS and hasn't tested every distro × DE combination. If anything breaks, run `gh-wallpaper diagnose` and [open an issue](https://github.com/Numbatt/github-heatmap-wallpaper/issues/new?template=linux-bug.md) — the diagnose output makes triage fast.

**What you get:**

- Same renderer the macOS app uses (heatmap + headline) at any canvas size.
- All 11 built-in themes: `github-dark`, `github-light`, `paper`, `midnight`, `blossom`, `ocean`, `tokyo-night`, `dracula`, `nord`, `gruvbox-dark`, `catppuccin-frappe`, `catppuccin-mocha`.
- Custom JSON themes (drop a file at `~/.config/gh-wallpaper/themes/<name>.json`).
- Image-backed themes (`backgroundImagePath` in the JSON).
- Hourly refresh via systemd user timer with 0–5min jitter.
- Per-DE wallpaper-setter shims for GNOME, KDE Plasma, XFCE, sway, Hyprland, X11/feh.

**Not yet on Linux** (roadmap, defer for v2):

- Long-running event-driven daemon (refresh on wake / network-up / display change). The macOS app has this; Linux uses the simpler systemd timer for now.
- Multi-display rendering. Single primary display only.
- HiDPI scale-factor auto-detection. Pass `--canvas WxH` explicitly.
- Visual theme editor. Use `themes export` + edit JSON + `themes import` instead.
- Auto-detection of canvas size (xrandr/swaymsg cascade lands in v2). Pass `--canvas` for now.

---

## Install

```sh
git clone https://github.com/Numbatt/github-heatmap-wallpaper
cd github-heatmap-wallpaper
./contrib/linux/install.sh
```

`install.sh` handles dependencies (`resvg`, Swift toolchain), builds the binary, and drops the systemd units in place. It does **not** auto-enable the timer — you need to set your username and pick a wallpaper-setter first (see step 1–3 below).

After install:

### 1. Set your GitHub username

```sh
systemctl --user edit gh-wallpaper.service
```

Add (substituting your username and a canvas matching your screen resolution):

```ini
[Service]
Environment=GH_USER=your-github-username
Environment=GH_THEME=catppuccin-mocha
Environment=GH_CANVAS=2560x1440
```

`GH_CANVAS` matters — `install.sh` doesn't auto-detect your display. Find your resolution with `xrandr` (X11) or `swaymsg -t get_outputs` (sway/Hyprland) or your DE's display settings.

### 2. Pick the wallpaper-setter for your desktop

Same `systemctl --user edit gh-wallpaper.service`, append an `ExecStartPost`:

```ini
# GNOME, Cinnamon, MATE
ExecStartPost=%h/.local/bin/set-wallpaper-gnome.sh

# KDE Plasma 6 (or 5)
ExecStartPost=%h/.local/bin/set-wallpaper-kde.sh

# XFCE
ExecStartPost=%h/.local/bin/set-wallpaper-xfce.sh

# X11 tiling WMs (i3, dwm, openbox, bspwm, awesome)
ExecStartPost=%h/.local/bin/set-wallpaper-feh.sh
```

For **sway**, add this once to `~/.config/sway/config`:
```
output * bg /home/YOU/.cache/gh-wallpaper/wallpaper.png fill
```
Then use `ExecStartPost=%h/.local/bin/set-wallpaper-swaybg.sh` (which just runs `swaymsg reload`).

For **Hyprland**, add this to `~/.config/hypr/hyprpaper.conf`:
```
preload   = ~/.cache/gh-wallpaper/wallpaper.png
wallpaper = ,~/.cache/gh-wallpaper/wallpaper.png
ipc = on
```
Then use:
```
ExecStartPost=hyprctl hyprpaper reload ,%h/.cache/gh-wallpaper/wallpaper.png
```

### 3. Enable the timer

```sh
systemctl --user daemon-reload
systemctl --user enable --now gh-wallpaper.timer
systemctl --user start gh-wallpaper.service       # render once now
journalctl --user-unit=gh-wallpaper.service -n 50 # check for errors
```

To also refresh while logged out (overnight desktops):

```sh
loginctl enable-linger "$USER"
```

Skip on laptops — default behavior is what you want.

---

## Themes

```sh
gh-wallpaper themes              # list built-ins + custom
gh-wallpaper theme tokyo-night   # set the active theme in config
                                  # (next render uses it; or `systemctl --user
                                  # start gh-wallpaper.service` to apply now)
```

### Custom themes (no editor, JSON-based)

The visual theme editor is macOS-only, but you can hand-edit JSON:

```sh
# 1. Export a built-in to start from
mkdir -p ~/.config/gh-wallpaper/themes
gh-wallpaper themes export github-dark > ~/.config/gh-wallpaper/themes/my-theme.json

# 2. Edit the JSON: change "id" to a non-built-in name, tweak colors
$EDITOR ~/.config/gh-wallpaper/themes/my-theme.json

# 3. Verify it loaded + apply
gh-wallpaper themes
gh-wallpaper theme my-theme
systemctl --user start gh-wallpaper.service
```

Schema:

```json
{
  "id": "my-theme",
  "background": "#1a1b26",
  "headlineColor": "#ffffff",
  "cellRamp": ["#16161e", "#3d59a1", "#7aa2f7", "#9d7cd8", "#bb9af7"],
  "backgroundImagePath": "/optional/absolute/path/to/image.png",
  "backgroundDimAlpha": 0.4
}
```

`cellRamp` must be exactly 5 colors (level 0 → level 4). `backgroundImagePath` is optional; relative paths resolve against the JSON file's directory. `backgroundDimAlpha` is a 0.0–1.0 dim overlay between the image and the heatmap.

---

## Manual render (without the timer)

```sh
gh-wallpaper render \
    --user your-github-username \
    --theme dracula \
    --canvas 2560x1440 \
    --output ~/wallpaper.png
```

Useful for testing themes, generating screenshots, or rendering at a one-off canvas size.

---

## Diagnose / troubleshooting

```sh
gh-wallpaper diagnose
```

Prints distro, desktop, session type, resolved paths, last-refresh status, rasterizer location. Paste this output into any bug report — it covers everything needed to triage.

```sh
# Was the unit scheduled?
systemctl --user list-timers gh-wallpaper.timer

# Recent run logs
journalctl --user-unit=gh-wallpaper.service -n 100 --no-pager

# Render directly, skip systemd, see exactly where it fails
gh-wallpaper render --user YOU --canvas 1920x1080 --output /tmp/test.png
```

---

## Uninstall

```sh
systemctl --user disable --now gh-wallpaper.timer
rm  ~/.config/systemd/user/gh-wallpaper.{service,timer}
rm -rf ~/.config/systemd/user/gh-wallpaper.service.d
rm  ~/.local/bin/gh-wallpaper ~/.local/bin/set-wallpaper-*.sh
rm -rf ~/.cache/gh-wallpaper
rm -rf ~/.config/gh-wallpaper
systemctl --user daemon-reload
```

---

## Fallback: `heatmap.sh` (no Swift toolchain)

If you don't want a Swift install on your machine, the original bash recipe is still here. It renders the heatmap grid only — **no headline**, only 5 hardcoded themes, no custom themes, no image backgrounds. Drop in `~/.local/bin/heatmap.sh` and point the systemd unit at it instead of the Swift binary. The script is ~180 lines of bash + awk; if GitHub changes their HTML markup, it'll need a manual fix (the Swift binary's canary CI catches the same break automatically).

See `heatmap.sh --help` for usage.

---

## Privacy

The Swift binary makes one network request per refresh: an HTTPS GET to `https://github.com/users/<your-username>/contributions`. No PAT, no auth, no analytics, no telemetry. Same scraping rules as the macOS app. Source is in [`Sources/GhWallpaper/Data/Scraper.swift`](../../Sources/GhWallpaper/Data/Scraper.swift) — read it.

## See also

- [Main README](../../README.md)
- [SPEC.md](../../SPEC.md) — design rationale
- [`heatmap.sh`](heatmap.sh) — bash fallback renderer
