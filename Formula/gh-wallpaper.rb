class GhWallpaper < Formula
  desc "GitHub contribution heatmap as your macOS desktop wallpaper"
  homepage "https://github.com/Numbatt/github-heatmap-wallpaper"
  url "https://github.com/Numbatt/github-heatmap-wallpaper/archive/refs/tags/v0.2.2.tar.gz"
  version "0.2.2"
  sha256 "cefbed5d14109f93a08a8b5ce9ca146c6d971e638ce00de8d579c5077f2da846"
  license "MIT"

  head "https://github.com/Numbatt/github-heatmap-wallpaper.git", branch: "main"

  # Bottle block intentionally empty until release tag + bottles are built.
  # `script/update-bottle-block.sh v0.2.2` will splice in the real values
  # once CI publishes the Sonoma/Sequoia bottles and the manual Tahoe
  # bottle is uploaded — see docs/RELEASING.md.

  # No `depends_on xcode` — Homebrew enforces it as full Xcode.app, which
  # most macOS users don't have. The Swift toolchain that ships with Apple's
  # Command Line Tools (`xcode-select --install`) compiles this package fine.
  # If `swift` isn't on PATH at install time, Homebrew's build will fail with
  # a clear "swift: command not found" — much friendlier than blocking
  # everyone-without-the-full-IDE up front.
  depends_on macos: :sonoma
  depends_on "resvg"

  def install
    # Only build the gh-wallpaper product (skip the dev-only SnapshotGen
    # target). Saves ~5–10 sec of compile + link time for end users.
    system "swift", "build", "--disable-sandbox", "-c", "release", "--product", "gh-wallpaper"
    bin.install ".build/release/gh-wallpaper"
    # Re-sign ad-hoc in place. macOS Sequoia/Tahoe attaches a
    # `com.apple.provenance` xattr to copied binaries which, combined
    # with the linker-emitted ad-hoc signature, makes amfid SIGKILL the
    # process on first launch. A fresh `codesign --sign -` after the
    # copy generates a valid ad-hoc signature that amfi accepts.
    system "codesign", "--force", "--sign", "-", bin/"gh-wallpaper"
  end

  test do
    assert_match "gh-wallpaper", shell_output("#{bin}/gh-wallpaper --help")
  end
end
