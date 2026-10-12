import Foundation

/// Executes the production installer rejection path without mounting a DMG or
/// launching UI. A corrupt download must leave the current app untouched.
@main struct InstallerFailureCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacVM-update-failure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Application folder with spaces/MacVM.app")
        let work = root.appendingPathComponent("download")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let original = target.appendingPathComponent("original.txt")
        try Data("keep the existing app".utf8).write(to: original)
        try Data("corrupt dmg".utf8).write(to: work.appendingPathComponent("MacVM.dmg"))
        let script = root.appendingPathComponent("installer.sh")
        try Data(UpdateInstallerScript.source.utf8).write(to: script)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, work.path, target.path, "0.2.0", String(repeating: "a", count: 64),
                             "com.burakerenoglu.macvm", "66K3EFBVB6", "999999"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus != 0, try Data(contentsOf: original) == Data("keep the existing app".utf8),
              !FileManager.default.fileExists(atPath: work.path) else {
            throw NSError(domain: "MacVM", code: 1, userInfo: [NSLocalizedDescriptionKey: "Corrupt installer modified the app or left temporary files."])
        }
        print("PASS: installer rejects corrupt DMG before mounting/replacement, preserves existing app, and cleans its workspace.")
    }
}
