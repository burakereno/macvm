import Foundation
import MacVMCore

/// Engine paths are app-owned and are never accepted from imported VM packages.
public struct WindowsConfiguration: Codable, Equatable, Sendable {
    public var directory: URL
    public var name = "Windows 11 ARM Prototype"
    public var cpuCount = 4
    public var memoryGB = 8
    public var diskGB = 128
    public var qemuPath = "/opt/homebrew/bin/qemu-system-aarch64"
    public var swtpmPath = "/opt/homebrew/bin/swtpm"
    public var firmwarePath = "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
    public var dataPath: String?
    public var audioEnabled: Bool?
    public var automaticDisplay: Bool?
    public var installerPath: String?
    public var toolsPath: String?
    public var networkEnabled: Bool?
    public var macAddress: String?

    public init(directory: URL) { self.directory = directory }
    public var diskURL: URL { directory.appendingPathComponent("Disk.qcow2") }
    public var variablesURL: URL { directory.appendingPathComponent("EFI.fd") }
    public var configURL: URL { directory.appendingPathComponent("Prototype.json") }

    public func save() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: configURL, options: .atomic)
    }

    public static func load(directory: URL) throws -> Self {
        var value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: directory.appendingPathComponent("Prototype.json")))
        value.directory = directory
        return value
    }

    public func arguments(runtime: URL, embeddedDisplay: Bool = false) throws -> [String] {
        guard (2...16).contains(cpuCount), (4...64).contains(memoryGB), (64...512).contains(diskGB) else {
            throw VMError.message("Windows requires 2–16 CPUs, 4–64 GB RAM and a 64–512 GB disk.")
        }
        guard runtime.path.utf8.count < 80, !runtime.path.contains(","), !runtime.path.contains("\n") else {
            throw VMError.message("The private Windows runtime socket path is invalid.")
        }
        // Setup needs the firmware framebuffer. Keep it for recovery too;
        // Display Tools disables Windows' duplicate Basic Display fallback
        // only after verifying the installed VirtIO driver is healthy.
        let gpu = "virtio-gpu-pci,id=gpu,xres=2560,yres=1600"
        let automatic = automaticDisplay ?? (installerPath == nil)
        let framebuffer = "ramfb,id=setup-display"
        let displays = automatic
            ? ["-device", gpu, "-device", framebuffer]
            : ["-device", framebuffer, "-device", gpu]
        // This VM uses PCI VirtIO devices. Exposing the board's 32 empty
        // MMIO transports produces unsupported LNRO0005 devices in Windows.
        var args = ["-name", name, "-L", dataPath ?? URL(fileURLWithPath: firmwarePath).deletingLastPathComponent().path, "-machine", "virt,gic-version=3,virtio-mmio-transports=0,pflash0=firmware,pflash1=efivars", "-accel", "hvf", "-cpu", "host",
                    "-smp", String(cpuCount), "-m", String(memoryGB * 1024), "-nodefaults",
                    "-display", embeddedDisplay ? "none" : "cocoa", "-rtc", "base=localtime", "-boot", "menu=on",
                    "-qmp", "unix:\(runtime.appendingPathComponent("qmp.sock").path),server=on,wait=off",
                    "-chardev", "socket,id=chrtpm,path=\(runtime.appendingPathComponent("tpm.sock").path)",
                    // QEMU 11.1.2's ARM PPI RAM region is not aligned to the
                    // 16 KiB HVF host page: hv_vm_unmap fails at startup.
                    // Disable only PPI; the TPM2 device remains present.
                    "-tpmdev", "emulator,id=tpm0,chardev=chrtpm", "-device", "tpm-tis-device,tpmdev=tpm0,ppi=off",
                    "-device", "qemu-xhci,id=usb", "-device", "usb-kbd,bus=usb.0", "-device", "usb-tablet,bus=usb.0"] + displays + [
                    "-blockdev", try block(name: "firmware", path: firmwarePath, format: "raw", readOnly: true),
                    "-blockdev", try block(name: "efivars", path: variablesURL.path, format: "raw", readOnly: false),
                    "-blockdev", try block(name: "disk", path: diskURL.path, format: "qcow2", readOnly: false),
                    "-device", "nvme,drive=disk,serial=MACVMWIN11,bootindex=0"]
        // Preserve PCI slot order from the installed prototype: USB, GPU, NIC, NVMe.
        let diskIndex = args.firstIndex(of: "-blockdev")!
        let address = macAddress ?? "02:4d:56:57:11:01"
        guard address.range(of: "^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$", options: .regularExpression) != nil else { throw VMError.message("Invalid Windows network address.") }
        if networkEnabled != false {
            args.insert(contentsOf: ["-netdev", "user,id=net0", "-device", "virtio-net-pci,netdev=net0,mac=\(address),romfile="], at: diskIndex)
        } else {
            args.insert(contentsOf: ["-device", "virtio-net-pci,mac=\(address),romfile="], at: diskIndex)
        }
        if embeddedDisplay {
            // Device realization order can differ from argument order. Bind
            // the viewer to its intended monitor instead of QEMU's default.
            let monitor = automatic ? "gpu" : "setup-display"
            args += ["-vnc", "unix:\(runtime.appendingPathComponent("display.sock").path),display=\(monitor)"]
        }
        if audioEnabled == true {
            args += ["-audiodev", "coreaudio,id=audio0", "-device", "intel-hda,id=hda0",
                     "-device", "hda-output,audiodev=audio0"]
        }
        if embeddedDisplay {
            args += ["-device", "virtio-serial-pci,id=macvm-serial",
                     "-chardev", "socket,id=agent,path=\(runtime.appendingPathComponent("agent.sock").path),server=on,wait=off",
                     "-device", "virtserialport,bus=macvm-serial.0,chardev=agent,name=com.redhat.spice.0",
                     "-chardev", "socket,id=webdav,path=\(runtime.appendingPathComponent("webdav.sock").path),server=on,wait=off",
                     "-device", "virtserialport,bus=macvm-serial.0,chardev=webdav,name=org.spice-space.webdav.0"]
        }
        for (path, name, index) in [(installerPath, "install", 1), (toolsPath, "tools", 2)] {
            if let path = path {
                args += ["-blockdev", try block(name: name, path: path, format: "raw", readOnly: true),
                         "-device", "usb-bot,bus=usb.0,id=\(name)-usb",
                         "-device", "scsi-cd,bus=\(name)-usb.0,drive=\(name),id=\(name)-cd,bootindex=\(index)"]
            }
        }
        return args
    }

    /// Engine executables and firmware come from the app, never an imported package.
    public static func installed(record: VirtualMachineRecord, directory: URL, resources: URL) throws -> Self {
        guard record.system == .windows else { throw VMError.message("This is not a Windows machine.") }
        try VMStorage.validate(record)
        var value = Self(directory: directory)
        value.name = record.name; value.cpuCount = record.cpuCount; value.memoryGB = record.memoryGB; value.diskGB = record.diskGB
        value.qemuPath = resources.appendingPathComponent("WindowsEngine/MacVMWindowsEngine").path
        value.swtpmPath = resources.appendingPathComponent("WindowsEngine/swtpm").path
        value.firmwarePath = resources.appendingPathComponent("WindowsEngine/edk2-aarch64-secure-code.fd").path
        value.dataPath = resources.appendingPathComponent("WindowsEngine").path
        value.audioEnabled = record.audioEnabled ?? true
        value.automaticDisplay = record.windowsAutomaticDisplay
        value.networkEnabled = record.networkEnabled; value.macAddress = record.macAddress
        if record.bootFromInstaller {
            value.installerPath = directory.appendingPathComponent("Installer.iso").path
            value.toolsPath = resources.appendingPathComponent("WindowsEngine/DisplayTools.iso").path
        }
        for path in [value.qemuPath, value.swtpmPath, value.firmwarePath,
                     resources.appendingPathComponent("WindowsEngine/keymaps/en-us").path] {
            guard FileManager.default.fileExists(atPath: path) else { throw VMError.message("The Windows engine is unavailable in this build of MacVM.") }
        }
        return value
    }

    private func block(name: String, path: String, format: String, readOnly: Bool) throws -> String {
        let value: [String: Any] = ["driver": format, "node-name": name, "read-only": readOnly,
                                  "file": ["driver": "file", "filename": path]]
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}
