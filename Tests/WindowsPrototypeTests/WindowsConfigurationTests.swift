import XCTest
@testable import WindowsPrototypeCore

final class WindowsConfigurationTests: XCTestCase {
    func testHardwareVirtualizationAndTPMAreRequired() throws {
        let c = WindowsConfiguration(directory: URL(fileURLWithPath: "/tmp/windows-test"))
        let args = try c.arguments(runtime: URL(fileURLWithPath: "/tmp/private-win"))
        XCTAssertEqual(args[args.firstIndex(of: "-accel")! + 1], "hvf")
        XCTAssertEqual(args[args.firstIndex(of: "-cpu")! + 1], "host")
        XCTAssertTrue(args[args.firstIndex(of: "-machine")! + 1].contains("virtio-mmio-transports=0"))
        XCTAssertTrue(args.contains("tpm-tis-device,tpmdev=tpm0,ppi=off"))
        XCTAssertFalse(args.contains(where: { $0.contains("tcg") || $0.contains("hostfwd") }))
        XCTAssertFalse(args.contains(where: { $0.contains("install-cd") }))
    }

    func testInstallerPathIsJSONEncodedAndOptional() throws {
        var c = WindowsConfiguration(directory: URL(fileURLWithPath: "/tmp/windows, quoted-test"))
        c.installerPath = "/tmp/source,\"test.iso"
        let args = try c.arguments(runtime: URL(fileURLWithPath: "/tmp/private-win"))
        let index = args.firstIndex(where: { $0.contains("\"node-name\":\"install\"") })!
        let object = try JSONSerialization.jsonObject(with: Data(args[index].utf8)) as! [String: Any]
        let file = object["file"] as! [String: Any]
        XCTAssertEqual(file["filename"] as? String, c.installerPath)
        XCTAssertEqual(object["read-only"] as? Bool, true)
        XCTAssertTrue(args.contains("scsi-cd,bus=install-usb.0,drive=install,id=install-cd,bootindex=1"))
    }

    func testRejectsInvalidResourceAndSocketLimits() {
        var c = WindowsConfiguration(directory: URL(fileURLWithPath: "/tmp/windows-test"))
        c.cpuCount = 0
        XCTAssertThrowsError(try c.arguments(runtime: URL(fileURLWithPath: "/tmp/private-win")))
        c.cpuCount = 4; c.memoryGB = 2
        XCTAssertThrowsError(try c.arguments(runtime: URL(fileURLWithPath: "/tmp/private-win")))
        c.memoryGB = 8
        XCTAssertThrowsError(try c.arguments(runtime: URL(fileURLWithPath: "/tmp/" + String(repeating: "a", count: 110))))
    }
}
