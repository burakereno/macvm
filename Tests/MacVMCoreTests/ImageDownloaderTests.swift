import XCTest
@testable import MacVMCore

private final class ImageProtocol: URLProtocol, @unchecked Sendable {
    static var handle: ((URLRequest, ImageProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handle?(request, self) }
    override func stopLoading() {}
    func reply(status: Int, headers: [String: String], body: Data, error: Error? = nil, responseURL: URL? = nil) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: responseURL ?? request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        // A short body models an interrupted transfer. URLProtocol discards its
        // buffered body on didFailWithError, unlike an actual TCP connection.
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class ImageDownloaderTests: XCTestCase {
    private var root: URL!
    private let remote = URL(string: "https://updates.example.test/image.ipsw")!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacVM-download-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { ImageProtocol.handle = nil; try FileManager.default.removeItem(at: root) }
    private func downloader(capacity: UInt64 = 1_000_000, allowedHosts: Set<String>? = nil) -> ImageDownloader {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ImageProtocol.self]
        return ImageDownloader(destination: root.appendingPathComponent("MacVM-macOS-test.ipsw.download"), requiredRemainingSpace: 0,
                               configuration: config, allowedHosts: allowedHosts, availableCapacity: { _ in capacity }, progress: { _, _ in })
    }
    func testMicrosoftDownloadCannotConsumeAnUntrustedResponse() async throws {
        let official = URL(string: "https://download.microsoft.com/test.iso")!
        ImageProtocol.handle = { _, connection in
            connection.reply(status: 200, headers: ["Content-Length":"4"], body: Data("evil".utf8), responseURL: URL(string: "https://outside.example/test.iso")!)
        }
        do { _ = try await downloader(allowedHosts: ["download.microsoft.com"]).download(official); XCTFail("Must reject outside response") } catch {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("MacVM-macOS-test.ipsw.download")).count, 0)
        ImageProtocol.handle = { _, _ in XCTFail("Disallowed initial URLs must not make a request") }
        for url in ["http://download.microsoft.com/test.iso", "https://user:password@download.microsoft.com/test.iso", "https://outside.example/test.iso"] {
            do { _ = try await downloader(allowedHosts: ["download.microsoft.com"]).download(URL(string: url)!); XCTFail("Must reject \(url)") } catch {}
        }
    }
    func testBrokenSymlinkCannotCreateAFileOutsideDownloads() async throws {
        let outside = root.appendingPathComponent("outside")
        let destination = root.appendingPathComponent("MacVM-macOS-test.ipsw.download")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
        do { _ = try await downloader().download(remote); XCTFail("Must reject download symlink") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    }
    func testInterruptedDownloadResumesWithMatchingValidatorAndRange() async throws {
        ImageProtocol.handle = { _, connection in
            connection.reply(status: 200, headers: ["Content-Length": "10", "ETag": "\"version1\""], body: Data("abc".utf8), error: URLError(.networkConnectionLost))
        }
        do { _ = try await downloader().download(remote); XCTFail("Interrupted download should fail") } catch {}
        ImageProtocol.handle = { request, connection in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=3-")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-Range"), "\"version1\"")
            connection.reply(status: 206, headers: ["Content-Length": "7", "Content-Range": "bytes 3-9/10", "ETag": "\"version1\""], body: Data("defghij".utf8))
        }
        let complete = try await downloader().download(remote)
        XCTAssertEqual(try Data(contentsOf: complete), Data("abcdefghij".utf8))
    }
    func testServerRestartDiscardsOldPartialBytes() async throws {
        ImageProtocol.handle = { _, connection in connection.reply(status: 200, headers: ["Content-Length": "10", "ETag": "\"old\""], body: Data("abc".utf8), error: URLError(.networkConnectionLost)) }
        do { _ = try await downloader().download(remote) } catch {}
        ImageProtocol.handle = { _, connection in connection.reply(status: 200, headers: ["Content-Length": "4", "ETag": "\"new\""], body: Data("NEW!".utf8)) }
        let complete = try await downloader().download(remote)
        XCTAssertEqual(try Data(contentsOf: complete), Data("NEW!".utf8))
    }
    func testHTTPErrorAndLowSpaceCannotBeConsumedAsImage() async throws {
        ImageProtocol.handle = { _, connection in connection.reply(status: 403, headers: ["Content-Length": "6"], body: Data("denied".utf8)) }
        do { _ = try await downloader().download(remote); XCTFail("Must reject HTTP error") } catch {}
        ImageProtocol.handle = { _, connection in connection.reply(status: 200, headers: ["Content-Length": "4"], body: Data("body".utf8)) }
        do { _ = try await downloader(capacity: 0).download(remote); XCTFail("Must reject low space") } catch {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("MacVM-macOS-test.ipsw.download")).count, 0)
    }
    func testInvalidResumeRangeCannotAppendToOldImage() async throws {
        ImageProtocol.handle = { _, connection in connection.reply(status: 200, headers: ["Content-Length": "10", "ETag": "\"old\""], body: Data("abc".utf8), error: URLError(.networkConnectionLost)) }
        do { _ = try await downloader().download(remote) } catch {}
        ImageProtocol.handle = { _, connection in connection.reply(status: 206, headers: ["Content-Length": "8", "Content-Range": "bytes 2-9/10", "ETag": "\"old\""], body: Data("BADBYTES".utf8)) }
        do { _ = try await downloader().download(remote); XCTFail("Must reject shifted range") } catch {}
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("MacVM-macOS-test.ipsw.download")), Data("abc".utf8))
    }
}
