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
            prompt: "GitHub username",
            defaultValue: nil,
            validator: { (input: String) -> String? in
                input.isEmpty ? "username required" : nil
            }
        )
        if !(await Self.usernameExists(username)) {
            print("warning: \(username) doesn't appear to exist on github.com — continuing anyway. You can re-run the wizard to fix.")
        }

        // Theme — ordered most-likely first. Accepts a number (1–5) or the
        // theme ID. Visible labels for `auto` use GitHub's wording ("sync
        // with system") but the persisted ID stays `auto` for stability.
        let themeID = pickTheme(existing: existing?.themeID)

        // Displays — numbered picker. The user can type "all", "main",
        // or comma-separated indices ("1", "1,3").
        let detected = DisplayEnumerator.all()
        let displays = pickDisplays(
            from: detected,
            existing: existing?.displays
        )

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
    private func activate(config initialConfig: UserConfig) async throws {
        var config = initialConfig
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

        let rasterizer = try Rasterizer()
        let builder = SVGBuilder()
        let setter = WallpaperSetter()
        let primary = DisplayEnumerator.main() ?? allDisplays[0]
        let previewURL = Paths.supportDir.appendingPathComponent("preview.png")

        // Preview/confirm loop: if the user rejects the rendered preview, we
        // offer to pick a different theme and re-preview without re-fetching
        // the calendar. They can iterate themes until they find one they like
        // (or bail out, which preserves the saved config).
        var confirmedTheme: Theme? = nil
        previewLoop: while true {
            let candidate = config.resolvedTheme()
            let previewSVG = builder.build(
                calendar: calendar,
                theme: candidate,
                canvas: SVGBuilder.Canvas(widthPx: primary.widthPx, heightPx: primary.heightPx)
            )
            try rasterizer.rasterize(
                svg: previewSVG,
                toPNG: previewURL,
                widthPx: primary.widthPx,
                heightPx: primary.heightPx
            )

            print("""

            Next: I'll open the rendered wallpaper in Preview so you can see what it'll
            look like before applying it. Close the preview when you're done and come
            back here to confirm.
            """)
            print("Press Enter to open the preview…", terminator: "")
            _ = readLine()
            openInPreview(previewURL)

            if askYesNo(prompt: "Set as your wallpaper now?", defaultYes: true) {
                confirmedTheme = candidate
                break previewLoop
            }

            if !askYesNo(prompt: "Want to try a different theme?", defaultYes: false) {
                print("\nconfig saved. Run `gh-wallpaper start` to enable the background daemon when ready.")
                try? FileManager.default.removeItem(at: previewURL)
                return
            }

            config.themeID = pickTheme(existing: config.themeID)
            try ConfigStore.write(config)
        }
        guard let theme = confirmedTheme else { return }

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
          • every ~2 min when plugged in, ~5 min on battery
          • on wake, network reconnect, or display change
        log: \(Paths.logFile.path)
        run `gh-wallpaper --help` for commands.
        """)
    }

    /// Theme picker. Lists themes most-likely-first, accepts either a number
    /// (1–N) or the theme ID. Re-prompts until the user picks something valid.
    private func pickTheme(existing: String?) -> String {
        // Order intentionally: auto first (most flexible), then dark/light,
        // then specialty themes. Display labels are user-friendly; the
        // persisted IDs stay aligned with `Themes.byId(_:)`.
        let choices: [(id: String, label: String)] = [
            ("auto", "auto — sync with system appearance"),
            ("github-dark", "github-dark"),
            ("github-light", "github-light"),
            ("midnight", "midnight"),
            ("paper", "paper"),
            ("blossom", "blossom"),
            ("sunset", "sunset"),
            ("ocean", "ocean"),
            ("forest", "forest"),
        ]
        print("\nThemes:")
        for (i, choice) in choices.enumerated() {
            print("  \(i + 1)) \(choice.label)")
        }
        // Default: existing config if re-running, else option 1 (auto).
        let defaultLabel: String = {
            if let existing, choices.contains(where: { $0.id == existing }) {
                if let idx = choices.firstIndex(where: { $0.id == existing }) {
                    return "\(idx + 1)"
                }
                return existing
            }
            return "1"
        }()
        while true {
            print("Theme [\(defaultLabel)]: ", terminator: "")
            let raw = (readLine() ?? "").trimmingCharacters(in: .whitespaces)
            let input = raw.isEmpty ? defaultLabel : raw
            // Accept either a number or a theme ID.
            if let n = Int(input), (1...choices.count).contains(n) {
                return choices[n - 1].id
            }
            if Themes.byId(input) != nil {
                return input
            }
            let validIDs = choices.map { $0.id }.joined(separator: ", ")
            print("  → pick a number 1–\(choices.count) or one of: \(validIDs)")
        }
    }

    /// Renders a numbered list of detected displays and prompts the user to
    /// pick `all`, `main`, a single index, or a comma-separated set of
    /// indices. Falls back to `.all` when nothing is detected.
    private func pickDisplays(
        from detected: [DisplayInfo],
        existing: UserConfig.DisplayMode?
    ) -> UserConfig.DisplayMode {
        guard !detected.isEmpty else { return .all }
        print("\nDetected displays:")
        for (i, d) in detected.enumerated() {
            let mainTag = d.isMain ? "  (main)" : ""
            print("  \(i + 1)) \(d.uuid)  \(d.widthPx)×\(d.heightPx)\(mainTag)")
        }
        let defaultDisplay = displayDefault(for: existing, available: detected)
        while true {
            print("Apply to (all / main / 1 / 1,2) [\(defaultDisplay)]: ", terminator: "")
            let raw = (readLine() ?? "").trimmingCharacters(in: .whitespaces)
            let input = raw.isEmpty ? defaultDisplay : raw
            switch input.lowercased() {
            case "all": return .all
            case "main": return .mainOnly
            default:
                let parts = input.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let indices = parts.compactMap { Int($0) }
                guard !indices.isEmpty, indices.count == parts.count else {
                    print("  → please enter `all`, `main`, or numbers like `1` or `1,2`")
                    continue
                }
                let validRange = 1...detected.count
                guard indices.allSatisfy({ validRange.contains($0) }) else {
                    print("  → indices must be in 1...\(detected.count)")
                    continue
                }
                let uuids = indices.map { detected[$0 - 1].uuid }
                if uuids.count == detected.count { return .all }
                return .custom(uuids: uuids)
            }
        }
    }

    /// Picks a sensible default for the display prompt: `all` for fresh
    /// installs, the existing serialized form when re-running the wizard,
    /// rewritten as comma-separated indices when those existing UUIDs map
    /// onto the currently-detected display set.
    private func displayDefault(
        for existing: UserConfig.DisplayMode?,
        available: [DisplayInfo]
    ) -> String {
        guard let existing else { return "all" }
        switch existing {
        case .all: return "all"
        case .mainOnly: return "main"
        case .custom(let uuids):
            let indices = uuids.compactMap { uuid in
                available.firstIndex(where: { $0.uuid == uuid }).map { $0 + 1 }
            }
            return indices.isEmpty ? "all" : indices.map(String.init).joined(separator: ",")
        }
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
