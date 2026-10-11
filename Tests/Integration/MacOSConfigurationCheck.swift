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
            let saved = try VMStorage.validateBundle(at: bundle)
            let config = try VMConfigurationFactory.make(record: saved, directory: bundle)
            try config.validate()
            print("PASS: Apple restore metadata, supported hardware model, auxiliary storage, identity, and VZ configuration.")
            print("Restore build: \(image.buildVersion). Guest: \(saved.osVersion ?? "macOS").")
            print("Full IPSW installation and boot were not performed by this check.")
        } catch {
            fputs("FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
