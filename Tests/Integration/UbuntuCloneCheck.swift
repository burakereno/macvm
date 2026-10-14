import Foundation

@main
struct UbuntuCloneCheck {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let cloneRoot = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        let source = URL(fileURLWithPath: try String(contentsOf: root.appendingPathComponent("MachinePath"), encoding: .utf8)).standardizedFileURL
        guard source.deletingLastPathComponent() == root, source.pathExtension == "macvm" else { throw VMError.message("Unexpected test source.") }
        UbuntuProvisioning.cleanupSeedAfterStop(at: source)
        guard !FileManager.default.fileExists(atPath: source.appendingPathComponent("NoCloud.iso").path) else { throw VMError.message("The completed test seed is still attached.") }
        try FileManager.default.createDirectory(at: cloneRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let original = try VirtualMachineRecord.load(from: source)
        let clone = try VMStorage.clone(VMEntry(record: original, url: source), to: cloneRoot)
        guard clone.id != original.id, clone.record.macAddress != original.macAddress,
              clone.record.ubuntuSetup?.completed == true else { throw VMError.message("Clone identity is not independent.") }
        for name in ["test-key", "test-key.pub", "TestCredential", "SHA256SUMS"] {
            try FileManager.default.copyItem(at: root.appendingPathComponent(name), to: cloneRoot.appendingPathComponent(name))
        }
        try Data(clone.url.path.utf8).write(to: cloneRoot.appendingPathComponent("MachinePath"))
        print("PASS: completed Ubuntu clone has an independent identity/MAC, private setup share and no account seed")
    }
}
