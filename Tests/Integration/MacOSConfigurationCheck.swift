import Foundation
import Virtualization

/// Opt-in integration check. Resolves Apple's restore metadata, creates actual
/// firmware/identity files, and validates the same configuration used by the app.
/// Does not download an IPSW or claim to test installation or guest boot.
@main
struct MacOSConfigurationCheck {
    @MainActor static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacVM-Configuration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let image = try await VZMacOSRestoreImage.latestSupported
            guard let requirements = image.mostFeaturefulSupportedConfiguration else {
                throw VMError.message("Apple did not return a configuration supported by this host.")
            }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let memoryGB = Int((requirements.minimumSupportedMemorySize + VMStorage.gib - 1) / VMStorage.gib)
            let record = VirtualMachineRecord(name: "macOS configuration check", system: .macOS,
                                              cpuCount: max(2, requirements.minimumSupportedCPUCount),
                                              memoryGB: max(4, memoryGB), diskGB: 64)
            let bundle = try VMStorage.createEmptyBundle(record: record, location: root)
            try VMConfigurationFactory.prepareMac(at: bundle, restoreImage: image)
            var saved = try VMStorage.validateBundle(at: bundle)
            let config = try VMConfigurationFactory.make(record: saved, directory: bundle)
            try config.validate()
            guard config.directorySharingDevices.isEmpty else { throw VMError.message("Restore configuration must omit folder shares.") }
            saved.installationPending = false
            let tools = root.appendingPathComponent("GuestTools")
            try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
            saved.sharedFolders = [SharedFolder(name: "Test Folder", path: root.path)]
            let installed = try VMConfigurationFactory.make(record: saved, directory: bundle, guestToolsURL: tools)
            guard let share = installed.directorySharingDevices.first as? VZVirtioFileSystemDeviceConfiguration,
                  share.tag == VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag,
                  let directories = share.share as? VZMultipleDirectoryShare,
                  directories.directories["MacVM Guest Tools"]?.isReadOnly == true,
                  directories.directories["Test Folder"]?.isReadOnly == true else {
                throw VMError.message("First installed boot must include read-only automount shares.")
            }
            print("PASS: Apple restore metadata, supported hardware model, auxiliary storage, identity, and VZ configuration.")
            print("Restore build: \(image.buildVersion). Guest: \(saved.osVersion ?? "macOS").")
            print("PASS: installed-guest configuration includes Guest Tools and selected read-only folders.")
            print("Full IPSW installation and boot were not performed by this check.")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
