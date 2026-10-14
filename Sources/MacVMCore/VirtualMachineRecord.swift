import Foundation

public enum GuestSystem: String, Codable, CaseIterable, Identifiable, Sendable {
    case macOS, linux, windows
    public var id: String { rawValue }
    public var title: String { self == .macOS ? "macOS" : self == .windows ? "Windows" : "Linux" }
    public var symbol: String { self == .macOS ? "apple.logo" : self == .windows ? "square.grid.2x2.fill" : "terminal" }
    public var minimumDiskGB: Int { self == .linux ? 16 : 64 }
    public var diskFilename: String { self == .windows ? "Disk.qcow2" : "Disk.img" }
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
    public var sourceImagePath: String?
    /// Optional string keeps older packages readable and unknown future brands safe.
    public var guestBrand: String?
    public var ubuntuSetup: UbuntuSetup?
    public var clipboardSharingEnabled: Bool?
    public var sharedFolders: [SharedFolder]?
    public var windowsInstallationPending: Bool?
    public var audioEnabled: Bool?

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
        self.guestBrand = GuestBrand.infer(system: system, sourceImagePath: nil, osVersion: nil, name: name).rawValue
    }

    public static func randomMACAddress() -> String {
        ([UInt8(0x02)] + (0..<5).map { _ in UInt8.random(in: 0...255) })
            .map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Imported packages cannot grant themselves access to host folders or
    /// the host clipboard. The user can select sharing again in Settings.
    public func withoutHostSharing() -> Self {
        var copy = self; copy.sharedFolders = nil; copy.clipboardSharingEnabled = false
        return copy
    }

    public static func load(from directory: URL) throws -> Self {
        var record = try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("Config.json")))
        guard record.schemaVersion == 1 else { throw VMError.message("This machine was created with a newer version of MacVM.") }
        // Migrate in memory; the next normal settings save preserves identity on rename.
        if record.guestBrand == nil { record.guestBrand = record.displayBrand.rawValue }
        return record
    }

    public func save(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent("Config.json"), options: .atomic)
    }
}

public struct SharedFolder: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var readOnly: Bool
    public init(name: String, path: String, readOnly: Bool = true) {
        id = UUID(); self.name = name; self.path = path; self.readOnly = readOnly
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
