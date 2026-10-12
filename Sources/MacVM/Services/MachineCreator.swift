import Foundation
import Observation
import Virtualization
import MacVMCore

@MainActor @Observable
final class MachineCreator {
    var isWorking = false
    var progress: Double?
    var stage = ""
    var errorMessage: String?
    private var task: Task<Void, Never>?

    func cancel() { task?.cancel() }

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
