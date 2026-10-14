import XCTest
import Darwin
@testable import WindowsPrototypeCore

final class QMPClientTests: XCTestCase {
    func testFragmentedGreetingAndEventsBeforeReply() throws {
        let server = try FakeQMPServer { connection in
            connection.send("{\"QMP\":")
            connection.send("{}}\r\n")
            let caps = connection.request()
            connection.send("{\"return\":{},\"id\":\(caps)}\n")
            let query = connection.request()
            connection.send("{\"event\":\"RESUME\",\"data\":{}}\r\n{\"return\":{\"running\":true},\"id\":\(query)}\n")
        }
        defer { server.finish() }
        let client = try QMPClient(socketURL: server.url)
        let status = try client.execute("query-status") as! [String: Any]
        XCTAssertEqual(status["running"] as? Bool, true)
    }

    func testEngineErrorIsReportedAndNextCommandStillWorks() throws {
        let server = try FakeQMPServer { connection in
            connection.send("{\"QMP\":{}}\n")
            connection.send("{\"return\":{},\"id\":\(connection.request())}\n")
            connection.send("{\"error\":{\"desc\":\"Not supported\"},\"id\":\(connection.request())}\n")
            connection.send("{\"return\":{},\"id\":\(connection.request())}\n")
        }
        defer { server.finish() }
        let client = try QMPClient(socketURL: server.url)
        XCTAssertThrowsError(try client.execute("missing-command")) { XCTAssertEqual($0.localizedDescription, "Not supported") }
        XCTAssertNoThrow(try client.execute("stop"))
    }

    func testDisconnectAndMismatchedReplyAreRejected() throws {
        let server = try FakeQMPServer { connection in
            connection.send("{\"QMP\":{}}\n")
            connection.send("{\"return\":{},\"id\":\(connection.request())}\n")
            _ = connection.request()
            connection.send("{\"return\":{},\"id\":999}\n")
        }
        defer { server.finish() }
        let client = try QMPClient(socketURL: server.url)
        XCTAssertThrowsError(try client.execute("stop"))
        XCTAssertThrowsError(try client.execute("query-status"))
    }

    func testMissingGreetingIsRejected() throws {
        let server = try FakeQMPServer { $0.send("{\"event\":\"RESUME\"}\n") }
        defer { server.finish() }
        XCTAssertThrowsError(try QMPClient(socketURL: server.url))
    }
}

private final class FakeQMPServer {
    let url: URL
    let directory: URL
    let done = DispatchSemaphore(value: 0)
    let listener: Int32
    init(handler: @escaping (Connection) -> Void) throws {
        directory = URL(fileURLWithPath: "/tmp/mvw-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        url = directory.appendingPathComponent("qmp")
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(url.path.utf8) + [0]) }
        let result = withUnsafePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, listen(listener, 1) == 0 else { throw NSError(domain: "FakeQMP", code: 1) }
        DispatchQueue.global().async { [self] in
            let fd = accept(listener, nil, nil)
            if fd >= 0 { let connection = Connection(fd); handler(connection); Darwin.close(fd) }
            done.signal()
        }
    }
    func finish() {
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        Darwin.close(listener); try? FileManager.default.removeItem(at: directory)
    }
    final class Connection {
        let fd: Int32
        init(_ fd: Int32) {
            self.fd = fd
            var noSignal: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, 4)
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        }
        func send(_ value: String) { _ = value.withCString { Darwin.write(fd, $0, strlen($0)) } }
        func request() -> Int {
            var data = Data(); var byte: UInt8 = 0
            while read(fd, &byte, 1) == 1 { if byte == 10 { break }; data.append(byte) }
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return object?["id"] as? Int ?? -1
        }
    }
}
