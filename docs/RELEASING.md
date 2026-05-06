# Releasing gh-wallpaper

How to cut a new version, build bottles, update both formula copies, and verify a clean install. Follow this top-to-bottom and a release takes ~15 minutes of wall time (~5 of which is CI; the rest is local).

> **`/ship` is not enough.** `/ship` handles the git side of pushing code (commit, push, PR). It does **not** tag a release, build bottles, or update the Homebrew tap. For a real Homebrew release you need this runbook.

> **Linux is not part of the release pipeline.** The bottles + tap dance is macOS-only. Linux users `git clone` the repo at the latest tag and run `contrib/linux/install.sh` — they don't pull from Homebrew. So a release is "macOS bottle ships, Linux git tag exists for users who want to pin." Tagging a version is enough; no extra Linux step.

## TL;DR

```sh
# From the repo root, with: gh auth done, write access to both
# Numbatt/github-heatmap-wallpaper and Numbatt/homebrew-tap.

VERSION=0.1.2                                            # whatever you're shipping

# 1. Bump formula version + url. SHA stays placeholder; we'll fix it after the tag exists.
$EDITOR Formula/gh-wallpaper.rb     # change `version` and `url` to the new version
git add Formula/gh-wallpaper.rb
git commit -m "release: v$VERSION"
git push origin main

# 2. Tag and push.
git tag -a "v$VERSION" -m "v$VERSION"
git push origin "v$VERSION"

# 3. Compute the real sha256 (tarball now exists on github.com).
SHA=$(curl -sL "https://github.com/Numbatt/github-heatmap-wallpaper/archive/refs/tags/v$VERSION.tar.gz" | shasum -a 256 | awk '{print $1}')
echo "$SHA"   # 64 hex chars

# 4. Patch the placeholder sha + push.
sed -i.bak -E "s|sha256 \"[0-9a-f]+\"$|sha256 \"$SHA\"|" Formula/gh-wallpaper.rb && rm -f Formula/gh-wallpaper.rb.bak
git add Formula/gh-wallpaper.rb && git commit -m "fix(formula): real sha256 for v$VERSION tarball" && git push

# 5. CI fires automatically on the tag push and builds Sonoma + Sequoia bottles
#    (~5–10 min). Watch:
gh run list --workflow=bottle.yml --limit 1

# 6. While CI runs, build the Tahoe bottle locally (no GH runner has macOS 26 yet).
brew uninstall gh-wallpaper 2>/dev/null
brew untap Numbatt/tap 2>/dev/null
brew tap Numbatt/tap
brew install --build-bottle Numbatt/tap/gh-wallpaper
cd /tmp && rm -f *.bottle.* 2>/dev/null
brew bottle --no-rebuild --root-url="https://github.com/Numbatt/github-heatmap-wallpaper/releases/download/v$VERSION" --json gh-wallpaper
cp gh-wallpaper--$VERSION.arm64_tahoe.bottle.tar.gz gh-wallpaper-$VERSION.arm64_tahoe.bottle.tar.gz   # single-dash for URL
gh release upload "v$VERSION" "gh-wallpaper-$VERSION.arm64_tahoe.bottle.tar.gz" --clobber --repo Numbatt/github-heatmap-wallpaper

# 7. Wait for CI to finish (Sonoma + Sequoia bottles upload to the release).
#    Then run the helper script. It splices the bottle do block into both
#    Formula/gh-wallpaper.rb (this repo) and the tap repo, and pushes both.
cd /Users/diego/dev/github-heatmap-wallpaper      # back to repo root
./script/update-bottle-block.sh "v$VERSION"

# 8. Smoke test from a clean shell.
brew uninstall gh-wallpaper && brew untap Numbatt/tap
time brew install Numbatt/tap/gh-wallpaper      # expect ~5 sec, "Pouring bottle"
gh-wallpaper --help
```

If steps 1–8 finish without errors and the smoke install pours a bottle (instead of compiling), the release is shipped.

---

## Why two repos?

- **`Numbatt/github-heatmap-wallpaper`** — the source code, plus a copy of the formula at `Formula/gh-wallpaper.rb` for local testing and as a canonical reference.
- **`Numbatt/homebrew-tap`** — the public tap that `brew install Numbatt/tap/gh-wallpaper` reads. The repo name `homebrew-tap` is mandated by Homebrew (the `brew` CLI hardcodes the convention `<user>/homebrew-<tapname>` → `<user>/<tapname>`).

