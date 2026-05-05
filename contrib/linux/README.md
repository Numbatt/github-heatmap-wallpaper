# gh-wallpaper on Linux (community recipe)

This is a **community recipe**, not a port. The macOS app at the root of this repo is the supported build; this directory ships a parallel implementation in `bash` + `curl` + `rsvg-convert` that renders just the GitHub contribution heatmap, plus a systemd timer to refresh it hourly. It exists so Linux users can have something rather than nothing.

**What you get:**

- The 53×7 heatmap grid in 5 themes: `github-dark`, `github-light`, `catppuccin-mocha`, `dracula`, `tokyo-night`.
- A systemd user service + hourly timer, with a randomized 0–5 min delay so we're polite to github.com.
- A render-only contract: `heatmap.sh` produces a PNG. You wire up your DE's wallpaper-setter via an `ExecStartPost=` drop-in (one line, see below).

**What you don't get (vs. the macOS app):**

- The "DESIGN BUILD SHIP" headline. Porting the hand-designed glyph data + scaling logic to shell would be ~150 LOC of awk that drifts every time the macOS renderer is tweaked. The heatmap is the iconic part.
- Custom JSON themes, image-backed themes, the visual editor. Stick to the 5 built-ins.
- Multi-display awareness, HiDPI auto-detection, the adaptive polling that the launchd daemon does on macOS.
- Any kind of support contract. This is best-effort. If GitHub changes their HTML, the macOS app's canary CI will catch it within a day; the shell parser will need a manual fix.

---

## Install

### 1. Install dependencies

```sh
# Debian / Ubuntu
sudo apt install -y curl librsvg2-bin

# Fedora
sudo dnf install -y curl librsvg2-tools

# Arch
sudo pacman -S curl librsvg
```

### 2. Drop the script and units in place

```sh
git clone https://github.com/Numbatt/github-heatmap-wallpaper
cd github-heatmap-wallpaper

install -Dm755 contrib/linux/heatmap.sh                 ~/.local/bin/heatmap.sh
install -Dm644 contrib/linux/gh-wallpaper.service       ~/.config/systemd/user/gh-wallpaper.service
install -Dm644 contrib/linux/gh-wallpaper.timer         ~/.config/systemd/user/gh-wallpaper.timer
install -Dm755 contrib/linux/examples/set-wallpaper-gnome.sh ~/.local/bin/set-wallpaper-gnome.sh
# (substitute the example for your desktop — see "Set wallpaper" section below)
```

### 3. Configure your username and wallpaper-setter

The service ships with `GH_USER=` empty so it fails fast if you forget this step. Override via a drop-in:

```sh
systemctl --user edit gh-wallpaper.service
```

Add (replacing `your-github-username`):

```ini
[Service]
Environment=GH_USER=your-github-username
Environment=GH_THEME=github-dark
ExecStartPost=%h/.local/bin/set-wallpaper-gnome.sh
```

Substitute `set-wallpaper-gnome.sh` with the right script for your desktop (see below).

### 4. Enable the timer

```sh
systemctl --user daemon-reload
systemctl --user enable --now gh-wallpaper.timer
systemctl --user list-timers gh-wallpaper.timer    # verify it's scheduled
systemctl --user start  gh-wallpaper.service       # render once now
```

Check the result:

```sh
file ~/.cache/gh-wallpaper/heatmap.png             # should be a PNG of your canvas size
journalctl --user-unit=gh-wallpaper.service -n 50  # logs from the most recent runs
```

### 5. (Optional) Run the timer when logged out

By default, systemd user timers only fire while you're logged in. If you want the wallpaper refreshed on a desktop that idles overnight at the GDM screen, enable lingering:

```sh
loginctl enable-linger "$USER"
```

Skip this on a laptop — the default behavior is what you want.

---

## Set wallpaper for your desktop

Each example below is a one-line drop-in for `ExecStartPost=`. Pick the one that matches your DE; install it to `~/.local/bin/`; reference it from `systemctl --user edit gh-wallpaper.service`.

### GNOME, Cinnamon, MATE — `set-wallpaper-gnome.sh`

Sets both `picture-uri` and `picture-uri-dark` so the wallpaper applies regardless of appearance. Works on Wayland and X11 sessions.

### KDE Plasma 6 — `set-wallpaper-kde.sh`

Plasma's wallpaper API is a JS snippet evaluated by `plasmashell` over DBus. The example tries `qdbus6` (Plasma 6) and falls back to `qdbus` (Plasma 5).

### XFCE — `set-wallpaper-xfce.sh`

XFCE stores the wallpaper path in xfconf, with property paths varying per monitor + workspace. The example walks every `last-image` property and sets each to the rendered PNG.

### Sway — `set-wallpaper-swaybg.sh`

**Important:** do NOT spawn `swaybg` from the systemd oneshot — it will daemonize, then die on the next render, and your wallpaper will go black.

