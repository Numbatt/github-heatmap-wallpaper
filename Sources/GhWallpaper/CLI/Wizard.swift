import Foundation

/// First-run + reconfigure flow. Re-runnable, non-destructive (pre-fills
/// current values when re-running).
public struct Wizard {
    public init() {}

    public func run() async throws -> UserConfig {
        let existing = (try? ConfigStore.read())

        printBanner()

        // Username
        let username: String = ask(
            prompt: "GitHub username (the part after github.com/, e.g. torvalds)",
            defaultValue: existing?.username,
            validator: { (input: String) -> String? in
                input.isEmpty ? "username required" : nil
            }
        )
        if !(await Self.usernameExists(username)) {
            print("warning: \(username) doesn't appear to exist on github.com — continuing anyway. You can re-run the wizard to fix.")
        }

        // Theme
        print("\nThemes:")
        print("  1) github-dark   2) github-light   3) paper   4) midnight   5) auto (matches macOS appearance)")
        let themeID: String = ask(
            prompt: "Theme",
            defaultValue: existing?.themeID ?? "github-dark",
            validator: { input in
                Themes.byId(input) == nil ? "unknown theme; pick one of: github-dark, github-light, paper, midnight, auto" : nil
            }
        )

        // Displays
        let displaysRaw: String = ask(
            prompt: "Displays (all, main, or 'custom:UUID1,UUID2')",
            defaultValue: existing?.displays.serialized ?? "all",
            validator: { _ in nil }
        )
        let displays = UserConfig.DisplayMode.parse(displaysRaw)

        let config = UserConfig(
            username: username,
            themeID: themeID,
            displays: displays,
            includePrivate: existing?.includePrivate ?? true
        )

        try ConfigStore.write(config)
        print("\n✓ saved \(Paths.configFile.path)")

        // SPEC §6 step 5–7: capture, preview/confirm/activate, done.
        try await activate(config: config)

        return config
    }

    /// Steps 5–7 of the wizard. Captures the prior wallpaper, renders + previews
    /// the new one, asks for confirmation, sets the wallpaper, and registers the
    /// launchd agent. Best-effort: a step failing here doesn't roll back the
    /// saved config — the user can re-run the wizard or use individual CLI
    /// subcommands to recover.
    private func activate(config: UserConfig) async throws {
        try Paths.ensureSupportDir()

        let allDisplays = DisplayEnumerator.all()
        guard !allDisplays.isEmpty else {
            print("\n(no displays detected — config saved but daemon not installed)")
            return
        }

        // Step 5: capture prior wallpaper. Idempotent — if previous-wallpapers.json
        // already exists from an earlier run, this is a no-op.
        do {
            try CaptureRestore().capture(displays: allDisplays)
        } catch {
            print("warning: could not snapshot prior wallpaper (\(error)) — continuing")
        }

        // Step 6: render → preview → confirm → activate.
        print("\n→ fetching contributions for @\(config.username)…")
        let scraper = Scraper()
        let calendar: ContributionCalendar
        do {
            calendar = try await scraper.fetch(username: config.username)
        } catch {
            print("error: could not fetch contributions: \(error)")
            print("config saved; re-run `gh-wallpaper` once the issue is resolved.")
            return
        }
        print("  parsed \(calendar.days.count) days")

        let theme = config.resolvedTheme()
        let rasterizer = try Rasterizer()
        let builder = SVGBuilder()
        let setter = WallpaperSetter()
        let primary = DisplayEnumerator.main() ?? allDisplays[0]
        let previewURL = Paths.supportDir.appendingPathComponent("preview.png")
        let previewSVG = builder.build(
            calendar: calendar,
            theme: theme,
            canvas: SVGBuilder.Canvas(widthPx: primary.widthPx, heightPx: primary.heightPx)
        )
        try rasterizer.rasterize(
            svg: previewSVG,
            toPNG: previewURL,
            widthPx: primary.widthPx,
            heightPx: primary.heightPx
        )
        openInPreview(previewURL)

        let confirmed: Bool = askYesNo(
            prompt: "Set as your wallpaper now?",
            defaultYes: true
        )
        if !confirmed {
            print("\nconfig saved. Run `gh-wallpaper start` to enable the background daemon when ready.")
            try? FileManager.default.removeItem(at: previewURL)
            return
        }

        // Render + set per target display, then register launchd.
        let targetDisplays = config.displays.filter(allDisplays)
        for display in targetDisplays {
            let canvas = SVGBuilder.Canvas(widthPx: display.widthPx, heightPx: display.heightPx)
            let svg = builder.build(calendar: calendar, theme: theme, canvas: canvas)
            let suffix = String(Int(Date().timeIntervalSince1970 * 1000))
            let png = Paths.supportDir.appendingPathComponent("wallpaper-\(display.uuid)-\(suffix).png")
            try rasterizer.rasterize(svg: svg, toPNG: png, widthPx: display.widthPx, heightPx: display.heightPx)
            try setter.set(pngURL: png, on: display)
            print("  wallpaper set on \(display.uuid)")
        }
        try? FileManager.default.removeItem(at: previewURL)

        // Register the daemon so future refreshes happen automatically.
        do {
            try LaunchAgent.install()
            print("✓ background daemon installed")
        } catch {
            print("warning: daemon registration failed (\(error))")
            print("you can retry with `gh-wallpaper start`.")
            return
        }

        // Step 7: done.
        print("""

        all set. gh-wallpaper will refresh:
          • every ~2 min on AC, ~5 min on battery
          • on wake, network reconnect, or display change
        log: \(Paths.logFile.path)
        run `gh-wallpaper --help` for commands.
        """)
    }

    private func openInPreview(_ url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Preview", url.path]
        try? p.run()
    }

    private func printBanner() {
        print("""

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
         gh-wallpaper setup
         GitHub contribution heatmap as your macOS desktop wallpaper.
         No tokens, no signup, no telemetry.
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        """)
    }

    private func ask(
        prompt: String,
        defaultValue: String?,
        validator: (String) -> String?
    ) -> String {
        while true {
            let suffix = defaultValue.map { " [\($0)]" } ?? ""
            print("\(prompt)\(suffix): ", terminator: "")
            let raw = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
            let value = raw.isEmpty ? (defaultValue ?? "") : raw
            if let err = validator(value) {
                print("  → \(err)")
                continue
            }
            return value
        }
    }

    private func askYesNo(prompt: String, defaultYes: Bool) -> Bool {
        let suffix = defaultYes ? " [Y/n]" : " [y/N]"
        print("\(prompt)\(suffix): ", terminator: "")
        let raw = (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if raw.isEmpty { return defaultYes }
        return raw.hasPrefix("y")
    }

    public static func usernameExists(_ username: String) async -> Bool {
        guard let url = URL(string: "https://github.com/\(username)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.setValue(Scraper.userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }
}
