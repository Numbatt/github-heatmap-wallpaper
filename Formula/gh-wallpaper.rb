class GhWallpaper < Formula
  desc "GitHub contribution heatmap as your macOS desktop wallpaper"
  homepage "https://github.com/diegorico/gh-wallpaper"
  # TODO: before tagging v0.1, replace url + sha256 + version with the release tarball.
  url "https://github.com/diegorico/gh-wallpaper/archive/refs/tags/v0.1.0.tar.gz"
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  head "https://github.com/diegorico/gh-wallpaper.git", branch: "main"

  depends_on xcode: ["15.0", :build]
  depends_on macos: :sonoma
  depends_on "resvg"

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/gh-wallpaper"
  end

  test do
    # M1 wires `gh-wallpaper <username>` directly. Once Wave 3 lands
    # the subcommand dispatcher, switch this to `--help`.
    assert_path_exists bin/"gh-wallpaper"
    assert_predicate bin/"gh-wallpaper", :executable?
  end
end
