import Foundation

public enum UbuntuRelease: String, Codable, CaseIterable, Identifiable, Sendable {
    case resolute, noble
    public var id: String { rawValue }
    public var version: String { self == .resolute ? "26.04" : "24.04" }
    public var title: String { "Ubuntu \(version) LTS" }
}

public enum UbuntuProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case gnome, xfce, server
    public var id: String { rawValue }
    public var title: String {
        switch self { case .gnome: "Ubuntu Desktop (GNOME)"; case .xfce: "Light Desktop (Xfce)"; case .server: "Server" }
    }
    public var detail: String {
        switch self {
        case .gnome: "Ubuntu’s desktop, with clipboard support and Retina scaling."
        case .xfce: "A lighter desktop with clipboard support and Retina scaling."
        case .server: "A console system for services and development."
        }
    }
    public var minimumMemoryGB: Int { self == .gnome ? 4 : 2 }
    public var minimumDiskGB: Int { self == .server ? 16 : 32 }
    public var requiredFreeGB: UInt64 { self == .server ? 12 : 24 }
    public var desktop: Bool { self != .server }
}

/// Only non-secret setup choices are persisted. Credentials live in private seed media.
public struct UbuntuSetup: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var release: UbuntuRelease
    public var profile: UbuntuProfile
    public var username: String
    public var developmentTools: Bool
    public var completed: Bool
    public init(release: UbuntuRelease = .resolute, profile: UbuntuProfile = .gnome,
                username: String, developmentTools: Bool = false, completed: Bool = false) {
        self.release = release; self.profile = profile; self.username = username
        self.developmentTools = developmentTools; self.completed = completed
    }
    public static func validateUsername(_ username: String) throws {
        let reserved = ["root", "daemon", "bin", "sys", "sync", "games", "man", "lp", "mail", "news", "uucp", "proxy", "www-data", "backup", "list", "irc", "_apt", "nobody"]
        guard username.range(of: "^[a-z_][a-z0-9_-]{0,31}$", options: .regularExpression) != nil,
              !reserved.contains(username), !username.hasPrefix("systemd") else {
            throw VMError.message("Use a lowercase user name, up to 32 letters, numbers, underscores or hyphens. Choose a personal account name.")
        }
    }
    public static func validatePassword(_ password: String, confirmation: String) throws {
        guard password.count >= 8, password.utf8.count <= 1024, !password.contains("\0") else {
            throw VMError.message("Choose a password of at least 8 characters, up to 1024 bytes.")
        }
        guard password == confirmation else { throw VMError.message("The passwords do not match.") }
    }
    public static func validatePublicKey(_ key: String?) throws {
        guard let key, !key.isEmpty else { return }
        let fields = key.split(separator: " ", omittingEmptySubsequences: true)
        guard key.utf8.count <= 8192, !key.contains("\n"), !key.contains("\r"), !key.contains("\0"), fields.count >= 2,
              ["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"].contains(String(fields[0])),
              let decoded = Data(base64Encoded: String(fields[1])), validKeyPayload(decoded, type: String(fields[0])) else {
            throw VMError.message("Choose one SSH public key (.pub), not a private key.")
        }
    }
    private static func validKeyPayload(_ data: Data, type: String) -> Bool {
        var position = 0
        func field() -> Data? {
            guard position + 4 <= data.count else { return nil }
            let length = data[position..<(position + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            position += 4
            guard length <= 4096, Int(length) <= data.count - position else { return nil }
            let result = data.subdata(in: position..<(position + Int(length))); position += Int(length)
            return result
        }
        guard let algorithm = field(), String(data: algorithm, encoding: .utf8) == type else { return false }
        if type == "ssh-ed25519" { return field()?.count == 32 && position == data.count }
        if type == "ssh-rsa" {
            guard let exponent = field(), let modulus = field(), !exponent.isEmpty, exponent.count <= 8,
                  modulus.count >= 128, modulus.count <= 1025 else { return false }
            return position == data.count
        }
        guard let curve = field(), let point = field(), String(data: curve, encoding: .utf8) == String(type.dropFirst("ecdsa-sha2-".count)),
              point.first == 4, [65, 97, 133].contains(point.count) else { return false }
        return position == data.count
    }
    public var requiredFreeBytes: UInt64 { (profile.requiredFreeGB + (developmentTools ? 8 : 0)) * VMStorage.gib }
    public func validate(record: VirtualMachineRecord) throws {
        guard version == 1, record.system == .linux else { throw VMError.message("This automatic Ubuntu setup is not supported by this version of MacVM.") }
        try Self.validateUsername(username)
        guard record.memoryGB >= profile.minimumMemoryGB, record.diskGB >= profile.minimumDiskGB else {
            throw VMError.message("\(profile.title) needs at least \(profile.minimumMemoryGB) GB memory and a \(profile.minimumDiskGB) GB disk.")
        }
        guard completed || record.networkEnabled else { throw VMError.message("Enable Internet access to complete automatic Ubuntu setup.") }
    }
}
