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
let themes: [(label: String, theme: Theme)] = Themes.builtins.map { ($0.id, $0) }
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

// Optional: regenerate the README gallery PNGs (images/torvalds-<theme>.png).
// Hits github.com to fetch torvalds's contribution graph, so it's gated
// behind an env var to keep the default `swift run SnapshotGen` offline.
//
//   GENERATE_GALLERY=1 swift run SnapshotGen
//   GENERATE_GALLERY=1 GALLERY_THEMES=tokyo-night,dracula,nord swift run SnapshotGen
//
// Requires `resvg` on PATH (same as the binary). Output dimensions match
// the existing gallery (3420×2214) so the README table stays consistent.
if ProcessInfo.processInfo.environment["GENERATE_GALLERY"] == "1" {
    let galleryDir = "images"
    try fm.createDirectory(atPath: galleryDir, withIntermediateDirectories: true)
    let only = ProcessInfo.processInfo.environment["GALLERY_THEMES"]
        .map { Set($0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }) }
    let galleryThemes = themes.filter { only?.contains($0.label) ?? true }

    FileHandle.standardError.write(Data(
        "→ fetching torvalds for gallery (\(galleryThemes.count) themes)…\n".utf8
    ))
    let calendar = try await Scraper().fetch(username: "torvalds")
    FileHandle.standardError.write(Data(
        "  parsed \(calendar.days.count) days\n".utf8
    ))
    let rasterizer = try Rasterizer()
    let galleryCanvas = SVGBuilder.Canvas(widthPx: 3420, heightPx: 2214)
    for (label, theme) in galleryThemes {
        let svg = builder.build(calendar: calendar, theme: theme, canvas: galleryCanvas)
        let outURL = URL(fileURLWithPath: "\(galleryDir)/torvalds-\(label).png")
        try rasterizer.rasterize(svg: svg, toPNG: outURL, widthPx: 3420, heightPx: 2214)
        FileHandle.standardError.write(Data(
            "  wrote \(outURL.lastPathComponent)\n".utf8
        ))
    }
}
