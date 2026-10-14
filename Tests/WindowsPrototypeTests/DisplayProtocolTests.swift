import XCTest
import Darwin
@testable import WindowsPrototypeCore

final class DisplayProtocolTests: XCTestCase {
    func testExtendedResizeWireNegotiationAndForwardedResponse() throws {
        let done = expectation(description: "new framebuffer received")
        let client = LocalDisplayClient()
        var dimensions: [Int] = []
        client.onFailure = { XCTFail($0); done.fulfill() }
        client.onFrame = { image in
            dimensions.append(image.width)
            if dimensions.count == 4 { client.stop(); done.fulfill() }
        }
        client.resizeDisplay(to: try XCTUnwrap(DisplaySize(width: 640, height: 480)))
        let server = try DisplayTestServer { socket in
            socket.send(Data("RFB 003.008\n".utf8)); XCTAssertEqual(socket.read(12), Data("RFB 003.008\n".utf8))
            socket.send(Data([1,1])); XCTAssertEqual(socket.read(1), Data([1]))
            socket.send(Data([0,0,0,0])); XCTAssertEqual(socket.read(1), Data([1]))
            socket.send(Data([0,2,0,2] + Array(repeating: 0, count: 20)))
            XCTAssertEqual(socket.read(20).count, 20)
            XCTAssertEqual(socket.read(16), Data([2,0,0,3,0,0,0,0,255,255,254,204,255,255,255,33]))
            XCTAssertEqual(socket.read(10), Data([3,0,0,0,0,0,0,2,0,2]))
            socket.layout(width: 2, height: 2)
            XCTAssertEqual(socket.read(10), Data([3,1,0,0,0,0,0,2,0,2]))
            XCTAssertEqual(socket.read(24), Data([251,0,2,128,1,224,1,0,0,0,0,0,0,0,0,0,2,128,1,224,0,0,0,0]))
            // Undefined dimensions in a forwarded response must not be allocated.
            socket.layout(width: 65535, height: 65535, reason: 1, status: 4)
            XCTAssertEqual(socket.read(10), Data([3,1,0,0,0,0,0,2,0,2]))
            socket.layout(width: 640, height: 480)
            XCTAssertEqual(socket.read(10), Data([3,0,0,0,0,0,2,128,1,224]))
            // A real pixel update must still parse after the variable-length screen payload.
            socket.send(Data([0,0,0,1,0,0,0,0,0,1,0,1,0,0,0,0,0,0,255,0]))
            _ = socket.read(1) // Wait until the client closes, keeping EOF out of the UI callback.
        }
        defer { client.stop(); server.finish() }
        client.start(socketURL: server.url)
        wait(for: [done], timeout: 8)
        XCTAssertEqual(dimensions, [2,2,640,640])
    }
}

private final class DisplayTestServer {
    let directory = URL(fileURLWithPath: "/tmp/mvrfb-\(UUID().uuidString.prefix(8))")
    var url: URL { directory.appendingPathComponent("socket") }
    private let listener: Int32
    private let done = DispatchSemaphore(value: 0)
    init(_ handler: @escaping (Connection) -> Void) throws {
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(url.path.utf8) + [0]) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, listen(listener, 1) == 0 else { throw NSError(domain: "DisplayTestServer", code: 1) }
        DispatchQueue.global().async { [self] in
            let fd = accept(listener, nil, nil)
            if fd >= 0 { handler(Connection(fd)); Darwin.close(fd) }
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
            var noSignal: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, 4)
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }
        func send(_ data: Data) { data.withUnsafeBytes { XCTAssertEqual(Darwin.write(fd, $0.baseAddress, $0.count), $0.count) } }
        func read(_ count: Int) -> Data {
            var data = Data(); var byte: UInt8 = 0
            while data.count < count, Darwin.read(fd, &byte, 1) == 1 { data.append(byte) }
            return data
        }
        func layout(width: Int, height: Int, reason: Int = 0, status: Int = 0) {
            func pair(_ n: Int) -> [UInt8] { [UInt8(n >> 8), UInt8(n & 255)] }
            send(Data([0,0,0,1] + pair(reason) + pair(status) + pair(width) + pair(height) + [255,255,254,204,1,0,0,0,0,0,0,0,0,0,0,0] + pair(width) + pair(height) + [0,0,0,0]))
        }
    }
}
