import XCTest
@testable import MacVMCore

final class QCOW2Tests: XCTestCase {
    private func fixture(version: UInt64 = 3) -> Data {
        var data = Data(repeating: 0, count: 3072)
        func put(_ offset: Int, _ value: UInt64, _ size: Int) {
            for i in 0..<size { data[offset + i] = UInt8(truncatingIfNeeded: value >> ((size - 1 - i) * 8)) }
        }
        put(0, 0x514649fb, 4); put(4, version, 4); put(20, 9, 4)
        put(24, 1536, 8); put(36, 1, 4); put(40, 1024, 8)
        put(100, 104, 4)
        put(1024, 1536 | (1 << 63), 8)
        put(1536, 2048 | (1 << 63), 8)
        put(1544, 2560 | (1 << 62), 8)
        put(1552, version == 3 ? 1 : 0, 8)
        data[2048] = 42; data[2558] = 0x55; data[2559] = 0xaa
        let deflate = Data(base64Encoded: "c3IaBSMZAAA=")!
        data.replaceSubrange(2560..<(2560 + deflate.count), with: deflate)
        return data
    }
    func testAllocatedDeflateAndSparseClustersForBothVersions() throws {
        for version: UInt64 in [2, 3] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("source.img"), destination = root.appendingPathComponent("Disk.img")
            try fixture(version: version).write(to: source)
            try QCOW2.convert(source: source, destination: destination, capacity: 2048)
            let output = try Data(contentsOf: destination)
            XCTAssertEqual(output.count, 2048)
            XCTAssertEqual(output[0], 42)
            XCTAssertEqual(output[510], 0x55)
            XCTAssertEqual(output[512..<1024], Data(repeating: 66, count: 512))
            XCTAssertTrue(output[1024...].allSatisfy { $0 == 0 })
        }
    }
    func testRejectsMalformedAndUnsupportedImagesWithoutReplacingDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.img"), destination = root.appendingPathComponent("Disk.img")
        let original = Data("keep-existing-disk".utf8)
        try original.write(to: destination)
        for offset in [0, 15, 35, 79, 40, 1537, 2560] {
            var damaged = fixture()
            damaged[offset] = 0xff
            try damaged.write(to: source)
            XCTAssertThrowsError(try QCOW2.convert(source: source, destination: destination, capacity: 2048))
            XCTAssertEqual(try Data(contentsOf: destination), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Disk.preparing").path))
        }
        try fixture().prefix(2800).write(to: source)
        XCTAssertThrowsError(try QCOW2.convert(source: source, destination: destination, capacity: 2048))
        try fixture().write(to: source)
        XCTAssertThrowsError(try QCOW2.convert(source: source, destination: destination, capacity: 512))
    }
    func testCancellationPreservesDestinationAndRemovesPreparationFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.img"), destination = root.appendingPathComponent("Disk.img")
        try fixture().write(to: source)
        let original = Data("untouched".utf8)
        try original.write(to: destination)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            try QCOW2.convert(source: source, destination: destination, capacity: 2048)
        }
        do { try await task.value; XCTFail("Cancelled conversion completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Disk.preparing").path))
    }
}
