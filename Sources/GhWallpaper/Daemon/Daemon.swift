import AppKit
import Foundation

/// Long-running process that owns the refresh loop. Started with
/// `gh-wallpaper --daemon` (Wave 3 may rename to `gh-wallpaper start`).
///
/// Architecture (SPEC §2, §3, §10, §11):
///
///   timer ─┐
///   wake ──┤
///   netUp ─┼──> AsyncStream<DaemonEvent> ──> debounce(30s) ──> refresh()
///   disp ──┤
///   login ─┘
///
/// Each `refresh()` does: scrape (with backoff) -> hash check -> render ->
/// rasterize per display -> setDesktopImageURL. On failure inside the tick,
/// the on-disk PNG is left untouched (last-good preserved).
public actor Daemon {

    public struct Config: Sendable {
        public var username: String
        public var theme: Theme
        public var debounceInterval: TimeInterval     // seconds
        public var backoffSchedule: [TimeInterval]    // seconds, retried in order

        public init(
            username: String,
            theme: Theme,
            debounceInterval: TimeInterval = 30,
            backoffSchedule: [TimeInterval] = [1, 4, 16]
        ) {
            self.username = username
            self.theme = theme
            self.debounceInterval = debounceInterval
            self.backoffSchedule = backoffSchedule
        }
    }

    public static let configPath: String = {
        let home = NSHomeDirectory()
        return "\(home)/Library/Application Support/gh-wallpaper/config.toml"
    }()

    public static let defaultUsername = "diegorico"

    private let logger: Logger
    private let scraper: Scraper
    private let svgBuilder: SVGBuilder
    private let rasterizer: Rasterizer?
    private let wallpaperSetter: WallpaperSetter
    private let failureTracker: FailureTracker
    private let observers: Observers
    private let timer: AdaptiveTimer
    private var config: Config

    /// Last successful render hash. nil if we haven't rendered yet this run.
    private var lastRenderHash: String?

    public init() {
        self.logger = Logger.shared
        self.scraper = Scraper()
        self.svgBuilder = SVGBuilder()
        // Rasterizer init throws if resvg is missing; treat that as a fatal
        // setup error but capture it so the daemon can still log + exit.
        var rasterizerOpt: Rasterizer? = nil
        var rasterizerSetupError: String? = nil
        do {
            rasterizerOpt = try Rasterizer()
        } catch {
            rasterizerSetupError = "\(error)"
        }
        self.rasterizer = rasterizerOpt
        self.wallpaperSetter = WallpaperSetter()
        self.failureTracker = FailureTracker()
        self.observers = Observers()
        self.timer = AdaptiveTimer()

        let username = Self.loadConfiguredUsername() ?? Self.defaultUsername
        self.config = Config(username: username, theme: Themes.githubDark)

        if let err = rasterizerSetupError {
            self.logger.error("rasterizer unavailable at startup: \(err)")
        }
    }

    /// Run the daemon forever. Returns only on cancellation.
    public func run() async {
        logger.info("daemon starting (username=\(config.username) theme=\(config.theme.id))")
        logger.info(
            "power=\(timer.isOnAC ? "AC" : "battery") network=\(timer.isReachable ? "up" : "down")"
        )

        // Synthetic login event triggers an immediate refresh.
        observers.post(.login)

        // Start the adaptive-timer driver task that posts `.tick` events.
        let timerTask = Task { [weak self] in
            await self?.runTimerLoop()
        }

        await runEventLoop()

        timerTask.cancel()
        logger.info("daemon stopped")
    }

    // MARK: - Timer loop

    private func runTimerLoop() async {
        while !Task.isCancelled {
            let interval = timer.nextTickInterval()
            if interval == .infinity {
                logger.debug("timer paused (network unreachable); waiting on reachability")
            } else {
                logger.debug("timer waiting \(Int(interval))s for next tick")
            }
            await timer.waitForNextTick()
            if Task.isCancelled { break }
            observers.post(.tick)
        }
    }

    // MARK: - Event loop with debounce
    //
    // Implementation note: AsyncStream's iterator isn't safely shareable across
    // tasks, so we can't trivially "race iterator.next() against a deadline".
    // Instead we build a tiny actor-local mailbox: a separate Task drains the
    // iterator and forwards events into a `Continuation`-driven queue. The
    // event-loop body then pulls from that queue with explicit deadline
    // control via `Task.sleep`.

    private func runEventLoop() async {
        // Mailbox: a serial queue that buffers events while the loop is busy.
        let mailbox = EventMailbox()

        // Forwarder Task: copies from observers.events into the mailbox.
        let forwarderTask = Task { [observers] in
            for await event in observers.events {
                if Task.isCancelled { break }
                await mailbox.deposit(event)
            }
        }
        defer { forwarderTask.cancel() }

        // Main loop: wait for first event, debounce, refresh, repeat.
        while !Task.isCancelled {
            // Block until at least one event arrives.
            guard let first = await mailbox.take() else { break }
            var coalesced: [DaemonEvent] = [first]
            logger.debug("event received: \(first.label) (debouncing \(Int(config.debounceInterval))s)")

            // Drain additional events for `debounceInterval`.
            let deadline = Date().addingTimeInterval(config.debounceInterval)
            while true {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { break }
                if let next = await mailbox.takeWithTimeout(seconds: remaining) {
                    coalesced.append(next)
                    logger.debug("event received: \(next.label) (within debounce)")
                } else {
                    break
                }
            }

            logger.info("refresh triggered by [\(coalesced.map(\.label).joined(separator: ","))]")
            await refresh()
        }
    }

    // MARK: - Refresh

    /// One refresh cycle: fetch -> hash -> render -> rasterize -> set wallpaper.
    /// Failures inside the tick (network, parse, render, set) increment the
    /// failure tracker; success resets it. Never overwrites the on-disk PNG
    /// on failure.
    public func refresh() async {
        // 1. Display
        guard let display = DisplayEnumerator.main() else {
            logger.error("no main display detected; skipping refresh")
            failureTracker.recordFailure()
            return
        }

        // 2. Fetch with exponential backoff inside this tick.
        let calendar: ContributionCalendar
        do {
            calendar = try await fetchWithBackoff(username: config.username)
        } catch {
            let count = failureTracker.recordFailure()
            logger.warn("fetch failed (consecutive failures: \(count)): \(error)")
            return
        }
        logger.debug("fetched \(calendar.days.count) days, contentHash=\(calendar.contentHash)")

        // 3. Hash check
        let canvas = SVGBuilder.Canvas(widthPx: display.widthPx, heightPx: display.heightPx)
        let appearance = Self.systemAppearance()
        let hash = renderHash(
            calendar: calendar,
            theme: config.theme,
            canvas: canvas,
            systemAppearance: appearance
        )
        if hash == lastRenderHash {
            logger.info("no change, skip render (hash=\(hash.prefix(12))…)")
            failureTracker.recordSuccess()
            return
        }

        // 4. Render
        guard let rasterizer = rasterizer else {
            logger.error("rasterizer unavailable; cannot render")
            failureTracker.recordFailure()
            return
        }
        let svg = svgBuilder.build(calendar: calendar, theme: config.theme, canvas: canvas)

        // 5. Rasterize to a temp file, then atomically promote to the canonical
        //    path. This is what guarantees "never overwrite on failure": if
        //    rasterize throws, we never touch the live PNG.
        let outputDir: URL
        do {
            outputDir = try Self.outputDirectory()
        } catch {
            logger.error("could not create output directory: \(error)")
            failureTracker.recordFailure()
            return
        }
        let livePNG = outputDir.appendingPathComponent("wallpaper-\(display.uuid).png")
        let tempPNG = outputDir.appendingPathComponent("wallpaper-\(display.uuid).new.png")

        do {
            try? FileManager.default.removeItem(at: tempPNG)
            try rasterizer.rasterize(svg: svg, toPNG: tempPNG, widthPx: display.widthPx, heightPx: display.heightPx)
        } catch {
            logger.error("rasterize failed: \(error)")
            try? FileManager.default.removeItem(at: tempPNG)
            failureTracker.recordFailure()
            return
        }

        // Promote temp -> live atomically.
        do {
            if FileManager.default.fileExists(atPath: livePNG.path) {
                _ = try FileManager.default.replaceItemAt(livePNG, withItemAt: tempPNG)
            } else {
                try FileManager.default.moveItem(at: tempPNG, to: livePNG)
            }
        } catch {
            logger.error("could not promote PNG: \(error)")
            try? FileManager.default.removeItem(at: tempPNG)
            failureTracker.recordFailure()
            return
        }

        // 6. Set wallpaper.
        do {
            try wallpaperSetter.set(pngURL: livePNG, on: display)
        } catch {
            // The render succeeded; only the set failed. We don't roll back
            // the PNG (it's a fresher last-good than what was there before).
            // Count it as a failure so persistent set-failures still surface.
            logger.error("setDesktopImageURL failed: \(error)")
            failureTracker.recordFailure()
            return
        }

        lastRenderHash = hash
        failureTracker.recordSuccess()
        logger.info("refresh complete (hash=\(hash.prefix(12))… display=\(display.widthPx)x\(display.heightPx))")
    }

    private func fetchWithBackoff(username: String) async throws -> ContributionCalendar {
        var attempts = 0
        let schedule = config.backoffSchedule
        while true {
            do {
                return try await scraper.fetch(username: username)
            } catch let error as ScraperError {
                // Hard errors that should not be retried.
                switch error {
                case .userNotFound, .parseError:
                    throw error
                case .httpError, .networkError:
                    if attempts >= schedule.count {
                        throw error
                    }
                    let backoff = schedule[attempts]
                    logger.warn("fetch attempt \(attempts + 1) failed: \(error); backing off \(Int(backoff))s")
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    attempts += 1
                }
            } catch {
                if attempts >= schedule.count { throw error }
                let backoff = schedule[attempts]
                logger.warn("fetch attempt \(attempts + 1) failed: \(error); backing off \(Int(backoff))s")
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                attempts += 1
            }
        }
    }

    // MARK: - Helpers

    public static func outputDirectory() throws -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gh-wallpaper", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Returns "light" | "dark" based on AppleInterfaceStyle global default.
    public static func systemAppearance() -> String {
        let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        return (style?.lowercased() == "dark") ? "dark" : "light"
    }

    /// Reads `username = "..."` out of `~/Library/Application Support/gh-wallpaper/config.toml`
    /// if it exists. Wave 3 replaces this with proper TOML parsing.
    public static func loadConfiguredUsername() -> String? {
        let path = configPath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let contents = String(data: data, encoding: .utf8) else {
            return nil
        }
        for rawLine in contents.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            // Match: username = "value"  (also tolerate single quotes / no quotes)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            if key != "username" { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // Strip surrounding quotes.
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if !value.isEmpty { return value }
        }
        return nil
    }
}

