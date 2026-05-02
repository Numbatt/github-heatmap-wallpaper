# gh-wallpaper

Your GitHub contribution heatmap as your macOS desktop wallpaper. Refreshes itself in the background so your desktop always reflects what you've shipped this year.

![Wallpaper preview](image.png)

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

Four themes ship plus an `auto` mode that follows your macOS appearance setting:

<table>
  <tr>
    <td align="center"><b>github-dark</b><br><img src="images/torvalds-github-dark.png" alt="github-dark theme — torvalds's contribution heatmap on graphite" /></td>
    <td align="center"><b>github-light</b><br><img src="images/torvalds-github-light.png" alt="github-light theme — torvalds's contribution heatmap on white" /></td>
  </tr>
  <tr>
    <td align="center"><b>paper</b><br><img src="images/torvalds-paper.png" alt="paper theme — torvalds's contribution heatmap in deep navy on cream" /></td>
    <td align="center"><b>midnight</b><br><img src="images/torvalds-midnight.png" alt="midnight theme — torvalds's contribution heatmap on a blue-purple gradient" /></td>
  </tr>
</table>

- `auto` — sync with system appearance (default; switches between `github-light` and `github-dark` based on macOS Light/Dark Mode).
- `github-dark` — green-on-graphite.
- `github-light` — classic green-on-white.
- `midnight` — deep blue-purple gradient with a custom green ramp.
- `paper` — single-ink deep navy on textured off-white.

Switch any time:

```sh
gh-wallpaper theme paper
```

The wallpaper re-renders immediately and the new theme persists.

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

## Requirements

- macOS 14 (Sonoma) or newer
- [`resvg`](https://github.com/RazrFalcon/resvg) on your `PATH` (`brew install resvg` — Homebrew installs this transitively)
- If building from source: Swift 5.7+ (Apple's Command Line Tools are enough — `xcode-select --install`; no full Xcode required)

---

## Design notes

Architecture, scope, and tradeoffs live in [`SPEC.md`](SPEC.md). License: MIT.
