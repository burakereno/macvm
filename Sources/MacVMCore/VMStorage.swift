import Foundation
import Darwin

public enum VMStorage {
    public static let gib: UInt64 = 1_073_741_824

    public static func availableBytes(at url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return UInt64(max(0, values?.volumeAvailableCapacity ?? 0))
    }

    public static func allocatedBytes(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
    }

    public static func validate(_ record: VirtualMachineRecord, hostCPUs: Int = ProcessInfo.processInfo.activeProcessorCount,
                                hostMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) throws {
        guard !record.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, record.name.count <= 100 else {
            throw VMError.message("Enter a machine name between 1 and 100 characters.")
        }
        guard (1...max(1, hostCPUs)).contains(record.cpuCount) else { throw VMError.message("Choose a CPU count available on this Mac.") }
        guard record.memoryGB >= 2, UInt64(record.memoryGB) <= hostMemory / gib else { throw VMError.message("Choose at least 2 GB of memory, within this Mac’s capacity.") }
        guard record.diskGB >= record.system.minimumDiskGB, record.diskGB <= 2048 else {
            throw VMError.message("Choose a disk between \(record.system.minimumDiskGB) GB and 2 TB.")
        }
        let folders = record.sharedFolders ?? []
        guard folders.count <= 8, Set(folders.map(\.name)).count == folders.count,
              folders.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 80 && !$0.name.contains("/") && !$0.name.contains("\0") && $0.name != "." && $0.name != ".." && $0.name != "MacVM Guest Tools" && $0.path.hasPrefix("/") && !$0.path.contains("\0") }) else {
            throw VMError.message("Choose up to eight shared folders with unique names.")
        }
    }

    public static func createEmptyBundle(record: VirtualMachineRecord, location: URL, staging: Bool = false) throws -> URL {
        try validate(record)
        let destination = location.appendingPathComponent(staging ? ".\(record.id.uuidString).creating" : "\(record.id.uuidString).macvm")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        do {
            let disk = destination.appendingPathComponent("Disk.img")
            let fd = open(disk.path, O_CREAT | O_EXCL | O_RDWR, 0o600)
            guard fd >= 0 else { throw VMError.message("Cannot create a virtual disk at this location.") }
            defer { close(fd) }
            guard ftruncate(fd, off_t(UInt64(record.diskGB) * gib)) == 0 else {
                throw VMError.message("Cannot allocate the virtual disk. Check the destination disk format and free space.")
            }
            try record.save(to: destination)
            return destination
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }

    public static func clone(_ source: VMEntry, to location: URL) throws -> VMEntry {
        let lock = try VMLock(directory: source.url)
        defer { withExtendedLifetime(lock) {} }
        guard !source.record.installationPending else { throw VMError.message("Complete installation before duplicating this machine.") }
        var record = try validateBundle(at: source.url)
        record.id = UUID(); record.name += " Copy"; record.createdAt = Date()
        record.macAddress = VirtualMachineRecord.randomMACAddress()
        let destination = location.appendingPathComponent(".\(record.id.uuidString).cloning")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for name in ["Disk.img", "AuxiliaryStorage", "HardwareModel", "EFI.nvram", "Installer.iso"] {
                let original = source.url.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: original.path) else { continue }
                let copy = destination.appendingPathComponent(name)
                if clonefile(original.path, copy.path, 0) != 0 {
                    let needed = allocatedBytes(at: original)
                    guard availableBytes(at: location) > UInt64(max(0, needed)) + gib else {
                        throw VMError.message("There is not enough free space to copy this machine to that volume.")
                    }
                    try FileManager.default.copyItem(at: original, to: copy)
                }
            }
            try VMConfigurationFactory.writeNewMachineIdentifier(to: destination, system: record.system)
            try record.save(to: destination)
            let published = location.appendingPathComponent(record.id.uuidString).appendingPathExtension("macvm")
            try FileManager.default.moveItem(at: destination, to: published)
            return VMEntry(record: record, url: published)
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
    }

    public static func validateBundle(at url: URL) throws -> VirtualMachineRecord {
        guard url.pathExtension == "macvm" else { throw VMError.message("Choose a .macvm machine package.") }
        let record = try VirtualMachineRecord.load(from: url)
        // Packages may come from a more powerful Mac. Allow them into the
        // library so resources can be reduced before the runtime host check.
        try validate(record, hostCPUs: 512, hostMemory: 8192 * gib)
        let required = record.system == .macOS ? ["Disk.img", "HardwareModel", "MachineIdentifier", "AuxiliaryStorage"] : ["Disk.img", "EFI.nvram"]
        for filename in required {
            let file = url.appendingPathComponent(filename)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw VMError.message("The machine package contains an invalid \(filename) file.") }
        }
        return record
    }
}
