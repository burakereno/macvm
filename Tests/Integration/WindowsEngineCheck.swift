import Foundation
import WindowsPrototypeCore

@main
struct WindowsEngineCheck {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
    static func run() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/tmp/mvw-engine-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        var config = WindowsConfiguration(directory: root)
        config.cpuCount = 2; config.memoryGB = 4
        config.toolsPath = fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/MacVM-Windows-Drivers-0.1.273.iso").path
        let engine = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacVM/Engines/Windows Prototype")
        config.firmwarePath = engine.appendingPathComponent("edk2-aarch64-secure-code.fd").path
        let disk = Process(); disk.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/qemu-img")
        disk.arguments = ["create", "-f", "qcow2", config.diskURL.path, "128G"]
        try disk.run(); disk.waitUntilExit(); try require(disk.terminationStatus == 0, "Disk preparation failed")
        let variables = Process(); variables.executableURL = disk.executableURL
        variables.arguments = ["convert", "-O", "raw", engine.appendingPathComponent("edk2-arm-secure-vars.fd").path, config.variablesURL.path]
        try variables.run(); variables.waitUntilExit(); try require(variables.terminationStatus == 0, "Firmware variable conversion failed")
        try fm.createDirectory(at: root.appendingPathComponent("TPM"), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let tpm = Process(); tpm.executableURL = URL(fileURLWithPath: config.swtpmPath); tpm.currentDirectoryURL = root
        tpm.arguments = ["socket", "--tpm2", "--tpmstate", "dir=TPM,mode=0600,lock", "--ctrl", "type=unixio,path=\(root.appendingPathComponent("tpm.sock").path),mode=0600,terminate"]
        try tpm.run()
        defer { if tpm.isRunning { tpm.terminate(); tpm.waitUntilExit() } }
        try waitFor(root.appendingPathComponent("tpm.sock"), process: tpm)
        let qemu = Process(); qemu.executableURL = URL(fileURLWithPath: config.qemuPath)
        var arguments = try config.arguments(runtime: root)
        arguments[arguments.firstIndex(of: "-display")! + 1] = "none"
        arguments.append("-S")
        qemu.arguments = arguments; try qemu.run()
        defer { if qemu.isRunning { qemu.terminate(); qemu.waitUntilExit() } }
        try waitFor(root.appendingPathComponent("qmp.sock"), process: qemu)
        let qmp = try QMPClient(socketURL: root.appendingPathComponent("qmp.sock"))
        let initial = try qmp.execute("query-status") as! [String: Any]
        try require(initial["running"] as? Bool == false, "Engine was not initially paused")
        let cpus = try qmp.execute("query-cpus-fast") as! [[String: Any]]
        try require(cpus.count == 2, "Incorrect CPU count")
        let tpms = try qmp.execute("query-tpm") as! [[String: Any]]
        try require(tpms.count == 1 && tpms[0]["model"] as? String == "tpm-tis", "TPM was not enumerated")
        let blocks = try qmp.execute("query-block") as! [[String: Any]]
        try require(blocks.contains { ($0["removable"] as? Bool == true) && ($0["tray_open"] as? Bool == false) }, "CD-ROM tray was not closed")
        try qmp.execute("cont")
        let running = try qmp.execute("query-status") as! [String: Any]
        try require(running["running"] as? Bool == true, "Engine did not resume")
        try qmp.execute("stop")
        let paused = try qmp.execute("query-status") as! [String: Any]
        try require(paused["running"] as? Bool == false, "Engine did not pause")
        try qmp.execute("quit"); qemu.waitUntilExit(); try require(qemu.terminationStatus == 0, "Engine did not exit cleanly")
        print("PASS: real QEMU/HVF, 2 CPUs, TPM2, QMP pause/resume and clean engine exit.")
    }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "WindowsEngineCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func waitFor(_ file: URL, process: Process) throws {
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: file.path) { return }
            guard process.isRunning else { throw NSError(domain: "WindowsEngineCheck", code: Int(process.terminationStatus)) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw NSError(domain: "WindowsEngineCheckTimeout", code: 1)
    }
}
