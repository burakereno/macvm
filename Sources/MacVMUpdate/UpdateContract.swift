import Foundation
import CryptoKit

public enum UpdateError: LocalizedError {
    case badResponse, missingVersion, missingAsset, invalidManifest, checksumMismatch, invalidInstaller, busy
    public var errorDescription: String? {
        switch self {
        case .badResponse: return "The update server did not return a successful response. Try again later."
        case .missingVersion: return "No compatible MacVM release was found."
        case .missingAsset: return "The release is missing its MacVM installer."
        case .invalidManifest: return "The update metadata does not match this MacVM app."
        case .checksumMismatch: return "The downloaded installer is damaged or does not match the release."
        case .invalidInstaller: return "The installer could not be verified. Your current MacVM app was kept."
        case .busy: return "Shut down your virtual machines before installing an update."
        }
    }
}

public struct SemanticVersion: Comparable, Equatable, Sendable {
    public let parts: [UInt]
    public init(_ value: String) throws {
        let strings = value.split(separator: ".", omittingEmptySubsequences: false)
        guard strings.count == 3, strings.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              strings.allSatisfy({ $0 == "0" || !$0.hasPrefix("0") }) else { throw UpdateError.missingVersion }
        let numbers = strings.compactMap { UInt($0) }
        guard numbers.count == 3 else { throw UpdateError.missingVersion }
        parts = numbers
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

public enum UpdateContract {
    public static let owner = "burakereno"
    public static let repo = "macvm"
    public static let assetName = "MacVM.dmg"
    public static let appName = "MacVM"
    public static let bundleIdentifier = "com.burakerenoglu.macvm"
    public static let teamIdentifier = "66K3EFBVB6"
    public static let latestURL = URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")!
    public static func validateResponseURL(_ url: URL?) throws {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host ?? "") else {
            throw UpdateError.badResponse
        }
    }

    public static func tag(from url: URL) throws -> String {
        let parts = url.pathComponents
        guard url.scheme == "https", url.host == "github.com", url.query == nil, url.fragment == nil,
              parts.count == 6, parts[1] == owner, parts[2] == repo, parts[3] == "releases", parts[4] == "tag",
              parts[5].hasPrefix("v") else { throw UpdateError.missingVersion }
        _ = try SemanticVersion(String(parts[5].dropFirst()))
        return parts[5]
    }
    public static func assetURL(tag: String, manifest: Bool = false) throws -> URL {
        guard tag.hasPrefix("v") else { throw UpdateError.missingVersion }
        _ = try SemanticVersion(String(tag.dropFirst()))
        return URL(string: "https://github.com/\(owner)/\(repo)/releases/download/\(tag)/\(assetName)\(manifest ? ".update.json" : "")")!
    }
    public static func checksum(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct UpdateManifest: Codable, Equatable, Sendable {
    public let version: String
    public let asset: String
    public let sha256: String
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public func validate(tag: String) throws {
        guard version == String(tag.dropFirst()), asset == UpdateContract.assetName,
              bundleIdentifier == UpdateContract.bundleIdentifier, teamIdentifier == UpdateContract.teamIdentifier,
              sha256.count == 64, sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw UpdateError.invalidManifest }
        _ = try SemanticVersion(version)
    }
    public func verify(file: URL) throws {
        guard try UpdateContract.checksum(of: file) == sha256 else { throw UpdateError.checksumMismatch }
    }
}

public struct UpdateRelease: Equatable, Sendable {
    public let tag: String
    public let downloadURL: URL
    public let manifest: UpdateManifest
}
