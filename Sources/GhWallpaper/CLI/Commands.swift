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
        case "themes":                   return await runThemes(args: Array(args.dropFirst()))
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

    // MARK: - Sync editor dispatch
    //
    // The editor (`themes new`, `theme … --edit`) drives `NSApplication.run()`
    // on the main thread. Mixing that with `await MainActor.run { … }` from
    // an async-main Swift Concurrency context starves both `DispatchQueue.main`
    // and MainActor continuations — preview never renders, post-editor
    // wallpaper apply never fires. So the entrypoint detects these
    // invocations up front and runs them on a fully synchronous main thread.

    /// Returns `true` for the two argv shapes that open the SwiftUI editor:
    /// `themes new …` and `theme <id> --edit`. Verbose flags are tolerated.
    public static func isEditorInvocation(_ argv: [String]) -> Bool {
        let stripped = argv.dropFirst().filter { $0 != "-v" && $0 != "--verbose" }
        guard let first = stripped.first else { return false }
        let rest = stripped.dropFirst()
        switch first {
        case "theme":  return rest.contains("--edit")
        case "themes": return rest.first == "new"
        default:       return false
        }
    }

    /// Synchronous dispatch for editor invocations. Caller must already be
    /// on the OS main thread (the `@main` entrypoint guarantees this).
    public static func dispatchEditorSync(_ argv: [String]) -> Int32 {
        var args = Array(argv.dropFirst())
        if let idx = args.firstIndex(where: { $0 == "-v" || $0 == "--verbose" }) {
            args.remove(at: idx)
            Logger.shared.consoleMirror = .debug
        }
        guard let first = args.first else { return 1 }
        let rest = Array(args.dropFirst())
        switch first {
        case "theme":
            return runThemeEditSync(args: rest)
        case "themes":
            // isEditorInvocation already gated this on rest.first == "new".
            return runThemesNewSync(args: Array(rest.dropFirst()))
        default:
            return 1
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
                    "unknown theme: \(themeID) (run `gh-wallpaper themes` to list available themes)\n".utf8
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

    private static let builtinThemeIDs: Set<String> = Set(Themes.builtins.map(\.id) + ["auto"])

    /// `theme <id>` applies a theme. The `--edit` form is dispatched
    /// separately by `dispatchEditorSync` because the editor must run
    /// fully synchronously on the main thread (mixing
    /// `NSApplication.run()` with `await MainActor.run` starves the
    /// SwiftUI preview render and the post-editor wallpaper apply).
    private static func runTheme(args: [String]) async -> Int32 {
        var themeID: String? = nil
        for a in args {
            if themeID == nil { themeID = a; continue }
            FileHandle.standardError.write(Data(
                "unexpected argument: \(a)\nusage: gh-wallpaper theme <id> [--edit]\n".utf8
            ))
            return 1
        }
        guard let id = themeID else {
            FileHandle.standardError.write(Data(
                "usage: gh-wallpaper theme <id> [--edit]  (run `gh-wallpaper themes` to list available themes)\n".utf8
            ))
            return 1
        }

        // Plain apply.
        guard Themes.byId(id) != nil else {
            FileHandle.standardError.write(Data(
                "unknown theme: \(id) (run `gh-wallpaper themes` to list available themes)\n".utf8
            ))
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

    // MARK: - Sync editor handlers (called from dispatchEditorSync)

    private static func runThemeEditSync(args: [String]) -> Int32 {
        var themeID: String? = nil
        for a in args {
            if a == "--edit" { continue }
            if themeID == nil { themeID = a; continue }
            FileHandle.standardError.write(Data(
                "unexpected argument: \(a)\nusage: gh-wallpaper theme <id> [--edit]\n".utf8
            ))
            return 1
        }
        guard let id = themeID else {
            FileHandle.standardError.write(Data(
                "usage: gh-wallpaper theme <id> [--edit]  (run `gh-wallpaper themes` to list available themes)\n".utf8
            ))
            return 1
        }
        // Seed comes from whatever this id resolves to. Built-ins get
        // forked (mustRename); existing customs edit in place.
        guard let seed = Themes.byId(id) else {
            FileHandle.standardError.write(Data(
                "no such theme '\(id)'. Try `gh-wallpaper themes new \(id)` to create one.\n".utf8
            ))
            return 1
        }
        let isBuiltin = builtinThemeIDs.contains(id)
        return runEditorSync(seed: seed, initialName: id, mustRename: isBuiltin)
    }

    private static func runThemesNewSync(args: [String]) -> Int32 {
        var name: String? = nil
        for a in args {
            if name == nil { name = a; continue }
            FileHandle.standardError.write(Data("unexpected argument: \(a)\n".utf8))
            return 1
        }
        guard let n = name, !n.isEmpty else {
            FileHandle.standardError.write(Data(
                "usage: gh-wallpaper themes new <name>\n".utf8
            ))
            return 1
        }
        if builtinThemeIDs.contains(n) {
            FileHandle.standardError.write(Data(
                "'\(n)' is a built-in theme. Pick a different name (e.g. 'my-\(n)') — built-ins are immutable.\n".utf8
            ))
            return 1
        }
        if CustomThemes.shared.find(id: n) != nil {
            FileHandle.standardError.write(Data(
                "theme '\(n)' already exists. Use `gh-wallpaper theme \(n) --edit` to edit it, or `themes delete \(n)` first.\n".utf8
            ))
            return 1
        }

        // Seed: current config theme if any, else github-dark. Users
        // re-seed live from the editor's "Apply defaults from…" menu.
        let seed: Theme
        if let cfg = try? ConfigStore.read() {
            seed = cfg.resolvedTheme()
        } else {
            seed = Themes.githubDark
        }

        return runEditorSync(seed: seed, initialName: n, mustRename: false)
    }

    /// Synchronous twin of the deleted async `runEditor`. Opens the SwiftUI
    /// window via `ThemeEditor.runOnMainThread` (which blocks until close),
    /// then — when the user hit Save & Apply — bridges back into the
    /// existing async `runRefreshOnce` via a semaphore. The bridge is safe
    /// here because we're past `app.run()` and Swift Concurrency is no
    /// longer fighting the AppKit run loop.
    private static func runEditorSync(seed: Theme, initialName: String, mustRename: Bool) -> Int32 {
        let outcome = ThemeEditor.runOnMainThread(seed: seed, themeName: initialName, mustRename: mustRename)
        switch outcome {
        case .cancelled:
            print("(cancelled)")
            return 0
        case .saved(let id, let applyImmediately):
            print("✓ saved theme '\(id)' to \(Paths.customThemesDir.path)")
            if applyImmediately {
                guard var config = try? ConfigStore.read() else {
                    FileHandle.standardError.write(Data(
                        "no config; run `gh-wallpaper` to set up before applying themes.\n".utf8
                    ))
                    return 0  // theme is still saved; just couldn't apply
                }
                config.themeID = id
                do {
                    try ConfigStore.write(config)
                    print("→ applying \(id)…")
                    let frozen = config
                    return runAsyncSync { await runRefreshOnce(config: frozen) }
                } catch {
                    FileHandle.standardError.write(Data("could not save config: \(error)\n".utf8))
                    return 1
                }
            }
            return 0
        }
    }

    /// Run an async operation to completion from a sync context, blocking
    /// the calling thread until it finishes. Used by `runEditorSync` to
    /// reuse the existing async refresh pipeline.
    private static func runAsyncSync(_ op: @escaping @Sendable () async -> Int32) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Task.detached {
            box.value = await op()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    private final class ResultBox: @unchecked Sendable {
        var value: Int32 = 1
    }

    /// `themes` (no verb) lists built-in + custom themes.
    /// `themes <verb>` dispatches to CRUD actions: delete / export / import.
    /// (`themes new` is handled by `dispatchEditorSync` — see `runTheme` for why.)
    private static func runThemes(args: [String]) async -> Int32 {
        guard let verb = args.first else { return runThemesList() }
        let rest = Array(args.dropFirst())
        switch verb {
        case "delete":  return runThemesDelete(args: rest)
        case "export":  return runThemesExport(args: rest)
        case "import":  return runThemesImport()
        default:
            FileHandle.standardError.write(Data(
                "unknown verb: \(verb)\nusage: gh-wallpaper themes [new|delete|export|import] [...]\n".utf8
            ))
            return 1
        }
    }

    private static func runThemesList() -> Int32 {
        print("Built-in themes:")
        for theme in Themes.builtins {
            print("  \(theme.id)")
        }
        print("  auto                (sync with system appearance)")

        let custom = CustomThemes.shared.all()
        if custom.isEmpty {
            print("""

            Custom themes: none.
              Create one with `gh-wallpaper themes new <name>` (visual editor),
              or fork a built-in with `gh-wallpaper theme <id> --edit`.
            """)
        } else {
            print("\nCustom themes (from \(Paths.customThemesDir.path)):")
            for theme in custom {
                print("  \(theme.id)")
            }
            print("\nTip: edit any of these with `gh-wallpaper theme <name> --edit`.")
        }
        return 0
    }

    private static func runThemesDelete(args: [String]) -> Int32 {
        guard let name = args.first else {
            FileHandle.standardError.write(Data(
                "usage: gh-wallpaper themes delete <name>\n".utf8
            ))
            return 1
        }
        if builtinThemeIDs.contains(name) {
            FileHandle.standardError.write(Data(
                "'\(name)' is a built-in theme; built-ins cannot be deleted.\n".utf8
            ))
            return 1
        }
        guard CustomThemes.shared.find(id: name) != nil else {
            FileHandle.standardError.write(Data(
                "no custom theme named '\(name)' (run `gh-wallpaper themes` to list).\n".utf8
            ))
            return 1
        }
        let fm = FileManager.default
        let json = Paths.customThemesDir.appendingPathComponent("\(name).json")
        do {
            try fm.removeItem(at: json)
        } catch {
            FileHandle.standardError.write(Data("could not delete \(json.path): \(error)\n".utf8))
            return 1
        }
        // Best-effort: remove any matching image extension (png/jpg/jpeg).
        for ext in ["png", "jpg", "jpeg"] {
            let img = Paths.customThemesImagesDir.appendingPathComponent("\(name).\(ext)")
            if fm.fileExists(atPath: img.path) {
                try? fm.removeItem(at: img)
            }
        }
        CustomThemes.shared.reload()
        print("✓ deleted theme '\(name)'")
        return 0
    }

    private static func runThemesExport(args: [String]) -> Int32 {
        guard let name = args.first else {
            FileHandle.standardError.write(Data(
                "usage: gh-wallpaper themes export <name>\n".utf8
            ))
            return 1
        }
        guard let theme = Themes.byId(name) else {
            FileHandle.standardError.write(Data(
                "no such theme '\(name)' (run `gh-wallpaper themes` to list).\n".utf8
            ))
            return 1
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(theme)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            return 0
        } catch {
            FileHandle.standardError.write(Data("could not encode theme: \(error)\n".utf8))
            return 1
        }
    }

    private static func runThemesImport() -> Int32 {
        let stdin = FileHandle.standardInput
        let data = stdin.readDataToEndOfFile()
        if data.isEmpty {
            FileHandle.standardError.write(Data(
                "no JSON received on stdin. Pipe a theme: `cat theme.json | gh-wallpaper themes import`\n".utf8
            ))
            return 1
        }
        let decoded: Theme
        do {
            decoded = try JSONDecoder().decode(Theme.self, from: data)
        } catch {
            FileHandle.standardError.write(Data("could not parse JSON: \(error)\n".utf8))
            return 1
        }
        if builtinThemeIDs.contains(decoded.id) {
            FileHandle.standardError.write(Data(
                "id '\(decoded.id)' collides with a built-in. Edit the JSON to use a different id (e.g. 'my-\(decoded.id)') and re-import.\n".utf8
            ))
            return 1
        }
        // Validate without a base directory — relative image paths are
        // rejected at import time since we have no obvious base to resolve
        // them against. Users wanting an image background should put the
        // image at an absolute path or use the editor.
        let validated: Theme
        switch CustomThemes.validate(theme: decoded, baseDirectory: nil) {
        case .success(let t):  validated = t
        case .failure(let e):
            FileHandle.standardError.write(Data("invalid theme: \(e.message)\n".utf8))
            return 1
        }
        do {
            let url = try CustomThemes.shared.save(validated)
            print("✓ imported theme '\(validated.id)' to \(url.path)")
            return 0
        } catch {
            FileHandle.standardError.write(Data("could not save: \(error)\n".utf8))
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
          gh-wallpaper theme <id>              Apply a theme (built-in or custom).
          gh-wallpaper theme <id> --edit       Open the editor seeded from <id>.
                                               Built-ins fork on save (must rename);
                                               customs edit in place.
          gh-wallpaper themes                  List built-in + custom themes
          gh-wallpaper themes new <name>       Create a new custom theme in the editor
                                               (use the "Apply defaults from…" menu to seed
                                               from any existing theme)
          gh-wallpaper themes delete <name>    Remove a custom theme + its image
          gh-wallpaper themes export <name>    Print theme JSON to stdout (works for built-ins)
          gh-wallpaper themes import           Read theme JSON from stdin and save it
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
