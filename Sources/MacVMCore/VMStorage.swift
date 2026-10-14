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
        try record.ubuntuSetup?.validate(record: record)
        if record.system == .windows {
            guard record.cpuCount >= 2, record.cpuCount <= 16, record.memoryGB >= 4, record.memoryGB <= 64,
                  record.diskGB <= 512, !record.installationPending, record.ubuntuSetup == nil else {
                throw VMError.message("Windows needs 2–16 CPUs, 4–64 GB RAM and a 64–512 GB disk.")
            }
        }
        let folders = record.sharedFolders ?? []
        guard folders.count <= 8, Set(folders.map(\.name)).count == folders.count,
              folders.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 80 && !$0.name.contains("/") && !$0.name.contains("\0") && $0.name != "." && $0.name != ".." && $0.name != "MacVM Guest Tools" && $0.path.hasPrefix("/") && !$0.path.contains("\0") }) else {
            throw VMError.message("Choose up to eight shared folders with unique names.")
        }
    }

    public static func createEmptyBundle(record: VirtualMachineRecord, location: URL, staging: Bool = false) throws -> URL {
        guard record.system != .windows else { throw VMError.message("Add an existing Windows machine to use the Windows engine.") }
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
        guard source.record.system != .windows else { throw VMError.message("Windows duplication is not available yet. TPM identity must be preserved safely.") }
        let lock = try VMLock(directory: source.url)
        defer { withExtendedLifetime(lock) {} }
        guard !source.record.installationPending, source.record.ubuntuSetup?.completed != false else { throw VMError.message("Complete installation before duplicating this machine.") }
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
            if record.ubuntuSetup != nil {
                try FileManager.default.createDirectory(at: UbuntuProvisioning.folder(in: destination), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
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
        let required = record.system == .macOS ? ["Disk.img", "HardwareModel", "MachineIdentifier", "AuxiliaryStorage"] : record.system == .windows ? ["Disk.qcow2", "EFI.fd"] : ["Disk.img", "EFI.nvram"]
        for filename in required {
            let file = url.appendingPathComponent(filename)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw VMError.message("The machine package contains an invalid \(filename) file.") }
        }
        if record.system == .windows {
            let file = try FileHandle(forReadingFrom: url.appendingPathComponent("Disk.qcow2"))
            defer { try? file.close() }
            let header = try file.read(upToCount: 104) ?? Data()
            guard header.count == 104, QCOW2.number(header, 0, 4) == 0x514649fb,
                  [2, 3].contains(QCOW2.number(header, 4, 4)),
                  QCOW2.number(header, 8, 8) == 0, QCOW2.number(header, 16, 4) == 0,
                  QCOW2.number(header, 32, 4) == 0,
                  QCOW2.number(header, 24, 8) == UInt64(record.diskGB) * gib,
                  QCOW2.number(header, 4, 4) != 3 || QCOW2.number(header, 72, 8) & ~UInt64(1) == 0 else {
                throw VMError.message("Windows requires a standalone QCOW2 disk without external backing files or unsupported features.")
            }
            let tpm = url.appendingPathComponent("TPM")
            let values = try tpm.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  let files = FileManager.default.enumerator(at: tpm, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey]) else {
                throw VMError.message("The Windows TPM state is missing or invalid.")
            }
            for case let child as URL in files {
                let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw VMError.message("The Windows TPM contains an invalid file.") }
            }
            let permanent = try tpm.appendingPathComponent("tpm2-00.permall").resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard permanent.isRegularFile == true, permanent.isSymbolicLink != true, (permanent.fileSize ?? 0) > 0 else {
                throw VMError.message("The Windows TPM identity is missing. Restore it from a backup before starting this machine.")
            }
        }
        return record
    }
}
