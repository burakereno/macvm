import Foundation

public enum GuestSystem: String, Codable, CaseIterable, Identifiable, Sendable {
    case macOS, linux
    public var id: String { rawValue }
    public var title: String { self == .macOS ? "macOS" : "Linux" }
    public var symbol: String { self == .macOS ? "apple.logo" : "terminal" }
    public var minimumDiskGB: Int { self == .macOS ? 64 : 16 }
}

public struct VirtualMachineRecord: Codable, Identifiable, Equatable, Sendable {
    public var schemaVersion = 1
    public var id: UUID
    public var name: String
    public var system: GuestSystem
    public var cpuCount: Int
    public var memoryGB: Int
    public var diskGB: Int
    public var createdAt: Date
    public var macAddress: String
    public var networkEnabled: Bool
    public var bootFromInstaller: Bool
    public var installationPending: Bool
    public var restoreImagePath: String?
    public var osVersion: String?

    public init(name: String, system: GuestSystem, cpuCount: Int = 4, memoryGB: Int = 4, diskGB: Int = 64) {
        self.id = UUID()
        self.name = name
        self.system = system
        self.cpuCount = cpuCount
        self.memoryGB = memoryGB
        self.diskGB = diskGB
        self.createdAt = Date()
        self.macAddress = Self.randomMACAddress()
        self.networkEnabled = true
        self.bootFromInstaller = system == .linux
        self.installationPending = system == .macOS
    }

    public static func randomMACAddress() -> String {
        ([UInt8(0x02)] + (0..<5).map { _ in UInt8.random(in: 0...255) })
            .map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    public static func load(from directory: URL) throws -> Self {
        let record = try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("Config.json")))
        guard record.schemaVersion == 1 else { throw VMError.message("This machine was created with a newer version of MacVM.") }
        return record
    }

    public func save(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent("Config.json"), options: .atomic)
    }
}

public struct VMEntry: Identifiable, Equatable, Sendable {
    public var record: VirtualMachineRecord
    public var url: URL
    public var id: UUID { record.id }
    public init(record: VirtualMachineRecord, url: URL) { self.record = record; self.url = url }
}

public enum VMError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}
