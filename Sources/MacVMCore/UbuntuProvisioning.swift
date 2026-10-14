import Foundation
import Darwin

public enum UbuntuSetupStage: String, Codable, Sendable {
    case starting, account, packages, desktop, development, verification, ready, failed
    public var title: String {
        switch self {
        case .starting: "Waiting for Ubuntu’s first boot…"
        case .account: "Creating your account…"
        case .packages: "Installing system tools…"
        case .desktop: "Installing the desktop…"
        case .development: "Installing development tools…"
        case .verification: "Checking the installation…"
        case .ready: "Ubuntu is ready"
        case .failed: "Ubuntu setup failed. View the setup log, then retry."
        }
    }
    public var progress: Double {
        switch self {
        case .starting: 0.02; case .account: 0.08; case .packages: 0.2
        case .desktop: 0.4; case .development: 0.7; case .verification: 0.9
        case .ready: 1; case .failed: 0
        }
    }
}

public struct UbuntuProvisionStatus: Codable, Sendable {
    public var version: Int = 1
    public var instanceID: String
    public var stage: UbuntuSetupStage
    public var updatedAt: Double
    public var ipv4: String?
    public var osVersion: String?
    public init(instanceID: String, stage: UbuntuSetupStage, ipv4: String? = nil, osVersion: String? = nil) {
        self.instanceID = instanceID; self.stage = stage
        updatedAt = Date().timeIntervalSince1970
        self.ipv4 = ipv4; self.osVersion = osVersion
    }
}

public enum UbuntuProvisioning {
    public static func instanceID(_ record: VirtualMachineRecord) -> String { "macvm-" + record.id.uuidString.lowercased() }
    public static func folder(in directory: URL) -> URL { directory.appendingPathComponent("Provisioning", isDirectory: true) }
    public static func read(record: VirtualMachineRecord, directory: URL) -> UbuntuProvisionStatus? {
        guard (try? validateFolder(directory)) != nil else { return nil }
        let url = folder(in: directory).appendingPathComponent("Status.json")
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= 16384,
              let data = try? file.read(upToCount: 16385), data.count <= 16384,
              let status = try? JSONDecoder().decode(UbuntuProvisionStatus.self, from: data),
              status.version == 1, status.instanceID == instanceID(record),
              status.updatedAt.isFinite, status.updatedAt <= Date().timeIntervalSince1970 + 300,
              (status.ipv4?.utf8.count ?? 0) <= 64, (status.osVersion?.utf8.count ?? 0) <= 80 else { return nil }
        return status
    }
    public static func validateFolder(_ directory: URL) throws {
        var info = stat()
        guard lstat(folder(in: directory).path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else {
            throw VMError.message("The Ubuntu setup folder is unavailable.")
        }
    }
    public static func requestRetry(record: VirtualMachineRecord, directory: URL) throws {
        guard record.ubuntuSetup?.completed == false else { throw VMError.message("This machine has no pending Ubuntu setup.") }
        try validateFolder(directory)
        try Data(instanceID(record).utf8).write(to: folder(in: directory).appendingPathComponent("Retry"), options: .atomic)
    }
    public static func logText(directory: URL) throws -> String {
        try validateFolder(directory)
        let fd = open(folder(in: directory).appendingPathComponent("Setup.log").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw VMError.message("The setup log is not available yet.") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { throw VMError.message("The setup log is not a regular file.") }
        // A guest controls this file. Bound both I/O and text rendering.
        let limit = 524288
        try file.seek(toOffset: UInt64(max(0, info.st_size - Int64(limit))))
        let raw = String(decoding: try file.read(upToCount: limit) ?? Data(), as: UTF8.self)
        return raw.replacingOccurrences(of: #"\x1b\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
    public static func cleanupSeedAfterStop(at directory: URL) {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("NoCloud.iso").path) else { return }
        guard let lock = try? VMLock(directory: directory) else { return }
        withExtendedLifetime(lock) {
            guard let fresh = try? VirtualMachineRecord.load(from: directory), fresh.ubuntuSetup?.completed == true else { return }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("NoCloud.iso"))
        }
    }
}