The two formula copies must stay in sync. `script/update-bottle-block.sh` writes to both atomically.

## Why does CI need to run for bottles?

A Homebrew bottle is a pre-compiled binary tagged to one specific (architecture, macOS version) combo. Bottles don't cross macOS versions — a binary built on Sequoia doesn't necessarily run cleanly on Sonoma because framework symbol layouts can shift. So we need one bottle per macOS version we want to support.

GitHub Actions runners cover `arm64_sonoma` (macos-14) and `arm64_sequoia` (macos-15). They don't yet offer a `macos-26` (Tahoe) runner, so we build that bottle locally on the maintainer's Tahoe Mac and upload it manually. When GitHub adds macos-26, add it to the matrix in `.github/workflows/bottle.yml`.

We don't ship Intel bottles. Apple Silicon shipped late 2020; Intel + macOS 14+ is a small, shrinking slice. Intel users still get a working install — just the from-source path (`swift build -c release`, ~30 sec).

## Things that have bitten us (don't re-bite)

### `--no-rebuild` is required

`brew bottle` without `--no-rebuild` may set `rebuild=N>0` based on prior local state. If one platform's bottle is `rebuild=0` and another's is `rebuild=1`, Homebrew's URL construction breaks because the `bottle do` block has a single `rebuild` field for all platforms. Always pass `--no-rebuild` to keep all bottles at rebuild=0. The CI workflow already does this; the manual Tahoe step in TL;DR step 6 also does.

### Single-dash vs double-dash filenames

`brew bottle` writes filenames with `--` (e.g. `gh-wallpaper--0.1.2.arm64_tahoe.bottle.tar.gz`). Homebrew's URL constructor uses `-` (e.g. `gh-wallpaper-0.1.2.arm64_tahoe.bottle.tar.gz`). Always rename to single-dash before uploading to a release. Both the workflow and the TL;DR above handle this.

### Workflow needs `contents: write`

Without it, `gh release upload` fails with HTTP 403. The permission is set in `.github/workflows/bottle.yml`. Don't remove it.

### Formula sha256 has to be patched after the tag is pushed

The formula's `url` references the tag's tarball, which doesn't exist until the tag is pushed. So the `version` bump and the `sha256` update can't happen in one commit unless you precompute the sha (which is fragile).

The pattern: bump `version`/`url` first with a placeholder `sha256`, push, tag, then patch the sha. CI works because the workflow's "Self-heal" step recomputes sha at runtime from the actual tarball — but the tap-side formula needs the real sha for end users to install. The TL;DR step 4 covers this.

### `amfid` SIGKILL on first launch (Sequoia/Tahoe)

macOS 15+ attaches `com.apple.provenance` to copied binaries. Combined with the linker-emitted ad-hoc signature, amfi sometimes decides the binary is untrusted and SIGKILLs it on launch (`zsh: killed gh-wallpaper`). Fix: re-sign in place after `bin.install`. Already done in `Formula/gh-wallpaper.rb`'s `def install`. If the smoke test fails with SIGKILL, verify `system "codesign", "--force", "--sign", "-", bin/"gh-wallpaper"` is still in the install block.

### Tap repo permissions

`script/update-bottle-block.sh` uses `gh repo clone` + `git push` against `Numbatt/homebrew-tap`. The maintainer's `gh` token needs `repo` scope (it does for personal repos owned by the same account; verify with `gh auth status`).

## Future improvements (not blocking)

1. **`script/release.sh`** that wraps TL;DR steps 1–4 in one command (`./script/release.sh 0.1.2`). Reduces release-time error surface.
2. **Auto-mirror tap from CI** via a `HOMEBREW_TAP_TOKEN` PAT secret. Lets the workflow push the bottle block directly instead of needing the maintainer to run the helper script. Nice but adds a long-lived secret to manage.
3. **Add `macos-26` to the matrix** in `.github/workflows/bottle.yml` once GitHub Actions offers it. Removes the manual Tahoe step.
4. **Submit to homebrew-core** when the project has stars/forks/users to pass their notability bar. That gets you bare `brew install gh-wallpaper` (no tap) plus auto-bottling for all platforms via Homebrew's CI infrastructure. Much later.
