import Foundation
import UserNotifications

/// Tracks consecutive refresh failures and surfaces a single user-visible
/// notification at the configured strike threshold (SPEC §10).
///
/// Behaviour:
///   - `recordFailure()` increments the consecutive-failure counter. When the
///     counter crosses `threshold`, fire one notification. Don't re-notify
///     until the counter resets.
///   - `recordSuccess()` resets the counter and clears the notified flag.
///
/// Thread-safe: a serial dispatch queue serialises state mutations.
public final class FailureTracker: @unchecked Sendable {

    public static let defaultThreshold = 3
    public static let notificationTitle = "gh-wallpaper"
    public static let notificationBody  = "can't refresh your heatmap. Run `gh-wallpaper diagnose` for details."

    private let queue = DispatchQueue(label: "dev.numbatt.gh-wallpaper.failure-tracker")
    private var _consecutiveFailures: Int = 0
    private var _hasNotified: Bool = false

    public let threshold: Int
    public let notifier: Notifier

    public init(threshold: Int = FailureTracker.defaultThreshold, notifier: Notifier? = nil) {
        self.threshold = threshold
        self.notifier = notifier ?? UNUserNotificationsNotifier()
    }

    public var consecutiveFailures: Int {
        return queue.sync { _consecutiveFailures }
    }

    public var hasNotified: Bool {
        return queue.sync { _hasNotified }
    }

    /// Record a failed refresh. Returns the new failure count.
    /// Fires a notification if the threshold is crossed for the first time
    /// since the last reset.
    @discardableResult
    public func recordFailure() -> Int {
        let (count, shouldNotify) = queue.sync { () -> (Int, Bool) in
            _consecutiveFailures += 1
            let crossed = _consecutiveFailures >= threshold && !_hasNotified
            if crossed { _hasNotified = true }
            return (_consecutiveFailures, crossed)
        }
        if shouldNotify {
            notifier.notify(
                title: FailureTracker.notificationTitle,
                body: FailureTracker.notificationBody
            )
        }
        return count
    }

    /// Record a successful refresh. Resets the counter and arms the notifier
    /// for the next failure streak.
    public func recordSuccess() {
        queue.sync {
            _consecutiveFailures = 0
            _hasNotified = false
        }
    }
}

/// Abstraction over UNUserNotificationCenter so tests can swap in a stub.
public protocol Notifier: Sendable {
    func notify(title: String, body: String)
}

/// Real implementation: delivers via UNUserNotificationCenter. Authorization
/// is requested lazily on first notify; if denied, the call is a no-op.
public final class UNUserNotificationsNotifier: Notifier, @unchecked Sendable {

    public init() {}

    public func notify(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            // nil trigger == deliver immediately.
            let request = UNNotificationRequest(
                identifier: "dev.numbatt.gh-wallpaper.failure.\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            center.add(request, withCompletionHandler: nil)
        }
    }
}
