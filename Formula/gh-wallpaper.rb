class GhWallpaper < Formula
  desc "GitHub contribution heatmap as your macOS desktop wallpaper"
  homepage "https://github.com/Numbatt/github-heatmap-wallpaper"
  url "https://github.com/Numbatt/github-heatmap-wallpaper/archive/refs/tags/v0.2.0.tar.gz"
  version "0.2.0"
  sha256 "143bbdd5955126f894975458c72518493564c8a56896a76cc96a50c76e1d1dcb"
  license "MIT"

  head "https://github.com/Numbatt/github-heatmap-wallpaper.git", branch: "main"

  bottle do
    root_url "https://github.com/Numbatt/github-heatmap-wallpaper/releases/download/v0.2.0"
    sha256 cellar: :any_skip_relocation, arm64_sequoia: "c82d2dc724bf704d6275d3b152c21c3b62358acd0fab065b654106e5e3367183"
    sha256 cellar: :any_skip_relocation, arm64_sonoma:  "c1a6310495e5021e02ff46aa66d456125af473b48a2cd6488955766ae8921e9c"
    sha256 cellar: :any_skip_relocation, arm64_tahoe:   "3233f4d22ceed94929f8c1fea5a55ae6d4a3db7fb3212f9965035762a8928187"
  end

  # Bottle block intentionally empty until release tag + bottles are built.
  # `script/update-bottle-block.sh v0.2.0` will splice in the real values
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
