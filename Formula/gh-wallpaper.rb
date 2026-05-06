class GhWallpaper < Formula
  desc "GitHub contribution heatmap as your macOS desktop wallpaper"
  homepage "https://github.com/Numbatt/github-heatmap-wallpaper"
  url "https://github.com/Numbatt/github-heatmap-wallpaper/archive/refs/tags/v0.2.1.tar.gz"
  version "0.2.1"
  sha256 "dd63cc4b4cd58ee7e85734b2c0d542065ae919de6a50a14ba148060e0296a649"
  license "MIT"

  head "https://github.com/Numbatt/github-heatmap-wallpaper.git", branch: "main"

  bottle do
    root_url "https://github.com/Numbatt/github-heatmap-wallpaper/releases/download/v0.2.1"
    sha256 cellar: :any_skip_relocation, arm64_sequoia: "b22a58c638f0fa24e9233c0ce84c0a722bc45b9474220260581d1009b529440b"
    sha256 cellar: :any_skip_relocation, arm64_sonoma:  "635d46f4fac987518f2e311c0138bcb5a7a805c105871498d7f7489cc2c935e3"
    sha256 cellar: :any_skip_relocation, arm64_tahoe:   "4f98e58bafd58828ad663f83b7c12888a3633ef52278be87f1eb748d036edf05"
  end

  # Bottle block intentionally empty until release tag + bottles are built.
  # `script/update-bottle-block.sh v0.2.1` will splice in the real values
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
