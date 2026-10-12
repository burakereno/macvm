import Foundation

/// Connection failures during boot or a login-session transition are not proof
/// that the tools are missing. Use a monotonic clock and allow time to reconnect.
public struct GuestToolsAvailability {
    public enum Status: Equatable { case checking, connected, notConnected }
    public static let startupGrace: TimeInterval = 45
    public private(set) var status: Status = .checking
    public private(set) var hasShownReminder = false
    private var firstFailureAt: TimeInterval?

    public init() {}

    public static func shouldCheck(system: GuestSystem, phase: RuntimePhase,
                                   restoring: Bool, busy: Bool) -> Bool {
        system == .macOS && phase == .running && !restoring && !busy
    }

    public var shouldRemind: Bool { status == .notConnected && !hasShownReminder }
    public mutating func markReminderShown() { hasShownReminder = true }

    public mutating func record(connected: Bool, at uptime: TimeInterval) {
        if connected {
            firstFailureAt = nil
            status = .connected
        } else {
            if firstFailureAt == nil { firstFailureAt = uptime }
            status = uptime - firstFailureAt! >= Self.startupGrace ? .notConnected : .checking
        }
    }

    /// Paused/installer time must not count toward an unavailable-tools warning.
    public mutating func suspend() {
        firstFailureAt = nil
        status = .checking
    }
}
