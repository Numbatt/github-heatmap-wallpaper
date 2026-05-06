#if !os(macOS)
import Foundation

/// Linux post-install setup: writes a systemd drop-in (`override.conf`) with
/// the user's `GH_USER` / `GH_THEME` / `GH_CANVAS` and the right
/// `ExecStartPost` shim for their desktop, then enables the timer and renders
/// once. The Linux analog of `Wizard` on macOS.
///
/// Re-runnable: pre-fills from the saved `UserConfig` when present.
public struct LinuxInit {
    public init() {}

    public struct Options {
        /// Skip `systemctl --user enable/start` (containers, sandboxes, CI —
        /// wherever there's no user bus). The drop-in still gets written.
        public var noEnable: Bool

        public init(noEnable: Bool = false) {
            self.noEnable = noEnable
        }
    }

    public func run(options: Options = Options()) async -> Int32 {
        let existing = try? ConfigStore.read()
        printBanner()

        // 1. Username
        let username: String = ask(
            prompt: "GitHub username",
            defaultValue: existing?.username,
            validator: { input in input.isEmpty ? "username required" : nil }
        )

        // 2. Theme — same picker as macOS, minus `auto` (no system-appearance
        // signal on Linux to follow).
        let themeID = pickTheme(existing: existing?.themeID)

        // 3. Canvas — try to detect, then prompt with the detected value as
        // the default. Fall back to the unit's own default if everything fails.
        let detectedCanvas = detectCanvas()
        let canvas: String = ask(
            prompt: "Canvas (WxH, e.g. 2560x1440)",
            defaultValue: detectedCanvas ?? "2560x1440",
            validator: validateCanvas
        )

        // 4. Wallpaper-setter shim — auto-pick from $XDG_CURRENT_DESKTOP,
        // confirm with the user, fall through to a manual list on unknown DEs.
        let setter = pickSetter()

        // 5. Persist the saved config. `gh-wallpaper theme <id>` and friends
        // read this file; the systemd drop-in is the source of truth for the
        // *render* call but the saved config keeps the rest of the CLI happy.
        let config = UserConfig(username: username, themeID: themeID, displays: .all)
        do {
            try Paths.ensureSupportDir()
            try ConfigStore.write(config)
            print("✓ saved \(Paths.configFile.path)")
        } catch {
            print("warning: could not save config (\(error)) — continuing")
        }

        // 6. Write the systemd drop-in.
        let dropInDir = Paths.systemdUnitPath.deletingLastPathComponent()
            .appendingPathComponent("\(Paths.systemdUnitName).d")
        let dropInFile = dropInDir.appendingPathComponent("override.conf")
        if FileManager.default.fileExists(atPath: dropInFile.path) {
            if !askYesNo(prompt: "Drop-in already exists at \(dropInFile.path) — overwrite?", defaultYes: true) {
                print("kept existing drop-in. Re-run `gh-wallpaper init` to reconfigure.")
                return 0
            }
        }
        do {
            try FileManager.default.createDirectory(at: dropInDir, withIntermediateDirectories: true)
            try renderDropIn(
                username: username,
                theme: themeID,
                canvas: canvas,
                setter: setter
            ).write(to: dropInFile, atomically: true, encoding: .utf8)
            print("✓ wrote \(dropInFile.path)")
        } catch {
            print("error: could not write drop-in: \(error)")
            return 1
        }

        // Setter post-config reminders (sway, Hyprland) — these need a
        // one-time edit to the user's compositor config that we can't make
        // for them.
        if let reminder = setter.postSetupReminder {
            print("\n\(reminder)\n")
            print("Press Enter once you've added that…", terminator: "")
            _ = readLine()
        }

        // 7. Bring it up.
        if options.noEnable {
            print("\n--no-enable: skipping systemctl. Run these when ready:")
            print("  systemctl --user daemon-reload")
            print("  systemctl --user enable --now gh-wallpaper.timer")
            print("  systemctl --user start gh-wallpaper.service")
            return 0
        }

        print("\n→ systemctl --user daemon-reload")
        let reload = runProcess("systemctl", ["--user", "daemon-reload"])
        if reload.exit != 0 {
            print("warning: daemon-reload failed (\(reload.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))")
            print("If you're in a sandbox or container without a user bus, that's expected.")
            print("Re-run on a real session, or run the three commands above by hand.")
            return 0
        }

        print("→ systemctl --user enable --now gh-wallpaper.timer")
        let enable = runProcess("systemctl", ["--user", "enable", "--now", "gh-wallpaper.timer"])
        if enable.exit != 0 {
            print("warning: enable failed: \(enable.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            return 1
        }

        print("→ systemctl --user start gh-wallpaper.service  (rendering once now)")
        _ = runProcess("systemctl", ["--user", "start", "gh-wallpaper.service"])

        // Tail the journal so any first-render error is visible without the
        // user having to know the journalctl incantation.
        print("\n--- journalctl --user-unit=gh-wallpaper.service -n 20 ---")
        let log = runProcess("journalctl", ["--user-unit=gh-wallpaper.service", "-n", "20", "--no-pager"])
        print(log.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        print("---")

        print("""

        all set. The timer will refresh hourly (with up to 5 min jitter).
        Reconfigure any time:  gh-wallpaper init
        Diagnose:              gh-wallpaper diagnose
        """)
        return 0
    }

    // MARK: - Drop-in rendering

    private func renderDropIn(username: String, theme: String, canvas: String, setter: Setter) -> String {
        // Empty `ExecStartPost=` resets the list before we set ours, so a
        // user's own drop-in won't double up if they re-run init after
        // hand-editing. Same idiom as systemd's docs recommend.
        var lines = [
            "# Written by `gh-wallpaper init`. Re-run to regenerate.",
            "[Service]",
            "Environment=GH_USER=\(username)",
            "Environment=GH_THEME=\(theme)",
            "Environment=GH_CANVAS=\(canvas)",
        ]
        if let exec = setter.execStartPost {
            lines.append("ExecStartPost=")
            lines.append("ExecStartPost=\(exec)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Canvas detection

    /// Cascade: swaymsg → wlr-randr → xrandr. Returns nil if all fail.
    private func detectCanvas() -> String? {
        if let s = canvasFromSwaymsg() { return s }
        if let s = canvasFromWlrRandr() { return s }
        if let s = canvasFromXrandr() { return s }
        return nil
    }

    private func canvasFromSwaymsg() -> String? {
        let r = runProcess("swaymsg", ["-t", "get_outputs", "--raw"])
        guard r.exit == 0,
              let data = r.stdout.data(using: .utf8),
              let outputs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        // Pick the first output that's marked `focused` or `active`, fall
        // back to the first entry. Read the `current_mode`'s width/height.
        let preferred = outputs.first(where: { ($0["focused"] as? Bool) == true })
            ?? outputs.first(where: { ($0["active"] as? Bool) == true })
            ?? outputs.first
        guard let mode = preferred?["current_mode"] as? [String: Any],
              let w = mode["width"] as? Int,
              let h = mode["height"] as? Int else { return nil }
        return "\(w)x\(h)"
    }

    private func canvasFromWlrRandr() -> String? {
        let r = runProcess("wlr-randr", ["--json"])
        guard r.exit == 0,
              let data = r.stdout.data(using: .utf8),
              let outputs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        guard let first = outputs.first,
              let modes = first["modes"] as? [[String: Any]],
              let current = modes.first(where: { ($0["current"] as? Bool) == true }),
              let w = current["width"] as? Int,
              let h = current["height"] as? Int else { return nil }
        return "\(w)x\(h)"
    }

    private func canvasFromXrandr() -> String? {
        let r = runProcess("xrandr", ["--query"])
        guard r.exit == 0 else { return nil }
        // Parse the `Screen 0: minimum … current 2560 x 1440 …` line.
        for line in r.stdout.split(separator: "\n") {
            guard line.contains("current ") else { continue }
            // Extract the two integers after "current ".
            let scanner = Scanner(string: String(line))
            _ = scanner.scanUpToString("current ")
            _ = scanner.scanString("current ")
            guard let w = scanner.scanInt() else { continue }
            _ = scanner.scanString(" x ")
            guard let h = scanner.scanInt() else { continue }
            return "\(w)x\(h)"
        }
        return nil
    }

    private func validateCanvas(_ s: String) -> String? {
        let parts = s.lowercased().split(separator: "x")
        guard parts.count == 2,
              let w = Int(parts[0]), let h = Int(parts[1]),
              w > 0, h > 0, w <= 16384, h <= 16384 else {
            return "expected WxH (e.g. 2560x1440)"
        }
        return nil
    }

    // MARK: - Setter detection

    struct Setter {
        let label: String
        let execStartPost: String?
        let postSetupReminder: String?
    }

    /// Maps `$XDG_CURRENT_DESKTOP` to a setter. Falls back to a numbered
    /// picker on unknown environments. Order matters in the menu —
    /// most-likely-first.
    private func pickSetter() -> Setter {
        let xdg = (ProcessInfo.processInfo.environment["XDG_CURRENT_DESKTOP"] ?? "").lowercased()
        let auto = autoSetter(forXDG: xdg)
        let choices = setterChoices()

        print("\nWallpaper-setter:")
        for (i, s) in choices.enumerated() {
            let star = (s.label == auto?.label) ? "  ← detected" : ""
            print("  \(i + 1)) \(s.label)\(star)")
        }
        print("  \(choices.count + 1)) skip — I'll wire it up myself")

        let defaultIdx: String = {
            if let auto, let idx = choices.firstIndex(where: { $0.label == auto.label }) {
                return "\(idx + 1)"
            }
            return "\(choices.count + 1)"  // skip
        }()

        while true {
            print("Pick a setter [\(defaultIdx)]: ", terminator: "")
            let raw = (readLine() ?? "").trimmingCharacters(in: .whitespaces)
            let input = raw.isEmpty ? defaultIdx : raw
            guard let n = Int(input), (1...(choices.count + 1)).contains(n) else {
                print("  → pick a number 1–\(choices.count + 1)")
                continue
            }
            if n == choices.count + 1 {
                return Setter(label: "skip", execStartPost: nil, postSetupReminder: nil)
            }
            return choices[n - 1]
        }
    }

    private func autoSetter(forXDG xdg: String) -> Setter? {
        let choices = setterChoices()
        // Substring match — `XDG_CURRENT_DESKTOP` can be colon-separated
        // (e.g. "ubuntu:GNOME") and case varies.
        if xdg.contains("gnome") || xdg.contains("cinnamon") || xdg.contains("mate") || xdg.contains("unity") {
            return choices.first(where: { $0.label.hasPrefix("GNOME") })
        }
        if xdg.contains("kde") || xdg.contains("plasma") {
            return choices.first(where: { $0.label.hasPrefix("KDE") })
        }
        if xdg.contains("xfce") {
            return choices.first(where: { $0.label.hasPrefix("XFCE") })
        }
        if xdg.contains("hyprland") {
            return choices.first(where: { $0.label.hasPrefix("Hyprland") })
        }
        if xdg.contains("sway") {
            return choices.first(where: { $0.label.hasPrefix("sway") })
        }
        if xdg.contains("i3") || xdg.contains("bspwm") || xdg.contains("awesome") || xdg.contains("dwm") || xdg.contains("openbox") {
            return choices.first(where: { $0.label.hasPrefix("X11 (feh)") })
        }
        return nil
    }

    private func setterChoices() -> [Setter] {
        let bin = "%h/.local/bin"
        return [
            Setter(
                label: "GNOME / Cinnamon / MATE",
                execStartPost: "\(bin)/set-wallpaper-gnome.sh",
                postSetupReminder: nil
            ),
            Setter(
                label: "KDE Plasma",
                execStartPost: "\(bin)/set-wallpaper-kde.sh",
                postSetupReminder: nil
            ),
            Setter(
                label: "XFCE",
                execStartPost: "\(bin)/set-wallpaper-xfce.sh",
                postSetupReminder: nil
            ),
            Setter(
                label: "X11 (feh) — i3, dwm, bspwm, openbox, awesome",
                execStartPost: "\(bin)/set-wallpaper-feh.sh",
                postSetupReminder: nil
            ),
            Setter(
                label: "sway",
                execStartPost: "\(bin)/set-wallpaper-swaybg.sh",
                postSetupReminder: """
                One-time sway setup: add this line to ~/.config/sway/config:
                    output * bg ~/.cache/gh-wallpaper/wallpaper.png fill
                """
            ),
            Setter(
                label: "Hyprland",
                execStartPost: "hyprctl hyprpaper reload ,%h/.cache/gh-wallpaper/wallpaper.png",
                postSetupReminder: """
                One-time Hyprland setup: add this to ~/.config/hypr/hyprpaper.conf:
                    preload   = ~/.cache/gh-wallpaper/wallpaper.png
                    wallpaper = ,~/.cache/gh-wallpaper/wallpaper.png
                    ipc = on
                """
            ),
        ]
    }

    // MARK: - Theme picker (Linux subset of Wizard's)

    private func pickTheme(existing: String?) -> String {
        let choices: [(id: String, label: String)] = [
            ("github-dark", "github-dark"),
            ("github-light", "github-light"),
            ("tokyo-night", "tokyo-night"),
            ("dracula", "dracula"),
            ("nord", "nord"),
            ("gruvbox-dark", "gruvbox-dark"),
            ("catppuccin-frappe", "catppuccin-frappe"),
            ("catppuccin-mocha", "catppuccin-mocha"),
            ("midnight", "midnight"),
            ("paper", "paper"),
            ("blossom", "blossom"),
            ("ocean", "ocean"),
        ]
        print("\nThemes:")
        for (i, choice) in choices.enumerated() {
            print("  \(i + 1)) \(choice.label)")
        }
        let defaultLabel: String = {
            if let existing, let idx = choices.firstIndex(where: { $0.id == existing }) {
                return "\(idx + 1)"
            }
            return "1"
        }()
        while true {
            print("Theme [\(defaultLabel)]: ", terminator: "")
            let raw = (readLine() ?? "").trimmingCharacters(in: .whitespaces)
            let input = raw.isEmpty ? defaultLabel : raw
            if let n = Int(input), (1...choices.count).contains(n) {
                return choices[n - 1].id
            }
            if Themes.byId(input) != nil { return input }
            let validIDs = choices.map { $0.id }.joined(separator: ", ")
            print("  → pick a number 1–\(choices.count) or one of: \(validIDs)")
        }
    }

    // MARK: - Prompt helpers (mirrors Wizard.swift)

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

    private func printBanner() {
        print("""

        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
         gh-wallpaper init  (Linux beta)
         GitHub contribution heatmap as your desktop wallpaper.
         No tokens, no signup, no telemetry.
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

        """)
    }

    // MARK: - Process helper

    private struct ProcessResult {
        let exit: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs `cmd args…` via `/usr/bin/env` so PATH resolution works. Captures
    /// stdout + stderr; never throws — returns exit -1 if the command can't
    /// be launched at all (missing binary, etc.).
    private func runProcess(_ cmd: String, _ args: [String]) -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [cmd] + args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
            p.waitUntilExit()
            let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
            let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            return ProcessResult(
                exit: p.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        } catch {
            return ProcessResult(exit: -1, stdout: "", stderr: "\(error)")
        }
    }
}
#endif
