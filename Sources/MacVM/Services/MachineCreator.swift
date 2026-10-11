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
            do {
                var record = initialRecord
                try VMStorage.validate(record)
                let requiredGB = record.system == .macOS ? (downloadMacOS ? 90 : 64) : 12
                guard VMStorage.availableBytes(at: location) >= UInt64(requiredGB) * VMStorage.gib else {
                    throw VMError.message("This location needs at least \(requiredGB) GB free. Choose a location on another drive.")
                }
                var selectedImage = imageURL
                if record.system == .macOS && downloadMacOS {
                    stage = "Finding the latest compatible macOS…"
                    let remote = try await VZMacOSRestoreImage.latestSupported
                    try Task.checkCancellation()
                    let cache = location.appendingPathComponent("Base Images")
                    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                    let finalURL = cache.appendingPathComponent(remote.buildVersion + ".ipsw")
                    if FileManager.default.fileExists(atPath: finalURL.path) {
                        selectedImage = finalURL
                    } else {
                        let temporary = cache.appendingPathComponent(UUID().uuidString + ".download")
                        partial = temporary
                        stage = "Downloading macOS from Apple…"
                        let downloader = ImageDownloader(destination: temporary) { [weak self] value, bytes in
                            Task { @MainActor in
                                self?.progress = value
                                self?.stage = "Downloading macOS · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                            }
                        }
                        let downloaded = try await downloader.download(remote.url)
                        try Task.checkCancellation()
                        try FileManager.default.moveItem(at: downloaded, to: finalURL)
                        partial = nil; selectedImage = finalURL
                    }
                }
                guard let selectedImage else { throw VMError.message("Choose an installation image first.") }
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
                if let partial { try? FileManager.default.removeItem(at: partial) }
                isWorking = false
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }
}
