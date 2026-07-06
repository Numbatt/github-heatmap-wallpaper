# Install stats

> *Auto-generated from `docs/install-stats.ndjson`. Last snapshot: **2026-07-06T07:56:19Z**. Do not hand-edit — re-run `script/install-stats.sh` to regenerate.*

## Install signals

| Metric | Value | What it counts |
|---|---:|---|
| **Installs of latest release** (`v0.2.6`) | **4** | Bottles pulled for the newest tag. The most honest install number we have. |
| All-time install events | 83 | Sum of every bottle download across every release. **Inflated by `brew upgrade` churn — not a user count.** |

## What is one "install"?

GitHub's release-asset `download_count` is an **event counter, not a user counter**. The API exposes no IP, user-agent, or anything we could use to de-dupe. Every `brew install` and every `brew upgrade` to a new version each register +1 against that version's bottle. So a single user who started on an early release and upgraded twice contributes +1 to three different versions — three events, one human.

This is why the headline figure is "installs of the latest release" rather than the inflated all-time sum. It's still imperfect (clean reinstalls double-count, stragglers on old versions undercount), but it's a far more honest signal than `bottles_all_time`.

## Per-version downloads

| Tag | Bottle downloads (cumulative, all platforms) |
|---|---:|
| `v0.2.6` | 4 |
| `v0.2.5` | 4 |
| `v0.2.4` | 4 |
| `v0.2.3` | 4 |
| `v0.2.2` | 7 |
| `v0.2.1` | 4 |
| `v0.2.0` | 11 |
| `v0.1.3` | 9 |
| `v0.1.2.1` | 13 |
| `v0.1.2` | 11 |
| `v0.1.1` | 11 |
| `v0.1.0` | 1 |

## What's invisible to this tracker

- **Intel users and `--build-from-source` users.** They download GitHub's auto-generated source tarball, which the API doesn't expose download counts for.
- **Tap-only clones** (`brew tap Numbatt/tap` without installing). Those hit the `homebrew-tap` repo, which isn't queried here.
- **Anything client-side.** The binary doesn't phone home. No telemetry, no analytics — only release-asset download counts that GitHub already publishes.

## Privacy

Data source is GitHub's own public releases API for *this repo*. Snapshotting these counters does not change the privacy posture of the tool itself: the binary still talks only to `github.com` and your local filesystem. We persist what GitHub already publishes about the repo; we add nothing user-side.

## History

Each daily snapshot is one line in [`install-stats.ndjson`](install-stats.ndjson). The file is append-only (deduped by date so re-running the script on the same day overwrites that day's row). Total snapshots so far: **63**.
