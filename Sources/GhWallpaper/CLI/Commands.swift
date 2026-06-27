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
            #if os(macOS)
            // `gh-wallpaper` with no args → wizard
            return await runWizard()
            #else
            // Linux has no interactive setup wizard; the systemd-driven
            // install.sh writes config directly. Show help instead.
            return printHelp()
            #endif
        }
        switch first {
        case "--help", "-h", "help":     return printHelp()
        case "--version", "-V", "version": return runVersion()
        case "render":                   return await runRender(args: Array(args.dropFirst()))
        case "rotate":                   return await runRotate(args: Array(args.dropFirst()))
        case "theme":                    return await runTheme(args: Array(args.dropFirst()))
        case "themes":                   return await runThemes(args: Array(args.dropFirst()))
        case "diagnose":                 return runDiagnose()
        #if os(macOS)
        case "--daemon", "daemon":       return await runDaemon()
        case "refresh":                  return await runRefresh()
        case "pause":                    return runPause()
        case "start":                    return runStart()
        case "displays":                 return runDisplays()
        case "uninstall":                return runUninstall()
        case "edit":
            // isEditorInvocation routes this to dispatchEditorSync on macOS;
            // reaching here means a routing bug.
            FileHandle.standardError.write(Data(
                "internal error: 'edit' should have been routed to the editor\n".utf8
            ))
            return 1
        case "init":
            FileHandle.standardError.write(Data(
                "`init` is Linux-only. On macOS, run `gh-wallpaper` (no args) for the interactive wizard.\n".utf8
            ))
            return 1
        #else
        case "--daemon", "daemon", "refresh", "pause", "start", "displays", "uninstall":
            FileHandle.standardError.write(Data(
                "`\(first)` is macOS-only. On Linux, control the systemd unit directly:\n  systemctl --user enable --now gh-wallpaper.timer\n  systemctl --user start gh-wallpaper.service\nSee contrib/linux/README.md.\n".utf8
            ))
            return 1
        case "edit":
            FileHandle.standardError.write(Data(
                "the visual theme editor is macOS-only. To customize a theme on Linux:\n  gh-wallpaper themes export github-dark > my-theme.json\n  # edit my-theme.json (change \"id\", adjust colors)\n  gh-wallpaper themes import < my-theme.json\n  gh-wallpaper theme my-theme\n".utf8
            ))
            return 1
        case "init":                     return await runLinuxInit(args: Array(args.dropFirst()))
        #endif
        default:
            // "dark" and "light" are aliases for the hyphen-prefixed github-* themes.
            let themeAliases: [String: String] = ["dark": "github-dark", "light": "github-light"]
            let themeID = themeAliases[first] ?? first
            if builtinThemeIDs.contains(themeID) || CustomThemes.shared.find(id: themeID) != nil {
                return await runTheme(args: [themeID])
            }
            FileHandle.standardError.write(Data(
                "unknown command: \(first)\nRun `gh-wallpaper --help` for usage.\n".utf8
            ))
            return 1
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
    /// Always returns false on non-macOS — there is no editor on Linux.
    public static func isEditorInvocation(_ argv: [String]) -> Bool {
        #if !os(macOS)
        return false
        #else
        let stripped = argv.dropFirst().filter { $0 != "-v" && $0 != "--verbose" }
        guard let first = stripped.first else { return false }
        let rest = stripped.dropFirst()
        switch first {
        case "edit":   return true
        case "theme":  return rest.contains("--edit")
        case "themes": return rest.first == "new"
        default:       return false
        }
        #endif
    }

    /// Synchronous dispatch for editor invocations. Caller must already be
    /// on the OS main thread (the `@main` entrypoint guarantees this).
    public static func dispatchEditorSync(_ argv: [String]) -> Int32 {
        #if !os(macOS)
        FileHandle.standardError.write(Data(
            "the visual theme editor is macOS-only. On Linux, place a JSON file at \(Paths.customThemesDir.path) — see contrib/linux/README.md for the schema.\n".utf8
        ))
        return 1
        #else
        var args = Array(argv.dropFirst())
        if let idx = args.firstIndex(where: { $0 == "-v" || $0 == "--verbose" }) {
            args.remove(at: idx)
            Logger.shared.consoleMirror = .debug
        }
        guard let first = args.first else { return 1 }
        let rest = Array(args.dropFirst())
        switch first {
        case "edit":
            return runEditCurrentThemeSync()
        case "theme":
            return runThemeEditSync(args: rest)
        case "themes":
            // isEditorInvocation already gated this on rest.first == "new".
            return runThemesNewSync(args: Array(rest.dropFirst()))
        default:
            return 1
        }
        #endif
    }

    // MARK: - Subcommands

    #if os(macOS)
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
    #endif

    private static func runRender(args: [String]) async -> Int32 {
        var username: String? = nil
        var themeID: String? = nil
        var canvasArg: String? = nil
        var outputArg: String? = nil
        var headlineTextArg: String? = nil
        var headlineFontArg: String? = nil
        var headlineSizeArg: String? = nil
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--user":           username       = args[safe: i + 1]; i += 2
            case "--theme":          themeID        = args[safe: i + 1]; i += 2
            case "--canvas":         canvasArg      = args[safe: i + 1]; i += 2
            case "--output":         outputArg      = args[safe: i + 1]; i += 2
            case "--headline-text":  headlineTextArg = args[safe: i + 1]; i += 2
            case "--headline-font":  headlineFontArg = args[safe: i + 1]; i += 2
            case "--headline-size":  headlineSizeArg = args[safe: i + 1]; i += 2
            default: i += 1
            }
        }
        let config = try? ConfigStore.read()
        guard let user = username ?? config?.username else {
            FileHandle.standardError.write(Data(
                "no GitHub username — pass `--user <name>` to render.\n".utf8
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

        // Build headline options: start from config, apply any per-render overrides.
        var headline = config?.resolvedHeadlineOptions() ?? .default
        if let t = headlineTextArg { headline.text = t.isEmpty ? nil : t }
        if let f = headlineFontArg {
            if let parsed = HeadlineFont.parse(f) {
                headline.font = parsed
            } else {
                FileHandle.standardError.write(Data(
                    "invalid --headline-font: \(f) (use 'pixel-glyphs' or 'system:<family>')\n".utf8
                ))
                return 1
            }
        }
        if let s = headlineSizeArg {
            guard let d = Double(s), d > 0 else {
                FileHandle.standardError.write(Data(
                    "invalid --headline-size: \(s) (expected a positive number, e.g. 1.2)\n".utf8
                ))
                return 1
            }
            headline.sizeScale = d
        }

        // Explicit-canvas path: works on both platforms. `--canvas WxH
        // --output PATH` skips display enumeration and writes one PNG.
        if canvasArg != nil || outputArg != nil {
            return await renderToCanvas(
                username: user, theme: theme, headline: headline,
                canvasArg: canvasArg, outputArg: outputArg
            )
        }

        #if os(macOS)
        return await renderOneShot(username: user, theme: theme, setWallpaper: false, headline: headline)
        #else
        FileHandle.standardError.write(Data(
            "on Linux, pass --canvas WxH --output PATH (auto-detection lands in a follow-up release).\nExample: gh-wallpaper render --user \(user) --canvas 2560x1440 --output ~/.cache/gh-wallpaper/wallpaper.png\n".utf8
        ))
        return 1
        #endif
    }

    /// Cross-platform single-canvas render: parse `--canvas WxH`, write one
    /// PNG to `--output PATH`. No display enumeration, no wallpaper-set.
    /// On Linux this is the only render path; on macOS it's an override that
    /// skips multi-display logic when the user wants a specific PNG written.
    private static func renderToCanvas(
        username: String,
        theme: Theme,
        headline: HeadlineOptions = .default,
        canvasArg: String?,
        outputArg: String?
    ) async -> Int32 {
        guard let canvasArg else {
            FileHandle.standardError.write(Data(
                "--output requires --canvas WxH (e.g. --canvas 2560x1440)\n".utf8
            ))
            return 1
        }
        guard let (width, height) = parseCanvas(canvasArg) else {
            FileHandle.standardError.write(Data(
                "invalid --canvas: \(canvasArg) (expected WxH, e.g. 2560x1440)\n".utf8
            ))
            return 1
        }
        let outputPath: String
        if let outputArg {
            outputPath = outputArg
        } else {
            _ = try? Paths.ensureSupportDir()
            outputPath = Paths.cacheDir.appendingPathComponent("wallpaper.png").path
        }

        do {
            let scraper = Scraper()
            print("→ fetching contributions for @\(username)…")
            let calendar = try await scraper.fetch(username: username)
            print("→ parsed \(calendar.days.count) days")

            let rasterizer = try Rasterizer()
            let builder = SVGBuilder()
            let canvas = SVGBuilder.Canvas(widthPx: width, heightPx: height)
            let svg = builder.build(calendar: calendar, theme: theme, canvas: canvas, headline: headline)

            let outURL = URL(fileURLWithPath: outputPath)
            // Ensure parent directory exists; users may pass a path under a
            // not-yet-created directory (especially on Linux's XDG_CACHE_HOME).
            try FileManager.default.createDirectory(
                at: outURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try rasterizer.rasterize(svg: svg, toPNG: outURL, widthPx: width, heightPx: height)
            print(outURL.path)
            return 0
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            return 1
        }
    }

    /// Parse `WxH` into `(width, height)`. Returns nil on malformed input or
    /// out-of-range dimensions (each side must be 1..8192).
    private static func parseCanvas(_ s: String) -> (Int, Int)? {
        let parts = s.split(separator: "x", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let w = Int(parts[0]), let h = Int(parts[1]),
              w > 0, h > 0, w <= 8192, h <= 8192 else {
            return nil
        }
        return (w, h)
    }

    #if os(macOS)
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
            setWallpaper: true,
            headline: config.resolvedHeadlineOptions()
        )
    }
    #endif

    // MARK: - Rotate

    private static func runRotate(args: [String]) async -> Int32 {
        guard let verb = args.first else { return printRotateStatus() }
        let rest = Array(args.dropFirst())
        switch verb {
        case "theme":    return await runRotateTheme(args: rest)
        case "headline": return await runRotateHeadline(args: rest)
        default:
            FileHandle.standardError.write(Data(
                "unknown rotate verb: \(verb)\nusage: gh-wallpaper rotate [theme|headline] [daily|off] [...]\n".utf8
            ))
            return 1
        }
    }

    private static func printRotateStatus() -> Int32 {
        guard let config = try? ConfigStore.read() else {
            FileHandle.standardError.write(Data("no config; run `gh-wallpaper` to set up\n".utf8))
            return 1
        }
        let rot = config.rotationConfig
        let state = RotationStateStore.read()

        print("Theme rotation: \(rot.themeMode.rawValue)")
        if !rot.themePool.isEmpty {
            print("  pool: \(rot.themePool.joined(separator: ", "))")
        } else if rot.themeMode == .daily {
            print("  pool: (all built-in themes)")
        }
        if let picked = state.pickedThemeID, let date = state.lastThemePickDate {
            print("  today's pick (\(date)): \(picked)")
        }

        print("Headline rotation: \(rot.headlineMode.rawValue)")
        if !rot.headlinePool.isEmpty {
            print("  pool: \(rot.headlinePool.map { "'\($0)'" }.joined(separator: ", "))")
        }
        if let picked = state.pickedHeadlineText, let date = state.lastHeadlinePickDate {
            print("  today's pick (\(date)): \(picked)")
        }
        return 0
    }

    private static func runRotateTheme(args: [String]) async -> Int32 {
        guard let mode = args.first else {
            FileHandle.standardError.write(Data(
                "usage: gh-wallpaper rotate theme [daily|off] [<id1> <id2> ...]\n".utf8
            ))
            return 1
        }
        switch mode {
        case "off":
            return await updateRotation { config in
                config.rotationConfig.themeMode = .off
            }
        case "daily":
            let pool = Array(args.dropFirst())
            var validPool: [String] = []
            for id in pool {
                if id == "auto" {
                    print("note: 'auto' is excluded from rotation pools (picks must be stable for the day)")
                } else if Themes.byId(id) == nil {
                    FileHandle.standardError.write(Data("warning: unknown theme id '\(id)'; skipping\n".utf8))
                } else {
                    validPool.append(id)
                }
            }
            if !pool.isEmpty && validPool.isEmpty {
                FileHandle.standardError.write(Data("error: no valid themes in pool after filtering\n".utf8))
                return 1
            }
            return await updateRotation { config in
                config.rotationConfig.themeMode = .daily
                config.rotationConfig.themePool = validPool
            }
        default:
            FileHandle.standardError.write(Data(
                "unknown mode: \(mode) (expected 'daily' or 'off')\n".utf8
            ))
            return 1
        }
    }

    private static func runRotateHeadline(args: [String]) async -> Int32 {
        guard let mode = args.first else {
            FileHandle.standardError.write(Data(
                "usage: gh-wallpaper rotate headline [daily|off] [<text1> <text2> ...]\n".utf8
            ))
            return 1
        }
        switch mode {
        case "off":
            return await updateRotation { config in
                config.rotationConfig.headlineMode = .off
            }
        case "daily":
            let pool = Array(args.dropFirst())
            if pool.isEmpty {
                FileHandle.standardError.write(Data(
                    "daily headline rotation requires at least one text entry\nusage: gh-wallpaper rotate headline daily \"TEXT 1\" \"TEXT 2\" ...\n".utf8
                ))
                return 1
            }
            for text in pool where text.contains("|") {
                FileHandle.standardError.write(Data(
                    "headline pool entries cannot contain '|' (it's used as delimiter in config)\n".utf8
                ))
                return 1
            }
            return await updateRotation { config in
                config.rotationConfig.headlineMode = .daily
                config.rotationConfig.headlinePool = pool
            }
        default:
            FileHandle.standardError.write(Data(
                "unknown mode: \(mode) (expected 'daily' or 'off')\n".utf8
            ))
            return 1
        }
    }

    private static func updateRotation(_ mutate: (inout UserConfig) -> Void) async -> Int32 {
        guard var config = try? ConfigStore.read() else {
            FileHandle.standardError.write(Data("no config; run `gh-wallpaper` to set up\n".utf8))
            return 1
        }
        mutate(&config)
        do {
            try ConfigStore.write(config)
            RotationStateStore.clear()  // force re-pick on next tick with new pool
            #if os(macOS)
            print("→ rotation updated; refreshing wallpaper…")
            return await runRefreshOnce(config: config)
            #else
            print("→ rotation updated. The systemd timer will pick it up on next firing.")
            return 0
            #endif
        } catch {
            FileHandle.standardError.write(Data("could not save config: \(error)\n".utf8))
            return 1
        }
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
            return runThemeStatus()
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
            #if os(macOS)
            print("→ theme set to \(id); refreshing wallpaper…")
            return await runRefreshOnce(config: config)
            #else
            print("→ theme set to \(id). The systemd timer will pick it up on next firing.")
            print("  Apply now: `systemctl --user start gh-wallpaper.service`")
            return 0
            #endif
        } catch {
            FileHandle.standardError.write(Data("could not save config: \(error)\n".utf8))
            return 1
        }
    }

    // MARK: - Sync editor handlers (called from dispatchEditorSync)
    #if os(macOS)

    /// `gh-wallpaper edit` — open the visual editor seeded from the currently
    /// active theme. "auto" is resolved to the concrete light/dark theme that
    /// matches the current system appearance. Built-in themes require a rename
    /// on save (fork); custom themes edit in place.
    private static func runEditCurrentThemeSync() -> Int32 {
        let config = try? ConfigStore.read()
        let themeID = config?.themeID ?? "github-dark"
        // Themes.byId handles "auto" via autoResolved(), so we always get a
        // concrete seed regardless of the stored value.
        let seed = Themes.byId(themeID) ?? Themes.githubDark
        let resolvedID = seed.id  // e.g. "github-dark" even if themeID was "auto"
        let isBuiltin = builtinThemeIDs.contains(resolvedID)
        return runEditorSync(seed: seed, initialName: resolvedID, mustRename: isBuiltin)
    }

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
    #endif  // os(macOS) — editor handlers

    /// `themes` (no verb) lists built-in + custom themes.
    /// `themes <verb>` dispatches to CRUD actions: delete / export / import.
    /// (`themes new` is handled by `dispatchEditorSync` on macOS — see
    /// `runTheme` for why. On Linux, "new" lands here and we point users at
    /// the export-edit-reimport JSON workflow.)
    private static func runThemes(args: [String]) async -> Int32 {
        guard let verb = args.first else { return runThemesList() }
        let rest = Array(args.dropFirst())
        switch verb {
        case "delete":  return runThemesDelete(args: rest)
        case "export":  return runThemesExport(args: rest)
        case "import":  return runThemesImport()
        case "new":
            #if os(macOS)
            // On macOS this is normally caught by isEditorInvocation upstream.
            FileHandle.standardError.write(Data(
                "internal: themes new should have been routed to the editor\n".utf8
            ))
            return 1
            #else
            FileHandle.standardError.write(Data(
                "the visual editor is macOS-only. Create a custom theme on Linux by exporting + editing JSON:\n  gh-wallpaper themes export github-dark > \(Paths.customThemesDir.path)/my-theme.json\n  # edit my-theme.json (change \"id\", tweak colors)\n  gh-wallpaper themes\nSee contrib/linux/README.md for the schema.\n".utf8
            ))
            return 1
            #endif
        default:
            FileHandle.standardError.write(Data(
                "unknown verb: \(verb)\nusage: gh-wallpaper themes [new|delete|export|import] [...]\n".utf8
            ))
            return 1
        }
    }

    private static func runThemeStatus() -> Int32 {
        let config = try? ConfigStore.read()
        if let current = config?.themeID {
            print("Current theme: \(current)")
            print("")
        }
        return runThemesList()
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

    #if os(macOS)
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
    #endif

    private static func runVersion() -> Int32 {
        print("gh-wallpaper v\(CurrentVersion)")
        let state = StateStore.read()
        if let latest = state.latestAvailableVersion, isNewerVersion(latest, than: CurrentVersion) {
            print("update available: v\(latest) — run `brew upgrade Numbatt/tap/gh-wallpaper`")
        }
        // whatsNew(since: nil) always returns the changelog for CurrentVersion.
        if let notes = whatsNew(since: nil) {
            print("\nWhat's new in v\(CurrentVersion):")
            print(notes)
        }
        return 0
    }

    private static func runDiagnose() -> Int32 {
        let config = try? ConfigStore.read()
        let state = StateStore.read()
        let resvgPath: String
        do {
            let r = try Rasterizer()
            resvgPath = "ok (\(r.path))"
        } catch {
            resvgPath = "(missing — \(error))"
        }

        print("gh-wallpaper diagnose")
        print("─────────────────────")
        print("version: v\(CurrentVersion)")
        if let latest = state.latestAvailableVersion, isNewerVersion(latest, than: CurrentVersion) {
            print("update:  v\(latest) available — run `brew upgrade Numbatt/tap/gh-wallpaper`")
        } else if state.lastUpdateCheckAt != nil {
            print("update:  up to date")
        }
        #if os(macOS)
        print("platform: macOS")
        #else
        print("platform: Linux")
        let env = ProcessInfo.processInfo.environment
        let distro = readOSReleaseField("PRETTY_NAME") ?? "unknown"
        print("  distro:        \(distro)")
        print("  desktop:       \(env["XDG_CURRENT_DESKTOP"] ?? "(unset)")")
        print("  session type:  \(env["XDG_SESSION_TYPE"] ?? "(unset)")")
        print("  XDG_CONFIG:    \(env["XDG_CONFIG_HOME"] ?? "(default)")")
        print("  XDG_CACHE:     \(env["XDG_CACHE_HOME"] ?? "(default)")")
        print("  XDG_STATE:     \(env["XDG_STATE_HOME"] ?? "(default)")")
        #endif

        print("config: \(ConfigStore.exists() ? Paths.configFile.path : "(not set up)")")
        if let c = config {
            print("  username: \(c.username)")
            print("  theme: \(c.themeID)")
            print("  displays: \(c.displays.serialized)")
        }
        print("paths:")
        print("  config dir:   \(Paths.supportDir.path)")
        print("  cache dir:    \(Paths.cacheDir.path)")
        print("  state dir:    \(Paths.stateDir.path)")
        print("  themes dir:   \(Paths.customThemesDir.path)")
        print("state:")
        if let last = state.lastRefreshAt {
            print("  last refresh: \(ISO8601DateFormatter().string(from: last))")
        } else {
            print("  last refresh: (none)")
        }
        print("  consecutive failures: \(state.consecutiveFailures)")
        if let err = state.lastError { print("  last error: \(err)") }
        print("rasterizer: \(resvgPath)")
        #if os(macOS)
        print("launchd plist: \(FileManager.default.fileExists(atPath: Paths.launchdPlist.path) ? "installed" : "not installed")")
        print("displays: \(DisplayEnumerator.all().count)")
        #else
        print("systemd unit: \(FileManager.default.fileExists(atPath: Paths.systemdUnitPath.path) ? Paths.systemdUnitPath.path : "(not installed)")")
        let dropIn = Paths.systemdUnitPath.deletingLastPathComponent()
            .appendingPathComponent("\(Paths.systemdUnitName).d/override.conf")
        print("drop-in:      \(FileManager.default.fileExists(atPath: dropIn.path) ? dropIn.path : "(none — run `gh-wallpaper init`)")")
        print("(see journalctl --user-unit=gh-wallpaper.service for runtime logs)")
        #endif
        print("log: \(Paths.logFile.path)")
        return 0
    }

    #if !os(macOS)
    /// `gh-wallpaper init` — Linux-only setup. See `LinuxInit.swift`.
    /// Recognized flags: `--no-enable` (skip systemctl, just write the drop-in).
    private static func runLinuxInit(args: [String]) async -> Int32 {
        var noEnable = false
        for arg in args {
            switch arg {
            case "--no-enable": noEnable = true
            case "-h", "--help":
                print("""
                gh-wallpaper init — interactive Linux setup.

                Walks through username / theme / canvas / wallpaper-setter,
                writes a systemd drop-in (~/.config/systemd/user/gh-wallpaper.service.d/override.conf),
                enables the timer, and renders once.

                Options:
                  --no-enable    Write the drop-in but don't run `systemctl enable/start`.
                                 Use in containers, sandboxes, or when scripting.
                """)
                return 0
            default:
                FileHandle.standardError.write(Data("unknown flag: \(arg)\n".utf8))
                return 2
            }
        }
        return await LinuxInit().run(options: .init(noEnable: noEnable))
    }

    /// Best-effort reader for `/etc/os-release` fields. Returns nil if the
    /// file or key isn't present. Strips surrounding quotes from the value.
    private static func readOSReleaseField(_ key: String) -> String? {
        guard let content = try? String(contentsOfFile: "/etc/os-release", encoding: .utf8) else {
            return nil
        }
        for line in content.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == Substring(key) else { continue }
            var v = String(parts[1])
            if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
                v = String(v.dropFirst().dropLast())
            }
            return v
        }
        return nil
    }
    #endif

    #if os(macOS)
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

    // MARK: - Render helper (macOS multi-display, sets wallpaper)

    private static func renderOneShot(
        username: String,
        theme: Theme,
        displaysMode: UserConfig.DisplayMode = .all,
        setWallpaper: Bool,
        headline: HeadlineOptions = .default
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
                let svg = builder.build(calendar: calendar, theme: theme, canvas: canvas, headline: headline)

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
    #endif  // os(macOS) — runUninstall + renderOneShot + cleanupOldWallpapers

    // MARK: - Help

    private static func printHelp() -> Int32 {
        #if os(macOS)
        print("""
        gh-wallpaper — GitHub contribution heatmap as your desktop wallpaper

        Usage:
          gh-wallpaper                         Run setup wizard (or re-run to reconfigure)
          gh-wallpaper version                 Show current version and what's new
          gh-wallpaper edit                    Open the visual theme editor for your current theme
          gh-wallpaper <theme>                 Switch theme — shorthand for `theme <id>`
                                               dark · light · dracula · midnight · nord · paper
                                               ocean · blossom · tokyo-night · gruvbox-dark
                                               catppuccin-frappe · catppuccin-mocha · auto
          gh-wallpaper theme                   Show current theme + list all available
          gh-wallpaper theme <id>              Apply a theme (built-in or custom)
          gh-wallpaper theme <id> --edit       Open the editor seeded from <id>
                                               Built-ins fork on save (must rename);
                                               customs edit in place.
          gh-wallpaper themes                  List built-in + custom themes
          gh-wallpaper themes new <name>       Create a new custom theme in the editor
          gh-wallpaper themes delete <name>    Remove a custom theme + its image
          gh-wallpaper themes export <name>    Print theme JSON to stdout (works for built-ins)
          gh-wallpaper themes import           Read theme JSON from stdin and save it
          gh-wallpaper refresh                 Force an immediate refresh + set wallpaper
          gh-wallpaper render [--user X]       Render PNG to disk without setting wallpaper
                              [--theme T]
                              [--canvas WxH]   Override display detection
                              [--output PATH]  Write PNG to this path
                              [--headline-text "TEXT"]
                              [--headline-font "system:SF Mono"|"pixel-glyphs"]
                              [--headline-size 1.2]
          gh-wallpaper rotate theme daily [<id1> <id2> ...]
                                               Enable daily random theme rotation
          gh-wallpaper rotate theme off        Disable theme rotation
          gh-wallpaper rotate headline daily "TEXT 1" "TEXT 2" ...
                                               Enable daily random headline rotation
          gh-wallpaper rotate headline off     Disable headline rotation
          gh-wallpaper rotate                  Show current rotation config + today's picks
          gh-wallpaper pause                   Stop the launchd agent
          gh-wallpaper start                   Start the launchd agent
          gh-wallpaper displays                List connected displays
          gh-wallpaper diagnose                Print install state, last refresh, errors
          gh-wallpaper uninstall               Full clean: launchd + config + restore prior wallpaper
          gh-wallpaper --daemon                Run the daemon (used by launchd)

        Pass -v / --verbose to mirror debug logs to stderr.

        Privacy: scrapes the public profile only. No PAT, no auth, no telemetry.
        """)
        #else
        print("""
        gh-wallpaper — GitHub contribution heatmap as your desktop wallpaper (Linux beta)

        Usage:
          gh-wallpaper init                     Interactive setup: write systemd drop-in,
                                                pick wallpaper-setter, enable timer, render once
          gh-wallpaper render --user X --canvas WxH --output PATH
                                                Render PNG to PATH at the given canvas size
                                                (e.g. --canvas 2560x1440 --output ~/.cache/gh-wallpaper/wallpaper.png)
                              [--theme T]       Override saved theme for this render only
          gh-wallpaper theme <id>               Set the active theme in config (next render uses it)
          gh-wallpaper themes                   List built-in + custom themes
          gh-wallpaper themes export <id>       Print theme JSON to stdout (works for built-ins)
          gh-wallpaper themes import            Read theme JSON from stdin and save it
          gh-wallpaper themes delete <id>       Remove a custom theme
          gh-wallpaper diagnose                 Print platform info + paths + state for bug reports

        On Linux gh-wallpaper renders to a PNG; a per-DE shell snippet (see
        contrib/linux/examples/) sets it as the wallpaper, and a systemd user
        timer drives the refresh cadence. The visual theme editor and
        long-running event-driven daemon are macOS-only for now.

        Setup:  curl -fsSL https://raw.githubusercontent.com/Numbatt/github-heatmap-wallpaper/main/contrib/linux/install.sh | bash
        Bugs:   https://github.com/Numbatt/github-heatmap-wallpaper/issues

        Pass -v / --verbose to mirror debug logs to stderr.
        """)
        #endif
        return 0
    }
}

// MARK: - Helpers

private extension Array {
    subscript(safe i: Int) -> Element? {
        return indices.contains(i) ? self[i] : nil
    }
}
