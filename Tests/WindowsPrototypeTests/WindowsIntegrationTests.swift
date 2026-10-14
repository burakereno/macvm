import XCTest
@testable import WindowsPrototypeCore
import MacVMCore

final class WindowsIntegrationTests: XCTestCase {
    func testEmbeddedDisplayHasOnlyPrivateSocketAndNetworkCanBeDisabled() throws {
        var config = WindowsConfiguration(directory: URL(fileURLWithPath: "/tmp/win-test"))
        config.networkEnabled = false
        let args = try config.arguments(runtime: URL(fileURLWithPath: "/tmp/private-win"), embeddedDisplay: true)
        XCTAssertEqual(args[args.firstIndex(of: "-display")! + 1], "none")
        XCTAssertEqual(args[args.firstIndex(of: "-vnc")! + 1], "unix:/tmp/private-win/display.sock")
        XCTAssertFalse(args.contains("-netdev"))
        XCTAssertFalse(args.contains(where: { $0.contains("hostfwd") }))
        XCTAssertLessThan(args.firstIndex(of: "virtio-gpu-pci,id=gpu,xres=2560,yres=1600")!, args.firstIndex(of: "ramfb")!)
        config.installerPath = "/tmp/setup.iso"
        let installer = try config.arguments(runtime: URL(fileURLWithPath: "/tmp/private-win"), embeddedDisplay: true)
        XCTAssertLessThan(installer.firstIndex(of: "ramfb")!, installer.firstIndex(of: "virtio-gpu-pci,id=gpu,xres=2560,yres=1600")!)
    }
    func testFramebufferChecksBoundsAndRetainsPreviousPixels() throws {
        var frame = try DisplayFramebuffer(width: 2, height: 2)
        let red = Data([0,0,255,0])
        try frame.apply(x: 1, y: 0, width: 1, height: 1, pixels: red)
        XCTAssertEqual(frame.pixels, Data([0,0,0,0,0,0,255,0,0,0,0,0,0,0,0,0]))
        XCTAssertEqual(frame.image()?.width, 2)
        XCTAssertThrowsError(try frame.apply(x: 2, y: 0, width: 1, height: 1, pixels: red))
        XCTAssertThrowsError(try frame.apply(x: 0, y: 0, width: 1, height: 1, pixels: Data()))
        XCTAssertThrowsError(try DisplayFramebuffer(width: 0, height: 1))
        XCTAssertThrowsError(try DisplayFramebuffer(width: 8192, height: 8192))
    }
    func testMigrationPreservesDiskAndTPMAndRejectsActiveVM() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("legacy"), location = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("TPM"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var header = Data(repeating: 0, count: 104)
        func put(_ value: UInt64, at offset: Int, length: Int) { for i in 0..<length { header[offset+i] = UInt8(truncatingIfNeeded: value >> ((length - 1 - i) * 8)) } }
        put(0x514649fb, at: 0, length: 4); put(3, at: 4, length: 4); put(128 * VMStorage.gib, at: 24, length: 8)
        try header.write(to: source.appendingPathComponent("Disk.qcow2"))
        try Data([1,2,3]).write(to: source.appendingPathComponent("EFI.fd"))
        try Data([4,5,6]).write(to: source.appendingPathComponent("TPM/tpm2-00.permall"))
        try WindowsConfiguration(directory: source).save()
        var lock: VMLock? = try VMLock(directory: source)
        XCTAssertThrowsError(try WindowsMigration.migrate(from: source, to: location))
        withExtendedLifetime(lock) {}; lock = nil
        let result = try WindowsMigration.migrate(from: source, to: location)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: result.url.appendingPathComponent("Disk.qcow2")), header)
        XCTAssertEqual(try Data(contentsOf: result.url.appendingPathComponent("TPM/tpm2-00.permall")), Data([4,5,6]))
        XCTAssertEqual(try VMStorage.validateBundle(at: result.url).system, .windows)
        XCTAssertEqual(result.record.displayBrand, .windows)
        XCTAssertThrowsError(try VMStorage.clone(result, to: location))
        try FileManager.default.removeItem(at: result.url.appendingPathComponent("TPM/tpm2-00.permall"))
        XCTAssertThrowsError(try VMStorage.validateBundle(at: result.url), "A missing TPM must never silently generate a new identity")
    }
    func testMigrationRollsBackUnsafeDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("legacy"), location = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try WindowsConfiguration(directory: source).save()
        try Data([1]).write(to: source.appendingPathComponent("Disk.qcow2"))
        try Data([1]).write(to: source.appendingPathComponent("EFI.fd"))
        XCTAssertThrowsError(try WindowsMigration.migrate(from: source, to: location))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("Disk.qcow2").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("Config.json").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: location.path), [])
    }
}
