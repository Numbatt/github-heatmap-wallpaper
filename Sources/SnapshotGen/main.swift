import Foundation
import GhWallpaper

// Generates the SVG snapshot files that SVGSnapshotTests asserts against.
//
// Run with:
//   swift run snapshot-gen
// or:
//   script/refresh-snapshots.sh
//
// Reads the committed HTML fixtures from Tests/GhWallpaperTests/fixtures/ and
// writes one SVG per (fixture × theme × canvas) combination into
// Tests/GhWallpaperTests/snapshots/. Re-run after any intentional change to
// SVGBuilder, Glyphs, Headline, HeatmapLayout, or Themes.

let fixturesDir = "Tests/GhWallpaperTests/fixtures"
let snapshotsDir = "Tests/GhWallpaperTests/snapshots"

struct CanvasSpec {
    let label: String
    let width: Int
    let height: Int
}

let fixtures = ["active", "sparse", "empty"]
let themes: [(label: String, theme: Theme)] = [
    ("github-dark", Themes.githubDark),
    ("github-light", Themes.githubLight),
    ("paper", Themes.paper),
    ("midnight", Themes.midnight),
]
let canvases = [
    CanvasSpec(label: "2880x1800", width: 2880, height: 1800),  // 14" MBP at retina
    CanvasSpec(label: "5120x2880", width: 5120, height: 2880),  // 5K external
]

let parser = HTMLParser()
let builder = SVGBuilder()
let fm = FileManager.default

try fm.createDirectory(atPath: snapshotsDir, withIntermediateDirectories: true)

var written = 0
for fixture in fixtures {
    let htmlURL = URL(fileURLWithPath: "\(fixturesDir)/\(fixture).html")
    let html = try String(contentsOf: htmlURL, encoding: .utf8)
    let days = try parser.parse(html: html)
    let calendar = ContributionCalendar(username: fixture, days: days)
    for (themeLabel, theme) in themes {
        for canvas in canvases {
            let svg = builder.build(
                calendar: calendar,
                theme: theme,
                canvas: SVGBuilder.Canvas(widthPx: canvas.width, heightPx: canvas.height)
            )
            let outURL = URL(fileURLWithPath:
                "\(snapshotsDir)/\(fixture)-\(themeLabel)-\(canvas.label).svg"
            )
            try svg.write(to: outURL, atomically: true, encoding: .utf8)
            written += 1
        }
    }
}

FileHandle.standardError.write(Data(
    "wrote \(written) snapshots to \(snapshotsDir)\n".utf8
))