The right pattern is:

1. Add this line to `~/.config/sway/config` once:
   ```
   output * bg /home/YOU/.cache/gh-wallpaper/heatmap.png fill
   ```
2. The example script just runs `swaymsg reload`, which makes Sway re-read the file at the path it already knows.

### Hyprland

Same idea as Sway — `hyprpaper` must be running already (started by Hyprland itself, not the timer). In `~/.config/hypr/hyprpaper.conf`:

```
preload  = ~/.cache/gh-wallpaper/heatmap.png
wallpaper = ,~/.cache/gh-wallpaper/heatmap.png
ipc = on
```

Then your `ExecStartPost=` is:

```
ExecStartPost=hyprctl hyprpaper reload ,%h/.cache/gh-wallpaper/heatmap.png
```

### X11 (i3, dwm, openbox, bspwm, awesome) — `set-wallpaper-feh.sh`

`feh --bg-fill` sets the X11 root pixmap and exits. Your WM's autostart should also call `~/.fehbg` at login to restore the wallpaper after a fresh session — or just let the systemd timer's next firing handle it.

---

## Themes

| id | background | level 0–4 ramp |
|---|---|---|
| `github-dark` | `#0d1117` | `#161b22 → #39d353` |
| `github-light` | `#ffffff` | `#ebedf0 → #216e39` |
| `catppuccin-mocha` | `#1e1e2e` | `#313244 → #caf0c1` |
| `dracula` | `#282a36` | `#44475a → #b4ffc7` |
| `tokyo-night` | `#1a1b26` | `#16161e → #bb9af7` |

Switch by changing `Environment=GH_THEME=` in the service drop-in:

```sh
systemctl --user edit gh-wallpaper.service
# update GH_THEME, save
systemctl --user start gh-wallpaper.service
```

To see the full palette for any theme, run `heatmap.sh --themes` or read the inline `THEMES_TSV` block at the top of `heatmap.sh`.

---

## Troubleshooting

```sh
# Did the service run? What did it log?
journalctl --user-unit=gh-wallpaper.service -n 50

# Is the timer scheduled?
systemctl --user list-timers gh-wallpaper.timer

# When does it next fire?
systemctl --user status gh-wallpaper.timer

# Force a render right now
systemctl --user start gh-wallpaper.service

# Run the renderer directly to see exactly where it fails
heatmap.sh --user your-github-username --output /tmp/test.png
```

**Common errors and exit codes:**

| Exit | Meaning | What to check |
|---:|---|---|
| 1 | User error (missing flag, bad theme, bad canvas) | Re-read the error message; `--help` is your friend. |
| 2 | Missing dependency | Install `curl` or `librsvg2-bin` per your distro. |
| 3 | Parse failure (no contribution cells) | GitHub may have changed their markup. Check the [main repo's canary CI](https://github.com/Numbatt/github-heatmap-wallpaper/actions); we'll coordinate a fix there. |
| 4 | Network failure (curl returned non-2xx) | Username might be wrong (404), or you're offline. |
| 5 | Render failure | `rsvg-convert` exit non-zero. Try `--svg-only` to inspect the SVG. |

---

## Uninstall

```sh
systemctl --user disable --now gh-wallpaper.timer
rm ~/.config/systemd/user/gh-wallpaper.{service,timer}
rm -rf ~/.config/systemd/user/gh-wallpaper.service.d
rm ~/.local/bin/heatmap.sh ~/.local/bin/set-wallpaper-*.sh
rm -rf ~/.cache/gh-wallpaper
systemctl --user daemon-reload
```

The wallpaper itself stays as whatever was set last; restore your previous wallpaper through your DE's settings.

---

## Limitations

- No headline, no custom themes, no image backgrounds, no multi-display, no HiDPI auto-detection.
- The shell script's HTML parser is simpler than the Swift one; it will fail loudly (exit 3) if GitHub changes the markup, where the macOS app's canary will detect the change earlier and we'll coordinate a fix.
- 5 hardcoded themes. If you want a custom palette, edit the `THEMES_TSV` block at the top of `heatmap.sh` directly.
- Only tested by the maintainer on GNOME (the other DE snippets follow each project's official wallpaper-setting docs but may need adjustment on your specific setup).

For the full feature set — visual theme editor, custom JSON themes, image backgrounds, adaptive daemon, multi-display, system-appearance follow — use the macOS app.

## A note on telemetry

This script makes one network request: a `curl` to `https://github.com/users/<you>/contributions`. That's it. No analytics, no phone-home, no dependency on any service besides github.com. Read the script — it's ~180 lines of bash. If you ever want to add telemetry, please don't. The privacy story is one of this project's load-bearing features.

## See also

- [Main README](../../README.md) — the macOS app
- [SPEC.md](../../SPEC.md) — design rationale for the macOS app
- [`heatmap.sh`](heatmap.sh) — the renderer itself, ~180 lines of bash
