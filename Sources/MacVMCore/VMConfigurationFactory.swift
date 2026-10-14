import Foundation
import Virtualization

public enum VMConfigurationFactory {
    public static func writeNewMachineIdentifier(to directory: URL, system: GuestSystem) throws {
        if system == .macOS {
            try VZMacMachineIdentifier().dataRepresentation.write(to: directory.appendingPathComponent("MachineIdentifier"), options: .atomic)
        }
    }

    public static func prepareMac(at directory: URL, restoreImage: VZMacOSRestoreImage) throws {
        guard let requirements = restoreImage.mostFeaturefulSupportedConfiguration else {
            throw VMError.message("This macOS image is not supported by this Mac. Choose a compatible IPSW or download from Apple.")
        }
        var record = try VirtualMachineRecord.load(from: directory)
        guard record.cpuCount >= requirements.minimumSupportedCPUCount,
              UInt64(record.memoryGB) * VMStorage.gib >= requirements.minimumSupportedMemorySize else {
            throw VMError.message("This macOS version needs at least \(requirements.minimumSupportedCPUCount) CPUs and \(requirements.minimumSupportedMemorySize / VMStorage.gib) GB of memory.")
        }
        record.osVersion = "macOS \(restoreImage.operatingSystemVersion.majorVersion).\(restoreImage.operatingSystemVersion.minorVersion).\(restoreImage.operatingSystemVersion.patchVersion)"
        try requirements.hardwareModel.dataRepresentation.write(to: directory.appendingPathComponent("HardwareModel"), options: .atomic)
        try writeNewMachineIdentifier(to: directory, system: .macOS)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: directory.appendingPathComponent("AuxiliaryStorage"), hardwareModel: requirements.hardwareModel, options: [])
        try record.save(to: directory)
    }

    public static func prepareLinux(at directory: URL) throws {
        _ = try VZEFIVariableStore(creatingVariableStoreAt: directory.appendingPathComponent("EFI.nvram"))
    }

    public static func make(record: VirtualMachineRecord, directory: URL, guestToolsURL: URL? = nil) throws -> VZVirtualMachineConfiguration {
        guard record.system != .windows else { throw VMError.message("Windows uses the Windows engine.") }
        guard VZVirtualMachine.isSupported else { throw VMError.message("Virtualization is not available on this Mac.") }
        try VMStorage.validate(record)
        let configuration = VZVirtualMachineConfiguration()
        configuration.cpuCount = record.cpuCount
        configuration.memorySize = UInt64(record.memoryGB) * VMStorage.gib

        if record.system == .macOS {
            let platform = VZMacPlatformConfiguration()
            guard let model = VZMacHardwareModel(dataRepresentation: try Data(contentsOf: directory.appendingPathComponent("HardwareModel"))), model.isSupported,
                  let identifier = VZMacMachineIdentifier(dataRepresentation: try Data(contentsOf: directory.appendingPathComponent("MachineIdentifier"))) else {
                throw VMError.message("This machine’s virtual hardware is not supported by this Mac.")
            }
            platform.hardwareModel = model; platform.machineIdentifier = identifier
            platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: directory.appendingPathComponent("AuxiliaryStorage"))
            configuration.platform = platform
            configuration.bootLoader = VZMacOSBootLoader()
            let graphics = VZMacGraphicsDeviceConfiguration()
            graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 144)]
            configuration.graphicsDevices = [graphics]
            configuration.keyboards = [VZMacKeyboardConfiguration()]
            configuration.pointingDevices = [VZMacTrackpadConfiguration()]
            configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        } else {
            configuration.platform = VZGenericPlatformConfiguration()
            let bootLoader = VZEFIBootLoader()
            bootLoader.variableStore = VZEFIVariableStore(url: directory.appendingPathComponent("EFI.nvram"))
            configuration.bootLoader = bootLoader
            let graphics = VZVirtioGraphicsDeviceConfiguration()
            graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1200)]
            configuration.graphicsDevices = [graphics]
            configuration.keyboards = [VZUSBKeyboardConfiguration()]
            configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
            configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
            configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
            if record.clipboardSharingEnabled == true {
                let console = VZVirtioConsoleDeviceConfiguration()
                let port = VZVirtioConsolePortConfiguration()
                port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
                let attachment = VZSpiceAgentPortAttachment(); attachment.sharesClipboard = true
                port.attachment = attachment
                console.ports[0] = port
                configuration.consoleDevices = [console]
            }
        }

        if !record.installationPending {
            var directories: [String: VZSharedDirectory] = [:]
            for folder in record.sharedFolders ?? [] {
                let url = URL(fileURLWithPath: folder.path)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw VMError.message("Shared folder ‘\(folder.name)’ is unavailable. Reconnect its drive or remove the folder in machine settings.")
                }
                directories[folder.name] = VZSharedDirectory(url: url, readOnly: folder.readOnly)
            }
            if record.system == .macOS, let guestToolsURL {
                directories["MacVM Guest Tools"] = VZSharedDirectory(url: guestToolsURL, readOnly: true)
            }
            if !directories.isEmpty {
                let share = VZVirtioFileSystemDeviceConfiguration(tag: record.system == .macOS ? VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag : "macvm-share")
                share.share = VZMultipleDirectoryShare(directories: directories)
                configuration.directorySharingDevices = [share]
            }
        }

        if record.system == .linux, record.ubuntuSetup != nil {
            if record.ubuntuSetup?.completed == false || FileManager.default.fileExists(atPath: UbuntuProvisioning.folder(in: directory).path) {
                try UbuntuProvisioning.validateFolder(directory)
                let share = VZVirtioFileSystemDeviceConfiguration(tag: "macvm-setup")
                share.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: UbuntuProvisioning.folder(in: directory), readOnly: false))
                configuration.directorySharingDevices.append(share)
            }
        }

        // Linux virtio I/O can corrupt data with the uncached path chosen by .automatic.
        // Keep full flush guarantees while explicitly enabling host caching.
        // https://github.com/utmapp/UTM/issues/4840#issuecomment-1824340975
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: directory.appendingPathComponent("Disk.img"), readOnly: false, cachingMode: record.system == .linux ? .cached : .automatic, synchronizationMode: .full)
        let disk = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
        configuration.storageDevices = [disk]
        if record.ubuntuSetup?.completed == false {
            let seed = directory.appendingPathComponent("NoCloud.iso")
            let values = try seed.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw VMError.message("Ubuntu’s first-boot data is missing.") }
            let attachment = try VZDiskImageStorageDeviceAttachment(url: seed, readOnly: true, cachingMode: .cached, synchronizationMode: .full)
            configuration.storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
        }
        if record.system == .linux && record.bootFromInstaller {
            let iso = directory.appendingPathComponent("Installer.iso")
            guard FileManager.default.fileExists(atPath: iso.path) else { throw VMError.message("The installer ISO is missing. Turn off ‘Boot from installer’ in machine settings to boot the disk.") }
            let attachment = try VZDiskImageStorageDeviceAttachment(url: iso, readOnly: true, cachingMode: .cached, synchronizationMode: .full)
            configuration.storageDevices.insert(VZUSBMassStorageDeviceConfiguration(attachment: attachment), at: 0)
        }
        if record.networkEnabled {
            let network = VZVirtioNetworkDeviceConfiguration()
            network.attachment = VZNATNetworkDeviceAttachment()
            guard let address = VZMACAddress(string: record.macAddress) else { throw VMError.message("Invalid network address in this machine’s configuration.") }
            network.macAddress = address
            configuration.networkDevices = [network]
        }
        let sound = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        sound.streams = [output]
        configuration.audioDevices = [sound]
        try configuration.validate()
        return configuration
    }
}
