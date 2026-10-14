import Foundation

public enum UbuntuMachinePreparation {
    public static func spaceProblem(setup: UbuntuSetup, location: URL, downloading: Bool = true) -> String? {
        let downloads = InstallationFiles.downloads
        let required = setup.requiredFreeBytes
        let volume = (try? location.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        let downloadVolume = (try? downloads.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        if VMStorage.availableBytes(at: location) < required + (downloading && volume == downloadVolume ? 4 * VMStorage.gib : 0) {
            return "This Ubuntu profile needs at least \((required / VMStorage.gib) + (downloading && volume == downloadVolume ? 4 : 0)) GB free for preparation and installed packages. Add a location on another drive."
        }
        if downloading && VMStorage.availableBytes(at: downloads) < 4 * VMStorage.gib {
            return "Downloads needs at least 4 GB free for the Ubuntu image."
        }
        return nil
    }

    /// Publishes only a fully prepared machine; credentials are never stored in Config.json.
    public static func prepare(record initial: VirtualMachineRecord, location: URL, image: UbuntuImage,
                               archive: URL, passwordHash: String, sshPublicKey: String? = nil) throws -> VMEntry {
        var record = initial
        guard let setup = record.ubuntuSetup else { throw VMError.message("Choose an Ubuntu profile.") }
        record.bootFromInstaller = false; record.guestBrand = GuestBrand.ubuntu.rawValue
        record.osVersion = setup.release.title; record.sourceImagePath = archive.path
        try VMStorage.validate(record)
        if let problem = spaceProblem(setup: setup, location: location, downloading: false) { throw VMError.message(problem) }
        let directory = try VMStorage.createEmptyBundle(record: record, location: location, staging: true)
        do {
            try Task.checkCancellation()
            try image.prepareDisk(archive: archive, destination: directory.appendingPathComponent("Disk.img"), diskGB: record.diskGB)
            try VMConfigurationFactory.prepareLinux(at: directory)
            try UbuntuSeed.create(record: record, directory: directory, passwordHash: passwordHash, sshPublicKey: sshPublicKey)
            try Task.checkCancellation()
            _ = try VMConfigurationFactory.make(record: record, directory: directory)
            let published = location.appendingPathComponent(record.id.uuidString).appendingPathExtension("macvm")
            try FileManager.default.moveItem(at: directory, to: published)
            return VMEntry(record: record, url: published)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
