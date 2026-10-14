import Foundation
import Darwin

public enum RuntimePhase: String, Codable, Sendable {
    case stopped, starting, installing, provisioning, running, paused, stopping, failed
    public var title: String { self == .provisioning ? "Setting up Ubuntu" : rawValue.capitalized }
    public var isActive: Bool { ![.stopped, .failed].contains(self) }
}

public struct RuntimeStatus: Codable, Sendable {
    public var phase: RuntimePhase
    public var pid: Int32
    public var session: UUID
    public var progress: Double?
    public var message: String?
    public var updatedAt: Date
    public init(phase: RuntimePhase, pid: Int32 = getpid(), session: UUID, progress: Double? = nil, message: String? = nil) {
        self.phase = phase; self.pid = pid; self.session = session
        self.progress = progress; self.message = message; self.updatedAt = Date()
    }
    public func save(to directory: URL) throws {
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("Runtime.json"), options: .atomic)
    }
    public static func load(from directory: URL) -> Self? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("Runtime.json")),
              let status = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        return status
    }
}

public enum RuntimeAction: String, Codable { case pause, resume, shutdown, forceStop, show, retrySetup }

public struct RuntimeCommand: Codable {
    public var action: RuntimeAction
    public var session: UUID
    public init(action: RuntimeAction, session: UUID) { self.action = action; self.session = session }
    public func send(to directory: URL) throws {
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("Command.json"), options: .atomic)
    }
}

/// A kernel lock, held for the entire runner lifetime and during mutations.
/// Process IDs alone are not a safe indication that a VM owns its disk.
public final class VMLock {
    private let descriptor: Int32
    public init(directory: URL) throws {
        descriptor = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw VMError.message("Cannot open this machine’s lock file.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw VMError.message("This machine is in use. Shut it down before changing it.")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
    public static func isHeld(at directory: URL) -> Bool {
        do { let lock = try VMLock(directory: directory); withExtendedLifetime(lock) {}; return false }
        catch { return true }
    }
}
