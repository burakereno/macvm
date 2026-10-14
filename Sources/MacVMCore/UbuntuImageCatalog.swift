import Foundation
import CryptoKit
import Darwin

public struct UbuntuImage: Sendable {
    public let release: UbuntuRelease
    public let url: URL
    public let sha256: String
    public var archiveName: String { "ubuntu-\(release.version)-server-cloudimg-arm64.img" }
    public var rawName: String { "\(release.rawValue)-server-cloudimg-arm64.img" }
    public var managedName: String { "MacVM-Ubuntu-\(release.version)-\(sha256.prefix(12))-arm64.img" }
    public init(release: UbuntuRelease, sha256: String) {
        self.release = release; self.sha256 = sha256
        url = URL(string: "https://cloud-images.ubuntu.com/releases/\(release.version)/release/ubuntu-\(release.version)-server-cloudimg-arm64.img")!
    }

    public func verify(archive: URL) throws {
        guard sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit }) else { throw VMError.message("Invalid Ubuntu image checksum.") }
        let fd = open(archive.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw VMError.message("Cannot read the Ubuntu image.") }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0,
              info.st_uid == geteuid(), info.st_nlink == 1 else { throw VMError.message("Choose a regular, private Ubuntu image file.") }
        var digest = SHA256()
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation(); digest.update(data: bytes)
        }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == sha256.lowercased() else {
            throw VMError.message("Ubuntu image verification failed. Remove the downloaded file in Installation Files and try again.")
        }
    }

    public func prepareDisk(archive: URL, destination: URL, diskGB: Int) throws {
        try verify(archive: archive)
        try QCOW2.convert(source: archive, destination: destination, capacity: UInt64(diskGB) * VMStorage.gib)
    }

    static func output(_ command: String, _ arguments: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: command); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        var bytes = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {
            bytes.append(chunk)
            if bytes.count > 65536 || Task.isCancelled {
                process.terminate(); process.waitUntilExit()
                if Task.isCancelled { throw CancellationError() }
                throw VMError.message("Ubuntu archive metadata is too large.")
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: bytes, encoding: .utf8) else { throw VMError.message("Cannot inspect the Ubuntu archive.") }
        return text
    }
}

public enum UbuntuImageCatalog {
    public static func resolve(_ release: UbuntuRelease) async throws -> UbuntuImage {
        let url = URL(string: "https://cloud-images.ubuntu.com/releases/\(release.version)/release/SHA256SUMS")!
        var request = URLRequest(url: url); request.timeoutInterval = 30; request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https", response.url?.host == "cloud-images.ubuntu.com", data.count <= 1_048_576,
              let text = String(data: data, encoding: .utf8) else { throw VMError.message("Could not load the official Ubuntu image catalog.") }
        return try parse(text, release: release)
    }
    public static func parse(_ text: String, release: UbuntuRelease) throws -> UbuntuImage {
        let filename = "ubuntu-\(release.version)-server-cloudimg-arm64.img"
        let matches = text.split(separator: "\n").compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[1] == "*" + filename || fields[1] == filename,
                  fields[0].count == 64, fields[0].allSatisfy(\.isHexDigit) else { return nil }
            return fields[0].lowercased()
        }
        guard matches.count == 1 else { throw VMError.message("The catalog does not contain a verified ARM64 Ubuntu image.") }
        return UbuntuImage(release: release, sha256: matches[0])
    }
}
