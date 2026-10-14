import Foundation
import Virtualization

@main
@MainActor
struct UbuntuAutomaticCheck {
    static var vm: VZVirtualMachine?
    static var delegate: Observer?
    static var timer: Timer?
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 6, let profile = UbuntuProfile(rawValue: args[2]), let release = UbuntuRelease(rawValue: args[3]) else {
            throw VMError.message("Usage: check ROOT PROFILE RELEASE ARCHIVE DEVELOPMENT")
        }
        let root = URL(fileURLWithPath: args[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let archive = URL(fileURLWithPath: args[4])
        let sums = try String(contentsOf: root.appendingPathComponent("SHA256SUMS"), encoding: .utf8)
        let image = try UbuntuImageCatalog.parse(sums, release: release)
        var record: VirtualMachineRecord
        let entry: VMEntry
        let existingPath = root.appendingPathComponent("MachinePath")
        if FileManager.default.fileExists(atPath: existingPath.path) {
            let path = URL(fileURLWithPath: try String(contentsOf: existingPath, encoding: .utf8)).standardizedFileURL
            guard path.deletingLastPathComponent() == root.standardizedFileURL else { throw VMError.message("Unexpected test machine location.") }
            record = try VirtualMachineRecord.load(from: path)
            entry = VMEntry(record: record, url: path)
        } else {
            record = VirtualMachineRecord(name: "Ubuntu Automatic Test", system: .linux, cpuCount: 2, memoryGB: profile == .server ? 2 : 4, diskGB: 32)
            record.ubuntuSetup = UbuntuSetup(release: release, profile: profile, username: "macvmtest", developmentTools: args[5] == "yes")
            record.clipboardSharingEnabled = profile.desktop
            let credential = UUID().uuidString + UUID().uuidString
            let secretURL = root.appendingPathComponent("TestCredential")
            try Data(credential.utf8).write(to: secretURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secretURL.path)
            let hash = try SHA512Crypt.hash(password: credential)
            let key = try String(contentsOf: root.appendingPathComponent("test-key.pub"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            print("Preparing verified \(release.title) / \(profile.title)…")
            entry = try UbuntuMachinePreparation.prepare(record: record, location: root, image: image, archive: archive, passwordHash: hash, sshPublicKey: key)
            record = entry.record
            try Data(entry.url.path.utf8).write(to: existingPath)
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("FailFirstBoot").path) {
                try Data().write(to: UbuntuProvisioning.folder(in: entry.url).appendingPathComponent("FailOnce"))
                let data = try UbuntuSeed.userData(record: record, passwordHash: hash, sshPublicKey: key)
                var json = try JSONSerialization.jsonObject(with: data.dropFirst("#cloud-config\n".utf8.count)) as! [String: Any]
                var files = json["write_files"] as! [[String: Any]]
                let original = files[0]["content"] as! String
                files[0]["content"] = original.replacingOccurrences(of: "status desktop", with: "if [ -f \"$HOST/FailOnce\" ]; then exit 99; fi\nstatus desktop")
                json["write_files"] = files
                let seed = entry.url.appendingPathComponent(".fault-seed")
                try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try (Data("#cloud-config\n".utf8) + JSONSerialization.data(withJSONObject: json)).write(to: seed.appendingPathComponent("user-data"))
                try JSONSerialization.data(withJSONObject: ["instance-id": UbuntuProvisioning.instanceID(record)]).write(to: seed.appendingPathComponent("meta-data"))
                try FileManager.default.removeItem(at: entry.url.appendingPathComponent("NoCloud.iso"))
                _ = try UbuntuImage.output("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-default-volume-name", "CIDATA", "-o", entry.url.appendingPathComponent("NoCloud.iso").path, seed.path])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: entry.url.appendingPathComponent("NoCloud.iso").path)
                try FileManager.default.removeItem(at: seed)
            }
        }
        let config = try VMConfigurationFactory.make(record: record, directory: entry.url)
        let logURL = root.appendingPathComponent("Console.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        serial.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: try FileHandle(forWritingTo: logURL))
        config.serialPorts = [serial]
        try config.validate()
        let machine = VZVirtualMachine(configuration: config)
        let lock = try VMLock(directory: entry.url)
        let observer = Observer(); delegate = observer; vm = machine; machine.delegate = observer
        machine.start { result in
            if case .failure(let error) = result { fputs("FAIL boot: \(error.localizedDescription)\n", stderr); exit(1) }
            print("VM booted"); fflush(stdout)
        }
        var previous: UbuntuSetupStage?
        var shutdownSent = false
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            if let status = UbuntuProvisioning.read(record: record, directory: entry.url) {
                if status.stage != previous { print("Stage: \(status.stage.rawValue)"); fflush(stdout); previous = status.stage }
                if status.stage == .ready && record.ubuntuSetup?.completed == false {
                    record.ubuntuSetup?.completed = true; record.osVersion = status.osVersion
                    try? record.save(to: entry.url)
                    try? Data((status.ipv4 ?? "").utf8).write(to: root.appendingPathComponent("ReadyIP"))
                }
            }
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("RetrySetup").path) {
                try? UbuntuProvisioning.requestRetry(record: record, directory: entry.url)
                try? FileManager.default.removeItem(at: root.appendingPathComponent("RetrySetup"))
            }
            if !shutdownSent && FileManager.default.fileExists(atPath: root.appendingPathComponent("Stop").path), machine.canRequestStop {
                do { try machine.requestStop(); shutdownSent = true } catch { print("Shutdown error: \(error.localizedDescription)") }
            }
        }
        fflush(stdout)
        withExtendedLifetime(lock) { RunLoop.main.run() }
    }

    final class Observer: NSObject, VZVirtualMachineDelegate {
        func guestDidStop(_ virtualMachine: VZVirtualMachine) { print("PASS: guest stopped normally"); exit(0) }
        func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
            fputs("FAIL VM: \(error.localizedDescription)\n", stderr); exit(1)
        }
    }
}
