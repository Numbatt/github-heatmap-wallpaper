class GhWallpaper < Formula
  desc "GitHub contribution heatmap as your macOS desktop wallpaper"
  homepage "https://github.com/Numbatt/github-heatmap-wallpaper"
  url "https://github.com/Numbatt/github-heatmap-wallpaper/archive/refs/tags/v0.2.6.tar.gz"
  version "0.2.6"
  sha256 "847ffc0f78fefa48faa9406c61b707ae455f7a4f02f8926b9eddc37c57c2c7c5"
  license "MIT"

  head "https://github.com/Numbatt/github-heatmap-wallpaper.git", branch: "main"

  bottle do
    root_url "https://github.com/Numbatt/github-heatmap-wallpaper/releases/download/v0.2.5"
    sha256 cellar: :any_skip_relocation, arm64_sequoia: "7ead417a1ea9f07dbff86baa8b6519bf8967fe128adc0d750d6ad3c8a4b8d76f"
    sha256 cellar: :any_skip_relocation, arm64_sonoma:  "181dc82a47738ba36c61f6410b15684c9e51fb897a60f4f2da3170a4a505790f"
    sha256 cellar: :any_skip_relocation, arm64_tahoe:   "53b76ef70c9c4830c77521f961daf945fcd8be51b21534c095bfe060b42adf6c"
  end

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
