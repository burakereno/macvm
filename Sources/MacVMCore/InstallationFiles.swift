import Foundation
import Darwin
import CryptoKit

public struct InstallationFile: Identifiable, Equatable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let bytes: Int64
    public let machineName: String?
    public let blocker: String?
}

/// The same lease is held while downloading, preparing, restoring or removing
/// an image. Locks live outside the image folders and survive process crashes.
public final class ImageLease {
    private let descriptor: Int32
    public init(url: URL) throws {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacVM/Image Locks")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let hash = SHA256.hash(data: Data(url.standardizedFileURL.resolvingSymlinksInPath().path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let fd = open(root.appendingPathComponent(hash).path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw VMError.message("Cannot lock this installation file.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw VMError.message("This installation file is in use. Try again after the operation finishes.")
        }
        descriptor = fd
    }
    deinit { close(descriptor) }
    public static func isHeld(at url: URL) -> Bool {
        do { let lease = try ImageLease(url: url); withExtendedLifetime(lease) {}; return false }
        catch { return true }
    }
}

public enum InstallationFiles {
    public static var downloads: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
    private static func isInstaller(_ url: URL) -> Bool {
        ["iso", "ipsw"].contains(url.pathExtension.lowercased()) ||
        (url.lastPathComponent.hasPrefix("MacVM-macOS-") && url.lastPathComponent.hasSuffix(".ipsw.download")) ||
        (url.lastPathComponent.hasPrefix("MacVM-Windows-") && url.lastPathComponent.hasSuffix(".iso.download")) ||
        url.lastPathComponent.range(of: "^MacVM-Ubuntu-(24\\.04|26\\.04)-[a-f0-9]{12}-arm64\\.(img|tar\\.gz)(\\.download)?$", options: .regularExpression) != nil
    }

    public static func list(downloads: URL = Self.downloads, legacyCaches: [URL], entries: [VMEntry]) -> [InstallationFile] {
        var candidates = Set<URL>()
        for folder in [downloads] + legacyCaches {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            candidates.formUnion(files.filter { isInstaller($0) }.map(\.standardizedFileURL))
        }
        for entry in entries {
            if entry.record.system != .macOS { candidates.insert(entry.url.appendingPathComponent("Installer.iso").standardizedFileURL) }
            for path in [entry.record.restoreImagePath, entry.record.sourceImagePath].compactMap({ $0 }) {
                candidates.insert(URL(fileURLWithPath: path).standardizedFileURL)
            }
        }
        return candidates.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  isInstaller(url) else { return nil }
            let owner = entries.first { $0.url.appendingPathComponent("Installer.iso").standardizedFileURL == url }
            return InstallationFile(url: url, bytes: Int64(values.fileSize ?? 0), machineName: owner?.record.name,
                                    blocker: deletionBlocker(url, entries: entries))
        }.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    public static func deletionBlocker(_ url: URL, entries: [VMEntry]) -> String? {
        for entry in entries {
            let record = entry.record
            if record.installationPending, let path = record.restoreImagePath,
               URL(fileURLWithPath: path).standardizedFileURL == url.standardizedFileURL {
                return "Needed to finish installing \(record.name)."
            }
            if entry.url.appendingPathComponent("Installer.iso").standardizedFileURL == url.standardizedFileURL {
                if VMLock.isHeld(at: entry.url) { return "Shut down \(record.name) before removing its installer." }
                if record.bootFromInstaller { return "Eject the installer in \(record.name)’s settings first." }
            }
        }
        let leasedURL = url.pathExtension == "download" ? url.deletingPathExtension() : url
        return ImageLease.isHeld(at: leasedURL) ? "This file is being downloaded or used for installation." : nil
    }

    /// Injectable Trash operation lets tests verify protection without touching
    /// the user's real Trash. Never accepts a VM disk or a symlink.
    public static func moveToTrash(_ url: URL, entries: [VMEntry], trash: (URL) throws -> Void = {
        try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard isInstaller(url),
              values.isRegularFile == true, values.isSymbolicLink != true else {
            throw VMError.message("Choose a regular ISO, IPSW or managed Ubuntu installation file.")
        }
        let package = entries.first { $0.url.appendingPathComponent("Installer.iso").standardizedFileURL == url.standardizedFileURL }
        let vmLock = try package.map { try VMLock(directory: $0.url) }
        defer { withExtendedLifetime(vmLock) {} }
        let fresh = try entries.map { VMEntry(record: try VirtualMachineRecord.load(from: $0.url), url: $0.url) }
        // The lock above belongs to this operation; inspect media state directly.
        if fresh.contains(where: { entry in
            (entry.record.installationPending && entry.record.restoreImagePath == url.path) ||
            (entry.url.appendingPathComponent("Installer.iso").standardizedFileURL == url.standardizedFileURL && entry.record.bootFromInstaller)
        }) { throw VMError.message("This installer is still needed. Finish installation and eject it first.") }
        let lease = try ImageLease(url: url.pathExtension == "download" ? url.deletingPathExtension() : url)
        defer { withExtendedLifetime(lease) {} }
        try trash(url)
        if url.pathExtension == "download" { try? FileManager.default.removeItem(at: url.appendingPathExtension("json")) }
    }
}
