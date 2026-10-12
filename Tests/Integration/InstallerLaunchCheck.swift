import AppKit
import CryptoKit
import Darwin

/// Opt-in live integration: verifies the production helper with a notarized DMG.
/// Uses an isolated app target and never replaces the user's installed app.
@main struct InstallerLaunchCheck {
    static func run(_ executable: String, _ arguments: [String], quiet: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if quiet { process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice }
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure("Command failed: \(executable)") }
    }

    static func failure(_ text: String) -> NSError {
        NSError(domain: "MacVM.UpdateLiveCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    static func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

    static func main() {
        setbuf(stdout, nil)
        do { try checkLaunches() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    static func checkLaunches() throws {
        guard CommandLine.arguments.count == 3 else { throw failure("Pass a notarized MacVM.dmg and a Developer ID signing identity.") }
        let fm = FileManager.default
        let dmg = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let identity = CommandLine.arguments[2]
        let usageURL = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacVM/ApplicationUsage.lock")
        let fd = open(usageURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw failure("Shut down all MacVM machines first.") }
        defer { close(fd) }
        let root = fm.temporaryDirectory.appendingPathComponent("MacVM-live-check-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            let fixtures = NSWorkspace.shared.runningApplications.filter {
                $0.bundleURL?.standardizedFileURL.path.hasPrefix(root.path + "/") == true
            }
            for app in fixtures {
                app.terminate()
                if !waitUntil(3, { app.isTerminated }) { app.forceTerminate() }
            }
            try? fm.removeItem(at: root)
        }
        let oldSource = root.appendingPathComponent("OldApp.swift")
        try Data(#"""
        import AppKit
        let marker = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("old-launched")
        try! Data("rollback relaunched the original executable".utf8).write(to: marker)
        """#.utf8).write(to: oldSource)
        let oldBinary = root.appendingPathComponent("MacVM")
        try run("/usr/bin/xcrun", ["swiftc", oldSource.path, "-o", oldBinary.path])
        let script = root.appendingPathComponent("installer.sh")
        try Data(UpdateInstallerScript.source.utf8).write(to: script)
        let sha = SHA256.hash(data: try Data(contentsOf: dmg)).map { String(format: "%02x", $0) }.joined()
        for rollback in [false, true] {
            let parent = root.appendingPathComponent(rollback ? "rollback Applications" : "success Applications")
            let target = parent.appendingPathComponent("MacVM.app")
            let executable = target.appendingPathComponent("Contents/MacOS/MacVM")
            try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: oldBinary, to: executable)
            let info: [String: Any] = ["CFBundleExecutable": "MacVM", "CFBundleIdentifier": "com.burakerenoglu.macvm",
                                      "CFBundleName": "MacVM", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.1.0",
                                      "CFBundleVersion": "1", "LSUIElement": true]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: target.appendingPathComponent("Contents/Info.plist"))
            try run("/usr/bin/codesign", ["--force", "--sign", identity, "--options", "runtime", "--timestamp", target.path], quiet: true)
            try run(executable.path, [])
            let oldMarker = parent.appendingPathComponent("old-launched")
            guard fm.fileExists(atPath: oldMarker.path) else { throw failure("Original-app fixture did not create its launch marker.") }
            try fm.removeItem(at: oldMarker)
            let original = try Data(contentsOf: executable)
            // An invalid confirmation prefix exercises a real successful launch
            // followed by missing confirmation and rollback, without altering code.
            let prefix = rollback ? "MacVM-unconfirmed-" : "MacVM-update-"
            let work = fm.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString)
            try fm.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: work) }
            try fm.copyItem(at: dmg, to: work.appendingPathComponent("MacVM.dmg"))
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path, work.path, target.path, "0.2.0", sha,
                                 "com.burakerenoglu.macvm", "66K3EFBVB6", "999999"]
            process.standardInput = FileHandle(fileDescriptor: dup(fd), closeOnDealloc: true)
            let log = parent.appendingPathComponent("helper.log")
            fm.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            process.standardOutput = output; process.standardError = output
            try process.run(); try output.close()
            guard waitUntil(90, { fm.fileExists(atPath: work.appendingPathComponent("ready").path) || !process.isRunning }),
                  process.isRunning else { throw failure("Helper did not stage the signed app: \((try? String(contentsOf: log, encoding: .utf8)) ?? "")") }
            try Data().write(to: work.appendingPathComponent("quit-approved"))
            guard waitUntil(55, { !process.isRunning }) else { process.terminate(); throw failure("Helper did not finish.") }
            if rollback {
                guard waitUntil(10, { fm.fileExists(atPath: parent.appendingPathComponent("old-launched").path) }) else {
                    throw failure("Rollback did not relaunch the original executable: \((try? String(contentsOf: log, encoding: .utf8)) ?? "")")
                }
                _ = waitUntil(3, { !NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL == target.standardizedFileURL } })
            }
            let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.standardizedFileURL == target.standardizedFileURL }
            defer { for app in apps { app.terminate() } }
            if rollback {
                guard process.terminationStatus != 0, try Data(contentsOf: executable) == original,
                      waitUntil(10, { fm.fileExists(atPath: parent.appendingPathComponent("old-launched").path) }),
                      apps.isEmpty else { throw failure("Rollback verification failed: status=\(process.terminationStatus), originalRestored=\((try? Data(contentsOf: executable)) == original), running=\(apps.map { $0.bundleURL?.path ?? "unknown" }).") }
                print("PASS: unconfirmed launch stopped, original executable restored and relaunched.")
            } else {
                let installed = try PropertyListSerialization.propertyList(from: Data(contentsOf: target.appendingPathComponent("Contents/Info.plist")), format: nil) as! [String: Any]
                guard process.terminationStatus == 0, installed["CFBundleShortVersionString"] as? String == "0.2.0", apps.count == 1,
                      !fm.fileExists(atPath: parent.appendingPathComponent("old-launched").path) else { throw failure("Signed installation/relaunch failed.") }
                print("PASS: signed DMG assessed, app replaced, actual MacVM 0.2.0 initialized and confirmed.")
            }
            guard !fm.fileExists(atPath: work.path), !(try fm.contentsOfDirectory(atPath: parent.path)).contains(where: { $0.hasPrefix(".MacVM-update.") }) else { throw failure("Update left workspace or backup behind.") }
            print("PASS: workspace, mount and staging cleanup.")
        }
    }
}
