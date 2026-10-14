import Foundation
import Darwin
import MacVMCore

public final class WindowsSession {
    public enum Action { case pause, resume, shutdown, forceStop }
    private let queue = DispatchQueue(label: "com.burakerenoglu.macvm.windows-prototype")
    private var qemu: Process?
    private var tpm: Process?
    private var qmp: QMPClient?
    private var lock: VMLock?
    private var runtime: URL?
    private var timer: DispatchSourceTimer?
    private var stoppingAt: Date?
    private var imageLeases: [ImageLease] = []
    private var displayToolsMounted = false
    private var update: ((String, String) -> Void)?
    public init() {}

    public func start(_ config: WindowsConfiguration, ownsLock: Bool = false, embeddedDisplay: Bool = false,
                      displayReady: ((URL) -> Void)? = nil, update: @escaping (String, String) -> Void) {
        queue.async { [self] in
            guard self.qemu == nil else { return }
            self.update = update; self.publish("Starting", "Starting QEMU with hardware acceleration…")
            do {
                if !ownsLock { self.lock = try VMLock(directory: config.directory) }
                self.imageLeases = try [config.installerPath, config.toolsPath].compactMap { $0 }.map { try ImageLease(url: URL(fileURLWithPath: $0)) }
                let runtime = URL(fileURLWithPath: "/tmp/mvw-\(getuid())-\(UUID().uuidString.prefix(8))", isDirectory: true)
                try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                self.runtime = runtime
                let tpmState = config.directory.appendingPathComponent("TPM", isDirectory: true)
                try FileManager.default.createDirectory(at: tpmState, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let logURL = config.directory.appendingPathComponent("Engine.log")
                FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                let log = try FileHandle(forWritingTo: logURL)
                defer { try? log.close() }
                let tpm = Process(); tpm.executableURL = URL(fileURLWithPath: config.swtpmPath)
                tpm.currentDirectoryURL = config.directory
                tpm.arguments = ["socket", "--tpm2", "--tpmstate", "dir=TPM,mode=0600,lock", "--ctrl",
                                 "type=unixio,path=\(runtime.appendingPathComponent("tpm.sock").path),mode=0600,terminate"]
                tpm.standardOutput = log; tpm.standardError = log
                self.tpm = tpm; try tpm.run()
                for _ in 0..<100 {
                    if FileManager.default.fileExists(atPath: runtime.appendingPathComponent("tpm.sock").path) { break }
                    guard tpm.isRunning else { throw VMError.message("TPM process failed. See Engine.log.") }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                guard FileManager.default.fileExists(atPath: runtime.appendingPathComponent("tpm.sock").path) else { throw VMError.message("TPM startup timed out.") }
                let process = Process(); process.executableURL = URL(fileURLWithPath: config.qemuPath)
                process.currentDirectoryURL = config.directory
                process.arguments = try config.arguments(runtime: runtime, embeddedDisplay: embeddedDisplay)
                process.standardOutput = log; process.standardError = log
                process.terminationHandler = { [weak self] child in
                    guard let owner = self else { return }
                    owner.queue.async { [weak self] in
                        guard let self = self, self.qemu === child else { return }
                        let status = child.terminationStatus
                        self.cleanup()
                        self.publish(status == 0 ? "Stopped" : "Failed", status == 0 ? "Windows is shut down." : "Engine exited (\(status)). See Engine.log.")
                    }
                }
                self.qemu = process; try process.run()
                for _ in 0..<100 {
                    if FileManager.default.fileExists(atPath: runtime.appendingPathComponent("qmp.sock").path) { break }
                    guard process.isRunning else { throw VMError.message("QEMU startup failed. See Engine.log.") }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                self.qmp = try QMPClient(socketURL: runtime.appendingPathComponent("qmp.sock"))
                self.stoppingAt = nil
                if embeddedDisplay {
                    let url = runtime.appendingPathComponent("display.sock")
                    DispatchQueue.main.async { displayReady?(url) }
                }
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: 2)
                timer.setEventHandler { [weak self] in self?.poll() }
                self.timer = timer; timer.resume()
            } catch {
                if let process = self.qemu, process.isRunning { process.terminate(); process.waitUntilExit() }
                self.cleanup(); self.publish("Failed", error.localizedDescription)
            }
        }
    }

    /// Read-only, app-owned media; no commands are executed in the guest.
    public func mountDisplayTools(_ url: URL, completion: @escaping (String?) -> Void) {
        queue.async { [self] in
            do {
                guard let qmp else {
                    DispatchQueue.main.async { completion("Windows is not running.") }; return
                }
                if displayToolsMounted { DispatchQueue.main.async { completion(nil) }; return }
                let lease = try ImageLease(url: url)
                try qmp.execute("blockdev-add", arguments: ["node-name": "display-tools", "driver": "raw", "read-only": true,
                    "file": ["driver": "file", "filename": url.path]])
                do {
                    try qmp.execute("device_add", arguments: ["driver": "usb-bot", "bus": "usb.0", "id": "display-tools-usb", "attached": false])
                    try qmp.execute("device_add", arguments: ["driver": "scsi-cd", "bus": "display-tools-usb.0", "drive": "display-tools", "id": "display-tools-cd"])
                    // Attach only after its CD LUN exists, so Windows does not enumerate an empty bridge.
                    try qmp.execute("qom-set", arguments: ["path": "/machine/peripheral/display-tools-usb", "property": "attached", "value": true])
                } catch {
                    _ = try? qmp.execute("device_del", arguments: ["id": "display-tools-usb"])
                    _ = try? qmp.execute("blockdev-del", arguments: ["node-name": "display-tools"])
                    throw error
                }
                imageLeases.append(lease); displayToolsMounted = true
                DispatchQueue.main.async { completion(nil) }
            } catch { DispatchQueue.main.async { completion(error.localizedDescription) } }
        }
    }

    public func perform(_ action: Action) {
        queue.async {
            do {
                guard let qmp = self.qmp else { throw VMError.message("Windows is not running.") }
                switch action {
                case .pause: try qmp.execute("stop")
                case .resume: try qmp.execute("cont")
                case .shutdown:
                    let status = try qmp.execute("query-status") as? [String: Any]
                    if status?["running"] as? Bool == false { try qmp.execute("cont") }
                    try qmp.execute("system_powerdown"); self.stoppingAt = Date()
                    self.publish("Stopping", "Waiting for Windows to shut down…")
                case .forceStop: try qmp.execute("quit"); return
                }
                self.poll()
            } catch { self.publish("Error", error.localizedDescription) }
        }
    }

    private func poll() {
        guard let qmp = qmp, qemu?.isRunning == true else { return }
        do {
            let status = try qmp.execute("query-status") as? [String: Any]
            if status?["status"] as? String == "io-error" {
                stoppingAt = nil
                publish("IOError", "Windows paused after a storage error. Check free space on the VM's drive and Engine.log, then resume after resolving the problem.")
                return
            }
            if let date = stoppingAt {
                if Date().timeIntervalSince(date) > 45 {
                    stoppingAt = nil
                    publish(status?["running"] as? Bool == true ? "Running" : "Paused", "Shutdown timed out. Use Windows’ power menu or choose Force Stop.")
                } else { publish("Stopping", "Waiting for Windows to shut down…") }
            } else {
                let running = status?["running"] as? Bool == true
                publish(running ? "Running" : "Paused", running ? "Windows is running." : "Windows is paused.")
            }
        } catch {
            if qemu?.isRunning == true { publish("Error", error.localizedDescription) }
        }
    }

    private func publish(_ phase: String, _ message: String) {
        NSLog("Windows prototype %@: %@", phase, message)
        DispatchQueue.main.async { self.update?(phase, message) }
    }
    private func cleanup() {
        timer?.cancel(); timer = nil; qmp?.close(); qmp = nil; qemu = nil
        if let tpm = tpm, tpm.isRunning { tpm.terminate(); tpm.waitUntilExit() }
        tpm = nil; stoppingAt = nil
        if let runtime = runtime { try? FileManager.default.removeItem(at: runtime) }
        runtime = nil; imageLeases = []; displayToolsMounted = false; lock = nil
    }
}
