import Foundation

public enum InstallationSpace {
    public static func problem(system: GuestSystem, downloading: Bool, vmFree: UInt64,
                               downloadsFree: UInt64, sameVolume: Bool) -> String? {
        let vmRequired: UInt64 = (system == .macOS ? 64 : 12) * VMStorage.gib
        if system == .macOS && downloading {
            if sameVolume && vmFree < vmRequired + 32 * VMStorage.gib {
                return "This volume needs at least \(format(96 * VMStorage.gib)) free for the macOS download and installation."
            }
            if downloadsFree < 32 * VMStorage.gib { return "Downloads needs at least \(format(32 * VMStorage.gib)) free for the macOS image." }
        }
        return vmFree < vmRequired ? "The machine location needs at least \(format(vmRequired)) free for installation." : nil
    }
    private static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
    public static func problem(system: GuestSystem, downloading: Bool, location: URL) -> String? {
        let downloads = InstallationFiles.downloads
        let vmVolume = (try? location.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        let downloadVolume = (try? downloads.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        return problem(system: system, downloading: downloading, vmFree: VMStorage.availableBytes(at: location),
                       downloadsFree: VMStorage.availableBytes(at: downloads),
                       sameVolume: vmVolume == nil || downloadVolume == nil || vmVolume == downloadVolume)
    }
}
