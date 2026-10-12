import AppKit
import Observation
import MacVMCore

@MainActor @Observable
public final class UpdateInstaller {
    public private(set) var isWorking = false
    public private(set) var stage = ""
    public private(set) var lastError: String?
    public init() {}

    public func install(_ release: UpdateRelease, machinesAreRunning: () -> Bool) async {
        guard !isWorking else { return }
        isWorking = true; lastError = nil
        defer { isWorking = false }
        var workspace: URL?
        var helper: Process?
        var usageLock: AppUsageLock?
        defer { withExtendedLifetime(usageLock) {} }
        do {
            guard !machinesAreRunning() else { throw UpdateError.busy }
            let target = Bundle.main.bundleURL.standardizedFileURL
            guard target.pathExtension == "app", FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
                throw VMError.message("Move MacVM to a writable Applications folder before updating.")
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacVM-update-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            workspace = root
            stage = "Downloading update…"
            let expected = try UpdateContract.assetURL(tag: release.tag)
            guard expected == release.downloadURL else { throw UpdateError.invalidManifest }
            try release.manifest.validate(tag: release.tag)
            var request = URLRequest(url: expected); request.timeoutInterval = 120
            let (download, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw UpdateError.badResponse }
            try UpdateContract.validateResponseURL(http.url)
            let dmg = root.appendingPathComponent(UpdateContract.assetName)
            try FileManager.default.moveItem(at: download, to: dmg)
            stage = "Verifying installer…"
            try await Task.detached { try release.manifest.verify(file: dmg) }.value
            guard !machinesAreRunning() else { throw UpdateError.busy }
            usageLock = try AppUsageLock(exclusive: true)
            let copiedScript = root.appendingPathComponent("install-update.sh")
            try Data(UpdateInstallerScript.source.utf8).write(to: copiedScript, options: .atomic)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.standardInput = try usageLock?.inheritedHandle()
            process.arguments = [copiedScript.path, root.path, target.path, release.manifest.version,
                                 release.manifest.sha256, UpdateContract.bundleIdentifier, UpdateContract.teamIdentifier,
                                 String(ProcessInfo.processInfo.processIdentifier)]
            let log = root.appendingPathComponent("installer.log")
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let output = try FileHandle(forWritingTo: log)
            process.standardOutput = output; process.standardError = output
            try process.run(); try output.close(); helper = process
            for _ in 0..<180 {
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) {
                    guard !machinesAreRunning() else { throw UpdateError.busy }
                    try Data().write(to: root.appendingPathComponent("quit-approved"))
                    stage = "Restarting MacVM…"
                    workspace = nil // The detached helper owns cleanup after quit.
                    NSApp.terminate(nil)
                    return
                }
                guard process.isRunning else { throw UpdateError.invalidInstaller }
                try await Task.sleep(for: .milliseconds(500))
            }
            throw UpdateError.invalidInstaller
        } catch {
            helper?.terminate()
            for _ in 0..<100 where helper?.isRunning == true { try? await Task.sleep(for: .milliseconds(50)) }
            lastError = error.localizedDescription; stage = ""
            if let workspace, helper?.isRunning != true { try? FileManager.default.removeItem(at: workspace) }
        }
    }
}
