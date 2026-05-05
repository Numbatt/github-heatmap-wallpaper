#!/usr/bin/env bash
#
# install-stats.sh — snapshot install signals from GitHub's API into
# docs/install-stats.ndjson, then regenerate docs/INSTALL_STATS.md and
# the README install-stats block from the accumulated history.
#
# Usage:
#   script/install-stats.sh             # snapshot + report (default)
#   script/install-stats.sh snapshot    # append today's NDJSON row only
#   script/install-stats.sh report      # rebuild markdown from NDJSON only
#
# Requires: gh CLI authenticated (or GH_TOKEN/GITHUB_TOKEN in the env, as
# CI uses), plus python3. Read-only against GitHub's releases API.

set -euo pipefail

REPO="Numbatt/github-heatmap-wallpaper"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NDJSON="$REPO_ROOT/docs/install-stats.ndjson"
STATS_MD="$REPO_ROOT/docs/INSTALL_STATS.md"
README="$REPO_ROOT/README.md"

cmd="${1:-all}"

cmd_snapshot() {
    python3 - "$REPO" "$NDJSON" <<'PY'
import json, pathlib, subprocess, sys
from datetime import datetime, timezone

repo, ndjson_path = sys.argv[1], pathlib.Path(sys.argv[2])

def gh(*args):
    out = subprocess.run(
        ["gh", "api", *args],
        check=True, capture_output=True, text=True,
    )
    return json.loads(out.stdout) if out.stdout.strip() else None

now = datetime.now(timezone.utc).replace(microsecond=0)
today = now.strftime("%Y-%m-%d")

releases = gh(f"repos/{repo}/releases", "--paginate")
release_assets = []
bottles_by_tag = {}
for rel in releases or []:
    tag = rel["tag_name"]
    for asset in rel.get("assets", []):
        if ".bottle" not in asset["name"] or not asset["name"].endswith(".tar.gz"):
            continue
        release_assets.append({
            "tag": tag,
            "name": asset["name"],
            "downloads": asset["download_count"],
        })
        bottles_by_tag[tag] = bottles_by_tag.get(tag, 0) + asset["download_count"]

# "Latest tag" = first release in API order (releases endpoint returns newest first).
latest_tag = releases[0]["tag_name"] if releases else None
downloads_of_latest = bottles_by_tag.get(latest_tag, 0)
bottles_all_time = sum(bottles_by_tag.values())

record = {
    "date": today,
    "snapshot_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "latest_tag": latest_tag,
    "release_assets": release_assets,
    "totals": {
        "downloads_of_latest": downloads_of_latest,
        "bottles_all_time": bottles_all_time,
        "bottles_by_tag": bottles_by_tag,
    },
}

# Read existing NDJSON, dedupe by date, sort, write back.
existing = {}
if ndjson_path.exists():
    for line in ndjson_path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        existing[row["date"]] = row
existing[today] = record

ndjson_path.parent.mkdir(parents=True, exist_ok=True)
with ndjson_path.open("w") as f:
    for d in sorted(existing.keys()):
        f.write(json.dumps(existing[d], separators=(",", ":")) + "\n")

print(f"snapshot {today}: {downloads_of_latest} on latest ({latest_tag}), "
      f"{bottles_all_time} all-time events")
PY
}

cmd_report() {
    python3 - "$NDJSON" "$STATS_MD" "$README" <<'PY'
import json, pathlib, re, sys

ndjson_path, stats_md_path, readme_path = (pathlib.Path(p) for p in sys.argv[1:4])

if not ndjson_path.exists() or ndjson_path.stat().st_size == 0:
    print(f"error: no data at {ndjson_path}; run `snapshot` first", file=sys.stderr)
    sys.exit(1)

rows = [json.loads(l) for l in ndjson_path.read_text().splitlines() if l.strip()]
rows.sort(key=lambda r: r["date"])
latest = rows[-1]

# --- README block ----------------------------------------------------------
readme = readme_path.read_text()
block_inner = (
    f"**Installs of latest release ({latest['latest_tag']}):** "
    f"{latest['totals']['downloads_of_latest']} · "
    f"[full stats & methodology](docs/INSTALL_STATS.md)"
)
new_readme, n = re.subn(
    r"<!-- install-stats:start -->\n.*?\n<!-- install-stats:end -->",
    f"<!-- install-stats:start -->\n{block_inner}\n<!-- install-stats:end -->",
    readme,
    count=1,
    flags=re.DOTALL,
)
if n == 0:
    print("warn: README has no <!-- install-stats:start --> markers; skipping",
          file=sys.stderr)
else:
    readme_path.write_text(new_readme)

# --- INSTALL_STATS.md ------------------------------------------------------
t = latest["totals"]

per_version_rows = "\n".join(
    f"| `{tag}` | {count} |"
    for tag, count in sorted(t["bottles_by_tag"].items(), reverse=True)
)

md = f"""# Install stats

> *Auto-generated from `docs/install-stats.ndjson`. Last snapshot: **{latest['snapshot_at']}**. Do not hand-edit — re-run `script/install-stats.sh` to regenerate.*

## Install signals

| Metric | Value | What it counts |
|---|---:|---|
| **Installs of latest release** (`{latest['latest_tag']}`) | **{t['downloads_of_latest']}** | Bottles pulled for the newest tag. The most honest install number we have. |
| All-time install events | {t['bottles_all_time']} | Sum of every bottle download across every release. **Inflated by `brew upgrade` churn — not a user count.** |

## What is one "install"?

GitHub's release-asset `download_count` is an **event counter, not a user counter**. The API exposes no IP, user-agent, or anything we could use to de-dupe. Every `brew install` and every `brew upgrade` to a new version each register +1 against that version's bottle. So a single user who started on an early release and upgraded twice contributes +1 to three different versions — three events, one human.

This is why the headline figure is "installs of the latest release" rather than the inflated all-time sum. It's still imperfect (clean reinstalls double-count, stragglers on old versions undercount), but it's a far more honest signal than `bottles_all_time`.

## Per-version downloads

| Tag | Bottle downloads (cumulative, all platforms) |
|---|---:|
{per_version_rows}

## What's invisible to this tracker

- **Intel users and `--build-from-source` users.** They download GitHub's auto-generated source tarball, which the API doesn't expose download counts for.
- **Tap-only clones** (`brew tap Numbatt/tap` without installing). Those hit the `homebrew-tap` repo, which isn't queried here.
- **Anything client-side.** The binary doesn't phone home. No telemetry, no analytics — only release-asset download counts that GitHub already publishes.

## Privacy

Data source is GitHub's own public releases API for *this repo*. Snapshotting these counters does not change the privacy posture of the tool itself: the binary still talks only to `github.com` and your local filesystem. We persist what GitHub already publishes about the repo; we add nothing user-side.

## History

Each daily snapshot is one line in [`install-stats.ndjson`](install-stats.ndjson). The file is append-only (deduped by date so re-running the script on the same day overwrites that day's row). Total snapshots so far: **{len(rows)}**.
"""

stats_md_path.parent.mkdir(parents=True, exist_ok=True)
stats_md_path.write_text(md)
print(f"report regenerated: {stats_md_path.name}, README block updated")
PY
}

case "$cmd" in
    snapshot) cmd_snapshot ;;
    report)   cmd_report ;;
    all|"")   cmd_snapshot; cmd_report ;;
    *)
        echo "usage: $0 [snapshot|report]" >&2
        exit 1
        ;;
esac
