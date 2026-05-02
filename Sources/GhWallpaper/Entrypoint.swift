import Foundation

// Entry point. Two modes today:
//
//   1. `gh-wallpaper --daemon` — long-running daemon (Stream A; this PR).
//      Reads events from system observers + adaptive timer, refreshes the
//      wallpaper on change, never exits.
//
//   2. `gh-wallpaper [<username>]` — M1 vertical-slice spike: scrape, render,
//      set wallpaper, then exit. This is the manual test path. Wave 3 will
//      replace it with a full subcommand dispatcher.

@main
struct GhWallpaperEntrypoint {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())

        if args.contains("--daemon") {
            await runDaemon()
            return
        }

        await runM1Spike(username: args.first { !$0.hasPrefix("-") } ?? "diegorico")
    }

    static func runDaemon() async {
        let daemon = Daemon()
        // Daemon.run() returns only on cancellation. The launchd KeepAlive
        // policy will restart us if we ever exit; this should not happen in
        // practice.
        await daemon.run()
        exit(0)
    }

    static func runM1Spike(username: String) async {
        let theme = Themes.githubDark

        do {
            // 1. Display
            guard let display = DisplayEnumerator.main() else {
                FileHandle.standardError.write(Data("no main display detected\n".utf8))
                exit(1)
            }
            print("→ main display: \(display.widthPx)×\(display.heightPx) (UUID \(display.uuid))")

            // 2. Scrape + parse
            print("→ fetching contributions for @\(username)...")
            let scraper = Scraper()
            let calendar = try await scraper.fetch(username: username)
            print("→ parsed \(calendar.days.count) days, content hash \(calendar.contentHash)")

            // 3. SVG
            let canvas = SVGBuilder.Canvas(widthPx: display.widthPx, heightPx: display.heightPx)
            let svg = SVGBuilder().build(calendar: calendar, theme: theme, canvas: canvas)

            // 4. Rasterize via resvg
            let outputDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("gh-wallpaper", isDirectory: true)
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            let pngURL = outputDir.appendingPathComponent("wallpaper-\(display.uuid).png")
            print("→ rasterizing to \(pngURL.path)...")
            let rasterizer = try Rasterizer()
            try rasterizer.rasterize(
                svg: svg,
                toPNG: pngURL,
                widthPx: display.widthPx,
                heightPx: display.heightPx
            )
            let attrs = try? FileManager.default.attributesOfItem(atPath: pngURL.path)
            let size = (attrs?[.size] as? Int) ?? -1
            print("→ wrote \(size) bytes")

            // 5. Set wallpaper
            print("→ setting wallpaper...")
            try WallpaperSetter().set(pngURL: pngURL, on: display)
            print("done.")
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
}
