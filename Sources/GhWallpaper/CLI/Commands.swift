import AppKit
import Foundation

/// Subcommand dispatcher: maps `argv` to a `runX(...)` handler.
public enum Commands {

    public static func dispatch(_ argv: [String]) async -> Int32 {
        var args = Array(argv.dropFirst())  // drop binary name
        // Strip -v / --verbose from anywhere in the arg list. Enables
        // stderr-mirror for Logger output across all subcommands.
        if let idx = args.firstIndex(where: { $0 == "-v" || $0 == "--verbose" }) {
            args.remove(at: idx)
            Logger.shared.consoleMirror = .debug
        }
        guard let first = args.first else {
            // `gh-wallpaper` with no args → wizard
            return await runWizard()
        }
        switch first {
        case "--help", "-h", "help":     return printHelp()
        case "--daemon", "daemon":       return await runDaemon()
        case "render":                   return await runRender(args: Array(args.dropFirst()))
        case "refresh":                  return await runRefresh()
        case "theme":                    return await runTheme(args: Array(args.dropFirst()))
        case "pause":                    return runPause()
        case "start":                    return runStart()
        case "displays":                 return runDisplays()
        case "diagnose":                 return runDiagnose()
        case "uninstall":                return runUninstall()
        default:
            // Convenience: `gh-wallpaper <username>` runs a one-shot render
            // for that user without touching saved config.
            return await runRender(args: ["--user", first])
        }
    }

    // MARK: - Subcommands

    private static func runWizard() async -> Int32 {
        do {
            _ = try await Wizard().run()
            return 0
        } catch {
            FileHandle.standardError.write(Data("wizard failed: \(error)\n".utf8))
            return 1
        }
    }

    private static func runDaemon() async -> Int32 {
        await Daemon().run()
        return 0
    }

