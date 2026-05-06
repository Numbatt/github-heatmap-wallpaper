#if os(macOS)
import Foundation

/// Generates and registers the per-user launchd agent that runs `gh-wallpaper --daemon`.
///
/// The plist body is embedded here as the canonical source of truth. The binary
/// path is resolved at install-time from `Bundle.main.executableURL`, so the
/// generated plist always points at the actual binary that performed the install
/// (Homebrew prefix, /usr/local/bin, or a custom location).
///
/// Idempotent by design: `install()` will overwrite an existing plist and
/// re-bootstrap, and any best-effort `bootout` failures are ignored.
public enum LaunchAgent {

    public enum LaunchAgentError: Error, CustomStringConvertible {
        case binaryPathUnresolved
        case writeFailed(URL, Error)
        case bootstrapFailed(Int32)

        public var description: String {
            switch self {
            case .binaryPathUnresolved:
                return "could not resolve the running gh-wallpaper binary path"
            case .writeFailed(let url, let err):
                return "could not write \(url.path): \(err)"
            case .bootstrapFailed(let code):
                return "launchctl bootstrap exited \(code)"
            }
        }
    }

    // MARK: - Public API

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: Paths.launchdPlist.path)
    }

    /// Returns true if `launchctl print gui/<uid>/<label>` exits 0 (agent loaded).
    public static var isLoaded: Bool {
        let result = run("/bin/launchctl", "print", "gui/\(getuid())/\(Paths.launchdLabel)")
        return result == 0
    }

    /// Writes the plist (with the running binary path baked in) and bootstraps
    /// the agent into the user's GUI launchd domain. Idempotent.
    @discardableResult
    public static func install() throws -> Int32 {
        let binaryPath = try resolveBinaryPath()
        let plist = renderPlist(binaryPath: binaryPath)
        let url = Paths.launchdPlist
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try plist.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw LaunchAgentError.writeFailed(url, error)
        }
        // Best-effort unload so bootstrap can re-load with the (possibly updated)
        // plist body. macOS returns assorted non-zero codes when the agent isn't
        // already loaded — all expected, all ignored. The 200ms sleep gives the
        // previous process time to fully exit; without it, bootstrap can race
        // the teardown and return 5 ("input/output error") on Sequoia/Tahoe.
        _ = run("/bin/launchctl", "bootout", "gui/\(getuid())/\(Paths.launchdLabel)")
        Thread.sleep(forTimeInterval: 0.2)

        var status = run("/bin/launchctl", "bootstrap", "gui/\(getuid())", url.path)
        if status == 5 {
            // Known race: bootout-then-bootstrap can return 5 even when the
            // agent isn't holding any resources. One retry after a longer
            // pause clears it in practice. If it still fails but the agent
            // ends up loaded anyway (also possible — bootstrap is occasionally
            // both noisy and successful), treat that as success.
            Thread.sleep(forTimeInterval: 0.8)
            status = run("/bin/launchctl", "bootstrap", "gui/\(getuid())", url.path)
            if status == 0 || isLoaded {
                return 0
            }
        }
        if status != 0 {
            throw LaunchAgentError.bootstrapFailed(status)
        }
        return 0
    }

    /// Stops the agent and removes the plist. Best-effort: never throws.
    public static func uninstall() {
        _ = run("/bin/launchctl", "bootout", "gui/\(getuid())/\(Paths.launchdLabel)")
        try? FileManager.default.removeItem(at: Paths.launchdPlist)
    }

    /// Stops the agent without removing the plist. Returns the launchctl exit code.
    @discardableResult
    public static func pause() -> Int32 {
        run("/bin/launchctl", "bootout", "gui/\(getuid())/\(Paths.launchdLabel)")
    }

    // MARK: - Internals

    /// Picks the binary path to embed in the plist. Prefers
    /// `Bundle.main.executableURL`; falls back to `realpath(argv[0])`.
    private static func resolveBinaryPath() throws -> String {
        if let url = Bundle.main.executableURL {
            return url.path
        }
        let argv0 = CommandLine.arguments.first ?? ""
        if !argv0.isEmpty,
           let resolved = realpath(argv0, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        throw LaunchAgentError.binaryPathUnresolved
    }

    private static func renderPlist(binaryPath: String) -> String {
        // XML-escape the binary path defensively — a path with `&` or `<` would
        // otherwise produce malformed XML. None of the canonical install paths
        // contain such characters today, but the cost is negligible.
        let safe = xmlEscape(binaryPath)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(Paths.launchdLabel)</string>

            <key>ProgramArguments</key>
            <array>
                <string>\(safe)</string>
                <string>--daemon</string>
            </array>

            <key>RunAtLoad</key>
            <true/>

            <key>KeepAlive</key>
            <dict>
                <key>Crashed</key>
                <true/>
                <key>SuccessfulExit</key>
                <false/>
            </dict>

            <key>ThrottleInterval</key>
            <integer>30</integer>

            <key>ProcessType</key>
            <string>Background</string>

            <key>StandardOutPath</key>
            <string>/tmp/gh-wallpaper.stdout.log</string>

            <key>StandardErrorPath</key>
            <string>/tmp/gh-wallpaper.stderr.log</string>
        </dict>
        </plist>

        """
    }

    private static func xmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }

    @discardableResult
    private static func run(_ executable: String, _ args: String...) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        // Silence launchctl's chatter on success; callers inspect the exit code.
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}
#endif