// MARK: - Event mailbox

/// Internal actor-isolated queue used by the daemon's event loop to decouple
/// AsyncStream consumption from debounce-window timing. The forwarder Task
/// drains the AsyncStream into the mailbox; the main loop reads from the
/// mailbox with optional timeouts.
fileprivate actor EventMailbox {
    /// Per-waiter token. Guarantees the underlying continuation resumes
    /// exactly once even when both the depositor and the timeout race.
    fileprivate final class Waiter: @unchecked Sendable {
        let id: UUID = UUID()
        let continuation: CheckedContinuation<DaemonEvent?, Never>
        private let lock = NSLock()
        private var fired: Bool = false

        init(_ continuation: CheckedContinuation<DaemonEvent?, Never>) {
            self.continuation = continuation
        }

        /// Atomically claim the right to resume. Only the first caller to
        /// return true is allowed to call `resume(with:)`.
        func tryClaim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }

        func resume(with event: DaemonEvent?) {
            continuation.resume(returning: event)
        }
    }

    private var buffer: [DaemonEvent] = []
    private var waiters: [Waiter] = []
    private var closed: Bool = false

    func deposit(_ event: DaemonEvent) {
        if closed { return }
        // Hand event to the first un-claimed waiter.
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            if waiter.tryClaim() {
                waiter.resume(with: event)
                return
            }
            // Waiter already claimed by its timeout; drop it and try next.
        }
        buffer.append(event)
    }

    func close() {
        closed = true
        let toResume = waiters
        waiters.removeAll()
        for w in toResume {
            if w.tryClaim() { w.resume(with: nil) }
        }
    }

    /// Block forever until an event arrives or the mailbox is closed.
    func take() async -> DaemonEvent? {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { cont in
            waiters.append(Waiter(cont))
        }
    }

    /// Block up to `seconds` for an event. Returns nil on timeout or close.
    func takeWithTimeout(seconds: TimeInterval) async -> DaemonEvent? {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if closed { return nil }
        if seconds <= 0 { return nil }

        let nanos = UInt64(seconds * 1_000_000_000)
        return await withCheckedContinuation { (cont: CheckedContinuation<DaemonEvent?, Never>) in
            let waiter = Waiter(cont)
            waiters.append(waiter)
            // Timeout task: claims and resumes with nil if the depositor
            // hasn't already won.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: nanos)
                guard let self else { return }
                await self.expire(waiterID: waiter.id)
            }
        }
    }

    private func expire(waiterID: UUID) {
        // Find and remove the waiter (it may already be gone because the
        // depositor won).
        if let idx = waiters.firstIndex(where: { $0.id == waiterID }) {
            let waiter = waiters.remove(at: idx)
            if waiter.tryClaim() {
                waiter.resume(with: nil)
            }
        }
    }
}
