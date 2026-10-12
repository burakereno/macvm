import Foundation

/// Tracks a guest shutdown request, not a forced power-off. Call with a monotonic clock.
public struct ShutdownWait {
    public enum Result: Equatable { case waiting, stopped, timedOut }
    public static let timeout: TimeInterval = 30
    private var requestedAt: TimeInterval?
    public var isPending: Bool { requestedAt != nil }

    public init() {}

    /// Repeated requests must not extend the original deadline.
    @discardableResult public mutating func begin(at uptime: TimeInterval) -> Bool {
        guard requestedAt == nil else { return false }
        requestedAt = uptime
        return true
    }

    public mutating func check(isStopped: Bool, at uptime: TimeInterval) -> Result? {
        guard let requestedAt else { return nil }
        if isStopped { clear(); return .stopped }
        if uptime - requestedAt >= Self.timeout { clear(); return .timedOut }
        return .waiting
    }

    public mutating func clear() { requestedAt = nil }
}
