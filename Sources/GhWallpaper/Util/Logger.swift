import Foundation

/// Severity levels for log lines. Listed in increasing severity.
public enum LogLevel: Int, Sendable, Comparable {
    case debug = 0
    case info  = 1
    case warn  = 2
    case error = 3

    public var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info:  return "INFO "
        case .warn:  return "WARN "
        case .error: return "ERROR"
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

/// Rotating file logger writing to ~/Library/Logs/gh-wallpaper/agent.log.
///
/// Rotation policy: when the active log reaches 1 MB, it is renamed to
/// `agent.log.1` (older `agent.log.N` shift up to `agent.log.N+1`), and the
/// last file (>= keepCount) is dropped. We keep the latest 3 archived files
/// in addition to the live one.
///
/// Thread-safe: a single serial dispatch queue serialises all writes.
public final class Logger: @unchecked Sendable {

    /// Process-wide default. Tests can construct their own instance pointing
    /// at a temp directory.
    public static let shared: Logger = {
        let dir = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/gh-wallpaper", isDirectory: true)
        return Logger(directory: dir)
    }()

    public let directory: URL
    public let logFileName: String
    public let maxBytes: Int
    public let keepCount: Int
    public var minLevel: LogLevel
    /// When non-nil, log lines at >= this level are also written to stderr.
    /// CLI dispatch sets this to `.debug` when `-v`/`--verbose` is passed.
    public var consoleMirror: LogLevel?

    private let queue = DispatchQueue(label: "dev.numbatt.gh-wallpaper.logger")
    private var handle: FileHandle?
    private var bytesWritten: UInt64 = 0
    private let isoFormatter: ISO8601DateFormatter

    public init(
        directory: URL,
        logFileName: String = "agent.log",
        maxBytes: Int = 1_000_000,    // 1 MB
        keepCount: Int = 3,
        minLevel: LogLevel = .debug,
        consoleMirror: LogLevel? = nil
    ) {
        self.directory = directory
        self.logFileName = logFileName
        self.maxBytes = maxBytes
        self.keepCount = keepCount
        self.minLevel = minLevel
        self.consoleMirror = consoleMirror
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = f
    }

    deinit {
        try? handle?.close()
    }

    public var logFileURL: URL {
        return directory.appendingPathComponent(logFileName)
    }

    public func debug(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        log(.debug, message(), file: file, line: line)
    }

    public func info(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        log(.info, message(), file: file, line: line)
    }

    public func warn(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        log(.warn, message(), file: file, line: line)
    }

    public func error(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        log(.error, message(), file: file, line: line)
    }

    public func log(_ level: LogLevel, _ message: String, file: String = #fileID, line: Int = #line) {
        guard level >= minLevel else { return }
        let timestamp = isoFormatter.string(from: Date())
        let lineStr = "\(timestamp) [\(level.label)] \(message)\n"
        guard let data = lineStr.data(using: .utf8) else { return }
        if let mirror = consoleMirror, level >= mirror {
            FileHandle.standardError.write(data)
        }
        queue.async { [weak self] in
            self?.write(data)
        }
    }

    /// Synchronously flush pending writes. Useful for tests + diagnostics.
    public func flush() {
        queue.sync {
            try? self.handle?.synchronize()
        }
    }

    // MARK: - Internal

    private func ensureHandle() throws -> FileHandle {
        if let h = handle { return h }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = logFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            bytesWritten = 0
        } else {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            bytesWritten = (attrs?[.size] as? UInt64) ?? 0
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        handle = h
        return h
    }

    private func write(_ data: Data) {
        do {
            let h = try ensureHandle()
            try h.write(contentsOf: data)
            bytesWritten &+= UInt64(data.count)
            if bytesWritten >= UInt64(maxBytes) {
                rotate()
            }
        } catch {
            // Best-effort: log to stderr if the file write itself fails.
            // We deliberately avoid throwing; logging must never crash the daemon.
            FileHandle.standardError.write(Data("logger write failed: \(error)\n".utf8))
        }
    }

    private func rotate() {
        do {
            try handle?.close()
        } catch {
            // ignore
        }
        handle = nil
        let fm = FileManager.default
        let base = logFileURL

        // Drop the oldest archive if it would exceed keepCount.
        let oldest = directory.appendingPathComponent("\(logFileName).\(keepCount)")
        if fm.fileExists(atPath: oldest.path) {
            try? fm.removeItem(at: oldest)
        }
        // Shift agent.log.(N) -> agent.log.(N+1) for N from keepCount-1 down to 1.
        if keepCount >= 2 {
            for i in stride(from: keepCount - 1, through: 1, by: -1) {
                let src = directory.appendingPathComponent("\(logFileName).\(i)")
                let dst = directory.appendingPathComponent("\(logFileName).\(i + 1)")
                if fm.fileExists(atPath: src.path) {
                    try? fm.moveItem(at: src, to: dst)
                }
            }
        }
        // Move active to .1.
        if fm.fileExists(atPath: base.path) {
            let dst = directory.appendingPathComponent("\(logFileName).1")
            try? fm.moveItem(at: base, to: dst)
        }
        bytesWritten = 0
    }
}
