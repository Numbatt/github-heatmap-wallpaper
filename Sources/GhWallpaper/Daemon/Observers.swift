#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import Network

/// Single event type the daemon's main loop reads from. All system observers
/// funnel into one stream so the loop's debounce + dispatch can be uniform.
public enum DaemonEvent: Sendable, Equatable {
    case tick           // adaptive timer fired
    case wake           // NSWorkspace.didWakeNotification
    case networkUp      // NWPathMonitor satisfied transition
    case displayChange  // CGDisplayRegisterReconfigurationCallback flag set
    case login          // initial trigger fired once on daemon start

    public var label: String {
        switch self {
        case .tick:          return "tick"
        case .wake:          return "wake"
        case .networkUp:     return "networkUp"
        case .displayChange: return "displayChange"
        case .login:         return "login"
        }
    }
}

/// Registers the daemon's wake/network/display observers and exposes them as a
/// single AsyncStream<DaemonEvent>. Hold the Observers instance alive for the
/// lifetime of the daemon — when it deallocates, the underlying observer
/// registrations are torn down.
public final class Observers: @unchecked Sendable {

    public let events: AsyncStream<DaemonEvent>
    private let continuation: AsyncStream<DaemonEvent>.Continuation

    private var workspaceWakeObserver: NSObjectProtocol?
    private let networkMonitor: NWPathMonitor
    private let networkQueue = DispatchQueue(label: "dev.numbatt.gh-wallpaper.observers.network")
    private var lastNetworkSatisfied: Bool = true
    private var receivedFirstPathUpdate: Bool = false

    public init() {
        var localContinuation: AsyncStream<DaemonEvent>.Continuation!
        self.events = AsyncStream<DaemonEvent>(bufferingPolicy: .bufferingNewest(64)) { cont in
            localContinuation = cont
        }
        self.continuation = localContinuation

        self.networkMonitor = NWPathMonitor()

        registerWakeObserver()
        registerNetworkObserver()
        registerDisplayObserver()
    }

    deinit {
        if let observer = workspaceWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        networkMonitor.cancel()
        Self.unregisterDisplayCallback(for: self)
        continuation.finish()
    }

    /// Manually post an event into the stream. Used by the daemon to inject
    /// the synthetic `.login` event on startup and for `.tick` events from the
    /// adaptive timer driver loop.
    public func post(_ event: DaemonEvent) {
        continuation.yield(event)
    }

    // MARK: - Wake from sleep

    private func registerWakeObserver() {
        let nc = NSWorkspace.shared.notificationCenter
        workspaceWakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.continuation.yield(.wake)
        }
    }

    // MARK: - Network reachability

    private func registerNetworkObserver() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = (path.status == .satisfied)
            // The first callback delivers the initial state; treat it as the
            // baseline rather than a transition so we don't synthesize a
            // spurious `.networkUp` at daemon startup (the daemon already
            // posts `.login` for the at-startup refresh).
            if !self.receivedFirstPathUpdate {
                self.receivedFirstPathUpdate = true
                self.lastNetworkSatisfied = satisfied
                return
            }
            // Only fire on transition from unsatisfied -> satisfied.
            if satisfied && !self.lastNetworkSatisfied {
                self.continuation.yield(.networkUp)
            }
            self.lastNetworkSatisfied = satisfied
        }
        networkMonitor.start(queue: networkQueue)
    }

    // MARK: - Display reconfiguration

    private func registerDisplayObserver() {
        Self.registerDisplayCallback(for: self)
    }

    fileprivate func handleDisplayReconfiguration(flags: CGDisplayChangeSummaryFlags) {
        // Filter to actually-meaningful changes. We care about:
        //   - displays added/removed
        //   - display geometry / mode changes (resolution)
        //   - mirroring transitions
        // We ignore the "begin configuration" notifications.
        let interesting: CGDisplayChangeSummaryFlags = [
            .addFlag, .removeFlag, .setMainFlag, .setModeFlag,
            .enabledFlag, .disabledFlag, .mirrorFlag, .unMirrorFlag
        ]
        if flags.intersection(interesting).rawValue == 0 { return }
        continuation.yield(.displayChange)
    }

    // CGDisplayRegisterReconfigurationCallback uses a C function pointer; we
    // need a static trampoline + a (display-id -> Observers) table to dispatch
    // back into Swift. There's only ever one Observers in practice (the
    // daemon's), so a static weak reference is sufficient.
    private static var displayCallbackInstalled = false
    nonisolated(unsafe) private static weak var activeInstance: Observers?

    private static func registerDisplayCallback(for instance: Observers) {
        activeInstance = instance
        if displayCallbackInstalled { return }
        let cb: CGDisplayReconfigurationCallBack = { _, flags, _ in
            DispatchQueue.main.async {
                Observers.activeInstance?.handleDisplayReconfiguration(flags: flags)
            }
        }
        let result = CGDisplayRegisterReconfigurationCallback(cb, nil)
        if result == .success {
            displayCallbackInstalled = true
        }
    }

    private static func unregisterDisplayCallback(for instance: Observers) {
        if activeInstance === instance {
            activeInstance = nil
        }
        // CGDisplayRemoveReconfigurationCallback would need the same function
        // pointer; since the daemon Observers is process-lifetime and the
        // callback dispatches via the (now nil) static weak ref, it becomes a
        // no-op on subsequent fires. Leaving the registration in place is
        // safe.
    }
}
#endif
