import Foundation
import IOKit.ps
import Network

/// Adaptive polling cadence per SPEC §3.
///
/// - On AC + network reachable: 120 seconds
/// - On battery + network reachable: 5 minutes
/// - Network unreachable: paused (returns .infinity until network returns)
///
/// Power state is read via IOPSCopyPowerSourcesInfo on each tick (cheap, no
/// observer overhead). Network reachability is tracked by an internal
/// NWPathMonitor so `waitForNextTick` can wake immediately when the path
/// transitions back to `satisfied`.
public final class AdaptiveTimer: @unchecked Sendable {

    public static let acInterval: TimeInterval = 120
    public static let batteryInterval: TimeInterval = 5 * 60

    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "dev.numbatt.gh-wallpaper.adaptive-timer.monitor")
    private let stateQueue = DispatchQueue(label: "dev.numbatt.gh-wallpaper.adaptive-timer.state")
    private var _isReachable: Bool = true
    private var receivedFirstPathUpdate: Bool = false
    private var pendingWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {
        self.monitor = NWPathMonitor()
        self.monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        self.monitor.start(queue: monitorQueue)
    }

    deinit {
        monitor.cancel()
        // Unblock any waiters so we don't leak Tasks.
        let waiters: [CheckedContinuation<Void, Never>] = stateQueue.sync {
            let w = pendingWaiters
            pendingWaiters = []
            return w
        }
        for w in waiters { w.resume() }
    }

    /// Whether the network path is currently satisfied.
    public var isReachable: Bool {
        return stateQueue.sync { _isReachable }
    }

    /// Whether the machine is on AC power right now.
    public var isOnAC: Bool {
        return AdaptiveTimer.readIsOnAC()
    }

    /// The interval the *next* tick will wait, given current power + network state.
    /// Returns `.infinity` when network is unreachable (paused).
    public func nextTickInterval() -> TimeInterval {
        if !isReachable { return .infinity }
        return isOnAC ? AdaptiveTimer.acInterval : AdaptiveTimer.batteryInterval
    }

    /// Suspend until either:
    ///   - the configured interval elapses (AC: 120s, battery: 5min)
    ///   - the network transitions from unreachable -> reachable
    ///
    /// When called while the network is unreachable, this blocks indefinitely
    /// (well, until reachable). Cancellable.
    public func waitForNextTick() async {
        // If unreachable, park until network returns.
        if !isReachable {
            await waitForReachable()
            // Once reachable we treat the resume itself as the tick. The
            // daemon's main loop will fire a refresh on the .networkUp event;
            // returning here lets the next tick interval start from now.
            return
        }
        let interval = isOnAC ? AdaptiveTimer.acInterval : AdaptiveTimer.batteryInterval
        let nanos = UInt64(interval * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
    }

    // MARK: - Network state

    private func handlePathUpdate(_ path: NWPath) {
        let nowReachable = (path.status == .satisfied)
        let toResume: [CheckedContinuation<Void, Never>] = stateQueue.sync {
            // The first callback is the initial state, not a transition.
            if !receivedFirstPathUpdate {
                receivedFirstPathUpdate = true
                _isReachable = nowReachable
                return []
            }
            let was = _isReachable
            _isReachable = nowReachable
            if !was && nowReachable {
                // Wake all waiters parked on reachability.
                let w = pendingWaiters
                pendingWaiters = []
                return w
            }
            return []
        }
        for cont in toResume { cont.resume() }
    }

    private func waitForReachable() async {
        // Fast path: already reachable.
        if isReachable { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let parked: Bool = stateQueue.sync {
                if _isReachable { return false }
                pendingWaiters.append(cont)
                return true
            }
            if !parked { cont.resume() }
        }
    }

    // MARK: - Power state

    /// Returns true if the system is currently drawing from any AC source.
    /// Falls back to `true` (treat as plugged in) on read failure so we don't
    /// silently slow down to battery cadence on a desktop Mac with no battery.
    public static func readIsOnAC() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return true
        }
        guard let sourcesArr = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return true
        }
        if sourcesArr.isEmpty {
            // No power sources known means a desktop with mains power.
            return true
        }
        for src in sourcesArr {
            guard let descDict = IOPSGetPowerSourceDescription(snapshot, src)?
                .takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if let state = descDict[kIOPSPowerSourceStateKey] as? String,
               state == kIOPSACPowerValue {
                return true
            }
        }
        return false
    }
}
