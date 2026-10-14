import Foundation
import Observation
import Virtualization
import MacVMCore
import WindowsPrototypeCore

@MainActor @Observable
final class MachineCreator {
    var isWorking = false
    var progress: Double?
    var stage = ""
    var errorMessage: String?
    private var task: Task<Void, Never>?

    func cancel() { task?.cancel() }

    func createWindows(record: VirtualMachineRecord, location: URL, imageURL: URL?, downloadURL: URL?, checksum: String,
                       completion: @escaping (VMEntry) -> Void) {
        guard !isWorking else { return }
        isWorking = true; errorMessage = nil; progress = nil
        task = Task { [self] in
            var lease: ImageLease?
            defer { withExtendedLifetime(lease) {} }
            do {
                guard let resources = Bundle.main.url(forResource: "MacVMRunner", withExtension: "app", subdirectory: "Helpers") else { throw VMError.message("Windows support is missing. Reinstall MacVM.") }
                let engine = resources.appendingPathComponent("Contents/Resources/WindowsEngine")
                var selected = imageURL
                if let downloadURL {
                    try WindowsMachinePreparation.validateDownloadURL(downloadURL)
                    let downloads = InstallationFiles.downloads
                    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
                    let base = downloadURL.deletingPathExtension().lastPathComponent.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                    let iso = downloads.appendingPathComponent("MacVM-Windows-" + String(base.prefix(100)) + ".iso")
                    lease = try ImageLease(url: iso)
                    if !FileManager.default.fileExists(atPath: iso.path) {
                        let a = (try? location.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
                        let b = (try? downloads.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
                        let downloader = ImageDownloader(destination: iso.appendingPathExtension("download"),
                            requiredRemainingSpace: a == b ? WindowsMachinePreparation.requiredFreeBytes : 2 * VMStorage.gib,
                            allowedHosts: Set(WindowsMachinePreparation.downloadHosts)) { [weak self] value, bytes in
                            Task { @MainActor in self?.progress = value; self?.stage = "Downloading Windows to Downloads · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
                        }
                        stage = "Downloading Windows to Downloads…"
                        let partial = try await downloader.download(downloadURL)
                        try Task.checkCancellation()
                        try FileManager.default.moveItem(at: partial, to: iso)
                        try? FileManager.default.removeItem(at: partial.appendingPathExtension("json"))
                    }
                    selected = iso
                }
                guard let iso = selected else { throw VMError.message("Choose a Windows ARM64 ISO.") }
                if lease == nil { lease = try ImageLease(url: iso) }
                stage = "Checking ARM64 media and preparing the disk and TPM…"; progress = nil
                let preparing = Task.detached(priority: .userInitiated) {
                    try WindowsMachinePreparation.prepare(record: record, location: location, iso: iso, engine: engine, expectedSHA256: checksum)
                }
                let entry = try await withTaskCancellationHandler { try await preparing.value } onCancel: { preparing.cancel() }
                isWorking = false; task = nil; completion(entry)
            } catch {
                isWorking = false; task = nil
                errorMessage = Task.isCancelled ? "Creation cancelled. Partial downloads remain in Downloads and can be resumed or removed in Installation Files." : error.localizedDescription
            }
        }
    }

    func createUbuntu(record: VirtualMachineRecord, location: URL, password: String, sshPublicKey: String?,
                      completion: @escaping (VMEntry) -> Void) {
        guard !isWorking else { return }
        isWorking = true; errorMessage = nil; progress = nil
        task = Task { [self] in
            var lease: ImageLease?
            defer { withExtendedLifetime(lease) {} }
            do {
                try VMStorage.validate(record)
                guard let setup = record.ubuntuSetup else { throw VMError.message("Choose an Ubuntu profile.") }
                if let problem = UbuntuMachinePreparation.spaceProblem(setup: setup, location: location) { throw VMError.message(problem) }
                stage = "Preparing the account…"
                let hashing = Task.detached(priority: .userInitiated) { try SHA512Crypt.hash(password: password) }
                let hash = try await withTaskCancellationHandler { try await hashing.value } onCancel: { hashing.cancel() }
                stage = "Finding the official Ubuntu ARM64 image…"
                let image = try await UbuntuImageCatalog.resolve(setup.release)
                try Task.checkCancellation()
                let downloads = InstallationFiles.downloads
                try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
                let archive = downloads.appendingPathComponent(image.managedName)
                lease = try ImageLease(url: archive)
                if !FileManager.default.fileExists(atPath: archive.path) {
                    let partial = archive.appendingPathExtension("download")
                    let volume = (try? location.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
                    let downloadVolume = (try? downloads.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
                    let reserve = volume == downloadVolume ? setup.requiredFreeBytes : 2 * VMStorage.gib
                    let downloader = ImageDownloader(destination: partial, requiredRemainingSpace: reserve) { [weak self] value, bytes in
                        Task { @MainActor in
                            self?.progress = value
                            self?.stage = "Downloading Ubuntu to Downloads · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                        }
                    }
                    let downloaded = try await downloader.download(image.url)
                    try Task.checkCancellation()
                    try FileManager.default.moveItem(at: downloaded, to: archive)
                    try? FileManager.default.removeItem(at: partial.appendingPathExtension("json"))
                }
                stage = "Verifying Ubuntu and preparing its disk…"; progress = nil
                let preparing = Task.detached(priority: .userInitiated) {
                    try UbuntuMachinePreparation.prepare(record: record, location: location, image: image,
                                                         archive: archive, passwordHash: hash, sshPublicKey: sshPublicKey)
                }
                let entry = try await withTaskCancellationHandler { try await preparing.value } onCancel: { preparing.cancel() }
                isWorking = false; task = nil
                completion(entry)
            } catch {
                isWorking = false; task = nil
                errorMessage = Task.isCancelled ? "Creation cancelled. Partial downloads stay in Downloads; Create resumes a supported download." : error.localizedDescription
            }
        }
    }

    func create(record initialRecord: VirtualMachineRecord, location: URL, imageURL: URL?, downloadMacOS: Bool,
                completion: @escaping (VMEntry) -> Void) {
        guard !isWorking else { return }
        isWorking = true; errorMessage = nil; progress = nil
        task = Task { [self] in
            var directory: URL?
            var partial: URL?
            var imageLease: ImageLease?
            defer { withExtendedLifetime(imageLease) {} }
            do {
                var record = initialRecord
                try VMStorage.validate(record)
                if let problem = InstallationSpace.problem(system: record.system, downloading: downloadMacOS, location: location) {
                    throw VMError.message(problem)
                }
                var selectedImage = imageURL
                if record.system == .macOS && downloadMacOS {
                    stage = "Finding the latest compatible macOS…"
                    let remote = try await VZMacOSRestoreImage.latestSupported
                    try Task.checkCancellation()
                    let cache = InstallationFiles.downloads
                    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                    let finalURL = cache.appendingPathComponent("MacVM-macOS-" + remote.buildVersion + ".ipsw")
                    imageLease = try ImageLease(url: finalURL)
                    if FileManager.default.fileExists(atPath: finalURL.path) {
                        selectedImage = finalURL
                    } else {
                        let temporary = finalURL.appendingPathExtension("download")
                        partial = temporary
                        stage = "Downloading macOS from Apple…"
                        let vmVolume = (try? location.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
                        let downloadVolume = (try? cache.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
                        let reserve: UInt64 = vmVolume == downloadVolume ? 64 * VMStorage.gib : 2 * VMStorage.gib
                        let downloader = ImageDownloader(destination: temporary, requiredRemainingSpace: reserve) { [weak self] value, bytes in
                            Task { @MainActor in
                                self?.progress = value
                                self?.stage = "Downloading macOS · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                            }
                        }
                        let downloaded = try await downloader.download(remote.url)
                        try Task.checkCancellation()
                        try FileManager.default.moveItem(at: downloaded, to: finalURL)
                        try? FileManager.default.removeItem(at: temporary.appendingPathExtension("json"))
                        partial = nil; selectedImage = finalURL
                    }
                }
                guard let selectedImage else { throw VMError.message("Choose an installation image first.") }
                if imageLease == nil { imageLease = try ImageLease(url: selectedImage) }
                record.sourceImagePath = selectedImage.path
                record.guestBrand = GuestBrand.infer(system: record.system, sourceImagePath: selectedImage.path,
                    osVersion: record.osVersion, name: record.name).rawValue
                if let problem = InstallationSpace.problem(system: record.system, downloading: false, location: location) { throw VMError.message(problem) }
                try Task.checkCancellation()
                stage = "Preparing your virtual machine…"; progress = nil
                var macImage: VZMacOSRestoreImage?
                if record.system == .macOS {
                    macImage = try await VZMacOSRestoreImage.image(from: selectedImage)
                    record.restoreImagePath = selectedImage.path
                }
                let bundle = try VMStorage.createEmptyBundle(record: record, location: location, staging: true)
                directory = bundle
                if let macImage {
                    try VMConfigurationFactory.prepareMac(at: bundle, restoreImage: macImage)
                } else {
                    stage = "Copying the Linux installer…"
                    let imageBytes = (try selectedImage.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                    guard VMStorage.availableBytes(at: location) >= UInt64(max(0, imageBytes)) + 12 * VMStorage.gib else {
                        throw VMError.message("The machine location needs room for the ISO copy plus at least 12 GB for Linux.")
                    }
                    try await Task.detached(priority: .userInitiated) {
                        try FileManager.default.copyItem(at: selectedImage, to: bundle.appendingPathComponent("Installer.iso"))
                    }.value
                    try VMConfigurationFactory.prepareLinux(at: bundle)
                }
                try Task.checkCancellation()
                let saved = try VirtualMachineRecord.load(from: bundle)
                _ = try VMConfigurationFactory.make(record: saved, directory: bundle)
                let published = location.appendingPathComponent(record.id.uuidString).appendingPathExtension("macvm")
                try FileManager.default.moveItem(at: bundle, to: published)
                directory = nil
                isWorking = false
                completion(VMEntry(record: saved, url: published))
            } catch {
                if let directory { try? FileManager.default.removeItem(at: directory) }
                isWorking = false
                if Task.isCancelled, partial != nil { errorMessage = "Download paused in Downloads. Choose Create again to resume, or remove it in Installation Files." }
                else if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }
}
