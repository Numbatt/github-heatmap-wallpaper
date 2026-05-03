class GhWallpaper < Formula
  desc "GitHub contribution heatmap as your macOS desktop wallpaper"
  homepage "https://github.com/Numbatt/github-heatmap-wallpaper"
  url "https://github.com/Numbatt/github-heatmap-wallpaper/archive/refs/tags/v0.1.2.1.tar.gz"
  version "0.1.2.1"
  sha256 "f2d020503ea2c2fb2358ef6605fb7635a8fad949cbfdf13e0e855f79a3fe7ea5"
  license "MIT"

  head "https://github.com/Numbatt/github-heatmap-wallpaper.git", branch: "main"

  bottle do
    root_url "https://github.com/Numbatt/github-heatmap-wallpaper/releases/download/v0.1.2"
    sha256 cellar: :any_skip_relocation, arm64_sequoia: "b247ff131723860ccd0caf14ebd25eb1ea347ff278925a5d2190aae81591e5ed"
    sha256 cellar: :any_skip_relocation, arm64_sonoma:  "653940caa980e657ba7af425d69b08a8cef4d5e4f58ec6c684c47056d1395a54"
    sha256 cellar: :any_skip_relocation, arm64_tahoe:   "aac83453a6e68201cefbc22cb4ec822f15d0d9384b07e722caf40669eb2f6094"
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
