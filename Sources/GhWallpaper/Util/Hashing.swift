import CryptoKit
import Foundation

/// Stable hash combining everything that influences the rendered wallpaper.
///
/// Inputs:
///   - `calendar` — contributions data (only the day list affects render)
///   - `theme` — id + colors + ramp
///   - `canvas` — display geometry the SVG is built against
///   - `systemAppearance` — "light" | "dark" (drives `auto` theme resolution)
///
/// Output is a hex SHA-256 digest. Stable across processes (CryptoKit) so the
/// daemon can persist it in `state.json` and compare on next launch.
public func renderHash(
    calendar: ContributionCalendar,
    theme: Theme,
    canvas: SVGBuilder.Canvas,
    systemAppearance: String
) -> String {
    var hasher = SHA256()

    // Calendar: deterministic ordering already guaranteed by Scraper (oldest first).
    // We hash the iso date + level pairs only (skips username).
    hasher.update(data: Data("calendar:".utf8))
    for day in calendar.days {
        hasher.update(data: Data(day.isoDate.utf8))
        hasher.update(data: Data(":".utf8))
        hasher.update(data: Data(String(day.level).utf8))
        hasher.update(data: Data("\n".utf8))
    }

    // Theme: id + colors. Stream C may add fields here; including them later
    // simply means the hash changes once on upgrade, which is the correct
    // behavior (we want to re-render).
    hasher.update(data: Data("theme:".utf8))
    hasher.update(data: Data(theme.id.utf8))
    hasher.update(data: Data("|".utf8))
    hasher.update(data: Data(theme.background.utf8))
    hasher.update(data: Data("|".utf8))
    hasher.update(data: Data(String(theme.backgroundIsGradient).utf8))
    hasher.update(data: Data("|".utf8))
    hasher.update(data: Data(theme.cellRamp.joined(separator: ",").utf8))
    hasher.update(data: Data("|".utf8))
    hasher.update(data: Data(theme.headlineColor.utf8))

    // Canvas dimensions affect the layout math, so they are part of the hash.
    hasher.update(data: Data("\ncanvas:".utf8))
    hasher.update(data: Data(String(canvas.widthPx).utf8))
    hasher.update(data: Data("x".utf8))
    hasher.update(data: Data(String(canvas.heightPx).utf8))

    // System appearance — "auto" theme resolves on this; harmless to include
    // for non-auto themes since it's a stable input.
    hasher.update(data: Data("\nappearance:".utf8))
    hasher.update(data: Data(systemAppearance.utf8))

    let digest = hasher.finalize()
    return digest.map { String(format: "%02x", $0) }.joined()
}
