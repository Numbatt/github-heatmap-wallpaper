import Foundation

public enum RasterizerError: Error, CustomStringConvertible {
    case resvgMissing
    case resvgFailed(exitCode: Int32, stderr: String)
    case ioError(String)

    public var description: String {
        switch self {
        case .resvgMissing:
            #if os(macOS)
            return "resvg binary not found on PATH. Install with `brew install resvg`."
            #else
            return "resvg binary not found on PATH. Install with one of: " +
                   "`sudo apt install resvg` (Debian/Ubuntu), " +
                   "`sudo dnf install resvg` (Fedora), " +
                   "`sudo pacman -S resvg` (Arch)."
            #endif
        case .resvgFailed(let code, let stderr):
            return "resvg failed (exit \(code)): \(stderr)"
        case .ioError(let m):
            return "IO error: \(m)"
        }
    }
}

/// Shells out to the `resvg` CLI to rasterize an SVG string into a PNG file.
public struct Rasterizer {
    private let resvgPath: String

    /// Absolute path to the resvg binary the rasterizer will invoke.
    /// Exposed so `gh-wallpaper diagnose` can show it in bug reports.
    public var path: String { resvgPath }

    public init(resvgPath: String? = nil) throws {
        if let p = resvgPath { self.resvgPath = p; return }
        // Find resvg on PATH. Platform-specific common install locations are
        // checked first (cheaper than spawning `which`); fall back to PATH lookup.
        #if os(macOS)
        let candidates = ["/opt/homebrew/bin/resvg", "/usr/local/bin/resvg"]
        #else
        let candidates = ["/usr/bin/resvg", "/usr/local/bin/resvg"]
        #endif
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            self.resvgPath = found
        } else if let viaWhich = Self.which("resvg") {
            self.resvgPath = viaWhich
        } else {
            throw RasterizerError.resvgMissing
        }
    }

    public func rasterize(svg: String, toPNG outputURL: URL, widthPx: Int, heightPx: Int) throws {
        // Write SVG to a temp file. resvg can read from stdin (`-`) but the file
        // path approach is robust to large inputs and simpler to debug.
        let svgURL = outputURL.deletingPathExtension().appendingPathExtension("svg")
        do {
            try svg.write(to: svgURL, atomically: true, encoding: .utf8)
        } catch {
            throw RasterizerError.ioError("could not write SVG: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: svgURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resvgPath)
        process.arguments = [
            "--width", String(widthPx),
            "--height", String(heightPx),
            svgURL.path,
            outputURL.path
        ]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()  // discard

        do {
            try process.run()
        } catch {
            throw RasterizerError.ioError("could not launch resvg: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
            throw RasterizerError.resvgFailed(exitCode: process.terminationStatus, stderr: stderrStr)
        }
    }

    private static func which(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["which", name]
        let pipe = Pipe()
        p.standardOutput = pipe
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0,
               let data = try pipe.fileHandleForReading.readToEnd(),
               let str = String(data: data, encoding: .utf8) {
                let path = str.trimmingCharacters(in: .whitespacesAndNewlines)
                return path.isEmpty ? nil : path
            }
        } catch { return nil }
        return nil
    }
}
