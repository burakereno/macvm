import Foundation

/// Presentation identity is separate from the supported virtualization backend.
public enum GuestBrand: String, Sendable {
    case macOS, ubuntu, windows, linux

    public var title: String {
        switch self {
        case .macOS: "macOS"
        case .ubuntu: "Ubuntu"
        case .windows: "Windows"
        case .linux: "Linux"
        }
    }

    public static func infer(system: GuestSystem, sourceImagePath: String?, osVersion: String?, name: String) -> Self {
        if system == .macOS { return .macOS }
        if system == .windows { return .windows }
        // The installer's filename is more reliable than a user-selected VM name.
        let candidates = [sourceImagePath.map { URL(fileURLWithPath: $0).lastPathComponent }, osVersion, name]
        for candidate in candidates.compactMap({ $0 }) {
            let words = candidate.lowercased().split { !$0.isLetter && !$0.isNumber }
            if words.contains(where: { isVersionedWord($0, prefix: "ubuntu") }) { return .ubuntu }
            if words.contains(where: { isVersionedWord($0, prefix: "windows") || ["win10", "win11"].contains(String($0)) }) { return .windows }
        }
        return .linux
    }

    private static func isVersionedWord(_ word: Substring, prefix: String) -> Bool {
        guard word.hasPrefix(prefix) else { return false }
        return word.dropFirst(prefix.count).allSatisfy(\.isNumber)
    }
}

extension VirtualMachineRecord {
    public var displayBrand: GuestBrand {
        if system == .macOS { return .macOS }
        if system == .windows { return .windows }
        if let guestBrand, let brand = GuestBrand(rawValue: guestBrand), brand != .macOS { return brand }
        return GuestBrand.infer(system: system, sourceImagePath: sourceImagePath, osVersion: osVersion, name: name)
    }
}