    private static func runRender(args: [String]) async -> Int32 {
        var username: String? = nil
        var themeID: String? = nil
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--user":  username = args[safe: i + 1]; i += 2
            case "--theme": themeID  = args[safe: i + 1]; i += 2
            default: i += 1
            }
        }
        let config = try? ConfigStore.read()
        guard let user = username ?? config?.username else {
            FileHandle.standardError.write(Data(
                "no GitHub username — pass `--user <name>` or run `gh-wallpaper` to set up.\n".utf8
            ))
            return 1
        }
        // If --theme was passed, it must resolve. Silent fall-through to the
        // default would render a wallpaper that ignores the user's request.
        let theme: Theme
        if let themeID {
            guard let resolved = Themes.byId(themeID) else {
                FileHandle.standardError.write(Data(
                    "unknown theme: \(themeID) (valid: github-dark, github-light, paper, midnight, auto)\n".utf8
                ))
                return 1
            }
            theme = resolved
        } else {
            theme = config?.resolvedTheme() ?? Themes.githubDark
        }
        return await renderOneShot(username: user, theme: theme, setWallpaper: false)
    }

    private static func runRefresh() async -> Int32 {
        guard let config = try? ConfigStore.read() else {
            FileHandle.standardError.write(Data("no config; run `gh-wallpaper` to set up\n".utf8))
            return 1
        }
        return await runRefreshOnce(config: config)
    }

    private static func runRefreshOnce(config: UserConfig) async -> Int32 {
        return await renderOneShot(
            username: config.username,
            theme: config.resolvedTheme(),
            displaysMode: config.displays,
            setWallpaper: true
        )
    }

    private static func runTheme(args: [String]) async -> Int32 {
        guard let id = args.first else {
            FileHandle.standardError.write(Data("usage: gh-wallpaper theme <github-dark|github-light|paper|midnight|auto>\n".utf8))
            return 1
        }
        guard Themes.byId(id) != nil else {
            FileHandle.standardError.write(Data("unknown theme: \(id)\n".utf8))
            return 1
        }
        guard var config = try? ConfigStore.read() else {
            FileHandle.standardError.write(Data(
                "no config; run `gh-wallpaper` to set up before switching themes.\n".utf8
            ))
            return 1
        }
        config.themeID = id
        do {
            try ConfigStore.write(config)
            print("→ theme set to \(id); refreshing wallpaper…")
            return await runRefreshOnce(config: config)
        } catch {
            FileHandle.standardError.write(Data("could not save config: \(error)\n".utf8))
            return 1
        }
    }

    private static func runPause() -> Int32 {
        // Unload the launchd agent (gracefully — agent persists if reinstalled later).
        return LaunchAgent.pause()
    }

    private static func runStart() -> Int32 {
        // Always (re)install — this regenerates the plist with the current
        // binary path and bootstraps. Idempotent.
        do {
            try LaunchAgent.install()
            return 0
        } catch {
            FileHandle.standardError.write(Data("could not start daemon: \(error)\n".utf8))
            return 1
        }
    }

    private static func runDisplays() -> Int32 {
        let displays = DisplayEnumerator.all()
        print("connected displays:")
        for d in displays {
            print("  \(d.uuid)  \(d.widthPx)×\(d.heightPx)")
        }
        let config = try? ConfigStore.read()
        if let mode = config?.displays {
            print("\ncurrent setting: \(mode.serialized)")
        }
        print("(change with `gh-wallpaper` to re-run the setup wizard)")
        return 0
    }

    private static func runDiagnose() -> Int32 {
        let config = try? ConfigStore.read()
        let state = StateStore.read()
        let resvgPath: String = (try? Rasterizer().description) ?? "(rasterizer init failed — `brew install resvg`)"

        print("gh-wallpaper diagnose")
        print("─────────────────────")
        print("config: \(ConfigStore.exists() ? Paths.configFile.path : "(not set up — run `gh-wallpaper`)")")
        if let c = config {
            print("  username: \(c.username)")
            print("  theme: \(c.themeID)")
            print("  displays: \(c.displays.serialized)")
        }
        print("state:")
        if let last = state.lastRefreshAt {
            print("  last refresh: \(ISO8601DateFormatter().string(from: last))")
        } else {
            print("  last refresh: (none)")
        }
        print("  consecutive failures: \(state.consecutiveFailures)")
        if let err = state.lastError { print("  last error: \(err)") }
        print("rasterizer: \(resvgPath)")
        print("launchd plist: \(FileManager.default.fileExists(atPath: Paths.launchdPlist.path) ? "installed" : "not installed")")
        print("displays: \(DisplayEnumerator.all().count)")
        print("log: \(Paths.logFile.path)")
        return 0
    }

    private static func runUninstall() -> Int32 {
        print("uninstalling gh-wallpaper…")

        // 1. Unload launchd + delete plist.
        LaunchAgent.uninstall()

        // 2. Restore previous wallpaper.
        do {
            let cr = CaptureRestore()
            let results = try cr.restore()
            for r in results {
                print("  \(r.displayUUID): \(r.action)")
            }
            try cr.clear()
        } catch {
            print("  (restore step had an issue: \(error) — continuing)")
        }

        // 3. Remove support dir.
        try? FileManager.default.removeItem(at: Paths.supportDir)

        print("✓ uninstalled.")
        return 0
    }

    // MARK: - Render helper

    private static func renderOneShot(
        username: String,
        theme: Theme,
        displaysMode: UserConfig.DisplayMode = .all,
        setWallpaper: Bool
    ) async -> Int32 {
        do {
            let displays = displaysMode.filter(DisplayEnumerator.all())
            guard !displays.isEmpty else {
                FileHandle.standardError.write(Data("no displays detected\n".utf8))
                return 1
            }
            let scraper = Scraper()
            print("→ fetching contributions for @\(username)…")
            let calendar = try await scraper.fetch(username: username)
            print("→ parsed \(calendar.days.count) days")

            try Paths.ensureSupportDir()
            let rasterizer = try Rasterizer()
            let setter = WallpaperSetter()
            let builder = SVGBuilder()
            for display in displays {
                let canvas = SVGBuilder.Canvas(widthPx: display.widthPx, heightPx: display.heightPx)
                let svg = builder.build(calendar: calendar, theme: theme, canvas: canvas)

                // Write to a uniquely-suffixed path so macOS treats every render
                // as a new image. Without this, NSWorkspace.setDesktopImageURL
                // with the same path silently no-ops (the OS caches by path).
                let suffix = String(Int(Date().timeIntervalSince1970 * 1000))
                let png = Paths.wallpaperPNG(displayUUID: "\(display.uuid)-\(suffix)")
                try rasterizer.rasterize(svg: svg, toPNG: png, widthPx: display.widthPx, heightPx: display.heightPx)
                print("→ rendered \(png.lastPathComponent) (\(display.widthPx)×\(display.heightPx))")
                if setWallpaper {
                    try setter.set(pngURL: png, on: display)
                }

                // Clean up older PNGs for this display so we don't accumulate
                // disk garbage across thousands of refreshes.
                cleanupOldWallpapers(displayUUID: display.uuid, keep: png)
            }
            if setWallpaper { print("done.") }
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
    }

    /// Deletes wallpaper-<UUID>-*.png files for the given display except `keep`.
    /// Best-effort: ignores errors. Called after every render.
    private static func cleanupOldWallpapers(displayUUID: String, keep: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: Paths.supportDir, includingPropertiesForKeys: nil) else {
            return
        }
        let prefix = "wallpaper-\(displayUUID)-"
        for entry in entries where entry != keep {
            if entry.lastPathComponent.hasPrefix(prefix) && entry.pathExtension == "png" {
                try? fm.removeItem(at: entry)
            }
        }
        // Also clean up the legacy non-suffixed file if it exists
        // (from before we added cache-busting).
        let legacy = Paths.supportDir.appendingPathComponent("wallpaper-\(displayUUID).png")
        if FileManager.default.fileExists(atPath: legacy.path) && legacy != keep {
            try? fm.removeItem(at: legacy)
        }
    }

    // MARK: - Help

    private static func printHelp() -> Int32 {
        print("""
        gh-wallpaper — GitHub contribution heatmap as your macOS desktop wallpaper

        Usage:
          gh-wallpaper                         Run setup wizard (or re-run to reconfigure)
          gh-wallpaper <username>              One-shot render for the given user
          gh-wallpaper render [--user X]       Render PNG to disk without setting wallpaper
                              [--theme T]
          gh-wallpaper refresh                 Force an immediate refresh + set wallpaper
          gh-wallpaper theme <id>              Switch theme (github-dark|github-light|paper|midnight|auto)
          gh-wallpaper pause                   Stop the launchd agent
          gh-wallpaper start                   Start the launchd agent
          gh-wallpaper displays                List connected displays
          gh-wallpaper diagnose                Print install state, last refresh, errors
          gh-wallpaper uninstall               Full clean: launchd + config + restore prior wallpaper
          gh-wallpaper --daemon                Run the daemon (used by launchd)

        Pass -v / --verbose to mirror debug logs to stderr.

        Privacy: scrapes the public profile only. No PAT, no auth, no telemetry.
        """)
        return 0
    }
}

// MARK: - Helpers

private extension Array {
    subscript(safe i: Int) -> Element? {
        return indices.contains(i) ? self[i] : nil
    }
}

private extension Rasterizer {
    var description: String { "ok (resvg available)" }
}
