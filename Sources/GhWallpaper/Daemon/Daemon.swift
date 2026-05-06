#if os(macOS)
import AppKit
import Foundation

/// Long-running process that owns the refresh loop. Started by launchd via
/// `gh-wallpaper --daemon`.
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

    /// Static runtime knobs. User-facing settings (username, theme, displays)
    /// are not in here — those live in `UserConfig` on disk and are reloaded
    /// every refresh tick so CLI commands like `gh-wallpaper theme paper`
    /// take effect without a daemon restart.
    public struct Config: Sendable {
        public var debounceInterval: TimeInterval     // seconds
        public var backoffSchedule: [TimeInterval]    // seconds, retried in order

        public init(
            debounceInterval: TimeInterval = 30,
            backoffSchedule: [TimeInterval] = [1, 4, 16]
        ) {
            self.debounceInterval = debounceInterval
            self.backoffSchedule = backoffSchedule
        }
    }

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

        self.config = Config()

        if let err = rasterizerSetupError {
            self.logger.error("rasterizer unavailable at startup: \(err)")
        }
    }

    /// Run the daemon forever. Returns only on cancellation.
    public func run() async {
        if let initial = Self.loadUserConfig() {
            logger.info("daemon starting (username=\(initial.username) theme=\(initial.themeID))")
        } else {
            logger.warn("daemon starting without a saved config; will retry each tick")
        }
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
        // 0. Reload the on-disk user config so theme/username/displays changes
        //    propagate without a daemon restart. If the config file is missing
        //    or unreadable, log and skip — the daemon shouldn't pick a default
        //    username, since rendering some other user's heatmap would be
        //    misleading rather than helpful.
        guard let userConfig = Self.loadUserConfig() else {
            logger.error("no usable config at \(Paths.configFile.path); run `gh-wallpaper` to set up. skipping refresh.")
            failureTracker.recordFailure()
            return
        }
        let theme = userConfig.resolvedTheme()

        // 1. Enumerate connected displays, then filter by `displays` mode.
        let allDisplays = DisplayEnumerator.all()
        let displays = userConfig.displays.filter(allDisplays)
        guard !displays.isEmpty else {
            logger.error("no displays detected; skipping refresh")
            failureTracker.recordFailure()
            return
        }

        // 2. Fetch with exponential backoff inside this tick.
        let calendar: ContributionCalendar
        do {
            calendar = try await fetchWithBackoff(username: userConfig.username)
        } catch {
            let count = failureTracker.recordFailure()
            logger.warn("fetch failed (consecutive failures: \(count)): \(error)")
            return
        }
        logger.debug("fetched \(calendar.days.count) days, contentHash=\(calendar.contentHash)")

        // 3. Hash check (combines content + theme + per-display geometry +
        //    system appearance). If nothing changed since last successful run,
        //    we skip render + set entirely.
        let appearance = Self.systemAppearance()
        let hash = combinedRenderHash(
            calendar: calendar,
            theme: theme,
            displays: displays,
            systemAppearance: appearance
        )
        if hash == lastRenderHash {
            logger.info("no change, skip render (hash=\(hash.prefix(12))… displays=\(displays.count))")
            failureTracker.recordSuccess()
            return
        }

        // 4. Per-display render + set. We tolerate per-display failures: try every
        //    display, count overall failure if any display fails, but only update
        //    lastRenderHash if every display succeeded.
        guard let rasterizer = rasterizer else {
            logger.error("rasterizer unavailable; cannot render")
            failureTracker.recordFailure()
            return
        }
        let outputDir: URL
        do {
            outputDir = try Self.outputDirectory()
        } catch {
            logger.error("could not create output directory: \(error)")
            failureTracker.recordFailure()
            return
        }

        var perDisplayFailed = false
        // Timestamp suffix forces NSWorkspace.setDesktopImageURL to treat each
        // render as a new file (macOS caches by path; same path, new content =
        // silent no-op). Old PNGs for this display are cleaned up after success.
        let stamp = String(Int(Date().timeIntervalSince1970 * 1000))
        for display in displays {
            let canvas = SVGBuilder.Canvas(widthPx: display.widthPx, heightPx: display.heightPx)
            let svg = svgBuilder.build(calendar: calendar, theme: theme, canvas: canvas)
            let livePNG = outputDir.appendingPathComponent("wallpaper-\(display.uuid)-\(stamp).png")
            let tempPNG = outputDir.appendingPathComponent("wallpaper-\(display.uuid)-\(stamp).new.png")

            // Rasterize to temp file (atomic promotion preserves last-good on failure).
            do {
                try? FileManager.default.removeItem(at: tempPNG)
                try rasterizer.rasterize(
                    svg: svg, toPNG: tempPNG,
                    widthPx: display.widthPx, heightPx: display.heightPx
                )
            } catch {
                logger.error("rasterize failed for display \(display.uuid): \(error)")
                try? FileManager.default.removeItem(at: tempPNG)
                perDisplayFailed = true
                continue
            }

            // Atomic promote temp -> live.
            do {
                if FileManager.default.fileExists(atPath: livePNG.path) {
                    _ = try FileManager.default.replaceItemAt(livePNG, withItemAt: tempPNG)
                } else {
                    try FileManager.default.moveItem(at: tempPNG, to: livePNG)
                }
            } catch {
                logger.error("could not promote PNG for display \(display.uuid): \(error)")
                try? FileManager.default.removeItem(at: tempPNG)
                perDisplayFailed = true
                continue
            }

            // Set wallpaper on this display.
            do {
                try wallpaperSetter.set(pngURL: livePNG, on: display)
            } catch {
                logger.error("setDesktopImageURL failed for display \(display.uuid): \(error)")
                perDisplayFailed = true
                continue
            }
        }

        if perDisplayFailed {
            failureTracker.recordFailure()
            // Don't update lastRenderHash so next tick retries.
            return
        }

        // Clean up older wallpaper PNGs for these displays so we don't accumulate
        // disk garbage across thousands of refresh ticks.
        cleanupOldWallpapers(in: outputDir, displays: displays, currentStamp: stamp)

        lastRenderHash = hash
        failureTracker.recordSuccess()
        let geom = displays.map { "\($0.widthPx)x\($0.heightPx)" }.joined(separator: ",")
        logger.info("refresh complete (hash=\(hash.prefix(12))… displays=\(displays.count) [\(geom)])")
    }

    /// Deletes `wallpaper-<UUID>-*.png` for each display except the file with
    /// `currentStamp`. Best-effort: errors are ignored (will retry next tick).
    private func cleanupOldWallpapers(in dir: URL, displays: [DisplayInfo], currentStamp: String) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }
        let activeUUIDs = Set(displays.map { $0.uuid })
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix("wallpaper-"), name.hasSuffix(".png") else { continue }
            // Match wallpaper-<UUID>(-<stamp>)?.png — keep current stamp; drop everything else.
            let body = String(name.dropFirst("wallpaper-".count).dropLast(".png".count))
            // Body looks like "<UUID>-<stamp>" or "<UUID>" (legacy) or "<UUID>-<stamp>.new"
            if body.contains("-\(currentStamp)") { continue }
            // Sanity: only delete if it starts with one of our active display UUIDs
            if activeUUIDs.contains(where: { body.hasPrefix($0) }) {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    /// Combines render-hash inputs across all connected displays so a display
    /// reconfiguration (resolution change, monitor plug/unplug) invalidates the
    /// last render and forces a re-render even if contribution data is unchanged.
    private func combinedRenderHash(
        calendar: ContributionCalendar,
        theme: Theme,
        displays: [DisplayInfo],
        systemAppearance: String
    ) -> String {
        var hasher = Hasher()
        hasher.combine(calendar.contentHash)
        hasher.combine(theme.id)
        hasher.combine(systemAppearance)
        // Sort by UUID for stable hashing regardless of NSScreen ordering.
        for d in displays.sorted(by: { $0.uuid < $1.uuid }) {
            hasher.combine(d.uuid)
            hasher.combine(d.widthPx)
            hasher.combine(d.heightPx)
        }
        return String(hasher.finalize(), radix: 16)
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

    /// Reads the on-disk `UserConfig`. Returns nil when the file is missing
    /// or unparseable — callers must handle that explicitly rather than fall
    /// back to a hardcoded username (rendering an arbitrary stranger's
    /// heatmap silently is worse than failing visibly).
    public static func loadUserConfig() -> UserConfig? {
        return try? ConfigStore.read()
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
#endif
