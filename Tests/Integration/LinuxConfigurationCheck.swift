import Foundation
import Virtualization

/// Signed integration check: VZ configuration validation requires the
/// virtualization entitlement, which the SwiftPM XCTest runner does not have.
@main
struct LinuxConfigurationCheck {
    @MainActor static func main() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacVM-Linux-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var record = VirtualMachineRecord(name: "Linux configuration check", system: .linux, cpuCount: 2, memoryGB: 2, diskGB: 16)
            let bundle = try VMStorage.createEmptyBundle(record: record, location: root)
            try VMConfigurationFactory.prepareLinux(at: bundle)
            let iso = bundle.appendingPathComponent("Installer.iso")
            try Data(repeating: 0, count: 4096).write(to: iso)
            record.clipboardSharingEnabled = true
            record.sharedFolders = [SharedFolder(name: "Test Share", path: root.path)]
            for installer in [false, true] {
                record.bootFromInstaller = installer
                let config = try VMConfigurationFactory.make(record: record, directory: bundle)
                guard config.consoleDevices.count == 1, let console = config.consoleDevices.first as? VZVirtioConsoleDeviceConfiguration,
                      console.ports[0]?.name == VZSpiceAgentPortAttachment.spiceAgentPortName,
                      (console.ports[0]?.attachment as? VZSpiceAgentPortAttachment)?.sharesClipboard == true,
                      (config.directorySharingDevices.first as? VZVirtioFileSystemDeviceConfiguration)?.tag == "macvm-share" else {
                    throw VMError.message("Clipboard or shared folder configuration is missing.")
                }
                guard config.storageDevices.count == (installer ? 2 : 1),
                      config.storageDevices.last is VZVirtioBlockDeviceConfiguration else {
                    throw VMError.message("Unexpected Linux disk configuration.")
                }
                for device in config.storageDevices {
                    guard let attachment = device.attachment as? VZDiskImageStorageDeviceAttachment,
                          attachment.cachingMode == .cached,
                          attachment.synchronizationMode == .full,
                          attachment.isReadOnly == (attachment.url == iso) else {
                        throw VMError.message("Linux storage must use cached I/O, full flushes, and read-only installer media.")
                    }
                }
            }
            record.sharedFolders = [SharedFolder(name: "Disconnected", path: root.appendingPathComponent("missing-drive").path)]
            do {
                _ = try VMConfigurationFactory.make(record: record, directory: bundle)
                throw VMError.message("Unavailable share was accepted.")
            } catch {
                guard error.localizedDescription.contains("unavailable") else { throw error }
            }
            print("PASS: Linux installed-disk and installer configurations use cached I/O with full flushes and correct media permissions.")
            print("PASS: SPICE clipboard port and read-only virtiofs folder share validate.")
            print("PASS: an unavailable shared folder produces a start error before running the VM.")
            print("Guest installation and boot must be tested separately.")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
