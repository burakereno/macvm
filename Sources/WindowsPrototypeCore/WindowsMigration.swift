import Foundation
import MacVMCore

public enum WindowsMigration {
    /// Move the installed test VM into the normal library without copying its
    /// disk, regenerating its EFI/TPM identity, or trusting imported executables.
    public static func migrate(from source: URL, to location: URL) throws -> VMEntry {
        let lock = try VMLock(directory: source)
        defer { withExtendedLifetime(lock) {} }
        guard !FileManager.default.fileExists(atPath: source.appendingPathComponent("Config.json").path) else {
            throw VMError.message("This machine is already in MacVM format.")
        }
        let legacy = try WindowsConfiguration.load(directory: source)
        guard legacy.installerPath == nil, legacy.toolsPath == nil else {
            throw VMError.message("Shut down Windows and detach its installation media before importing it.")
        }
        let sourceVolume = try source.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let destinationVolume = try location.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        guard sourceVolume != nil, sourceVolume == destinationVolume else {
            throw VMError.message("Import Windows into a location on the same disk first.")
        }
        var record = VirtualMachineRecord(name: legacy.name.replacingOccurrences(of: " Prototype", with: ""), system: .windows,
                                           cpuCount: legacy.cpuCount, memoryGB: legacy.memoryGB, diskGB: legacy.diskGB)
        record.osVersion = "Windows 11 ARM"
        record.macAddress = legacy.macAddress ?? "02:4d:56:57:11:01"
        record.networkEnabled = legacy.networkEnabled ?? true
        let staging = location.appendingPathComponent(".\(record.id.uuidString).macvm")
        let destination = location.appendingPathComponent("\(record.id.uuidString).macvm")
        try FileManager.default.moveItem(at: source, to: staging)
        do {
            try record.save(to: staging)
            _ = try VMStorage.validateBundle(at: staging)
            try FileManager.default.moveItem(at: staging, to: destination)
            return VMEntry(record: record, url: destination)
        } catch {
            try? FileManager.default.removeItem(at: staging.appendingPathComponent("Config.json"))
            do { try FileManager.default.moveItem(at: staging, to: source) }
            catch { throw VMError.message("The import could not be rolled back. The preserved VM is at \(staging.path).") }
            throw error
        }
    }
}
