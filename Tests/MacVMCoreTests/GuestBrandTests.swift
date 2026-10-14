import XCTest
@testable import MacVMCore

final class GuestBrandTests: XCTestCase {
    func testInstallerIdentityTakesPriorityOverUserName() {
        XCTAssertEqual(GuestBrand.infer(system: .linux, sourceImagePath: "/Downloads/UBUNTU-26.04.1-arm64.iso",
            osVersion: nil, name: "Windows build worker"), .ubuntu)
        XCTAssertEqual(GuestBrand.infer(system: .linux, sourceImagePath: "/Downloads/Win11_25H2_English_Arm64.iso",
            osVersion: nil, name: "Test machine"), .windows)
        XCTAssertEqual(GuestBrand.infer(system: .linux, sourceImagePath: nil, osVersion: nil, name: "Windows11 Test"), .windows)
        XCTAssertEqual(GuestBrand.infer(system: .linux, sourceImagePath: "/Users/ubuntu/Downloads/alpine.iso",
            osVersion: nil, name: "Web server"), .linux)
    }

    func testLegacyUbuntuKeepsBrandWhenRenamedAndInstallerRemoved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = VirtualMachineRecord(name: "Ubuntu 26.04.1", system: .linux)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(initial)) as! [String: Any]
        object.removeValue(forKey: "guestBrand")
        try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent("Config.json"))
        var migrated = try VirtualMachineRecord.load(from: directory)
        XCTAssertEqual(migrated.displayBrand, .ubuntu)
        migrated.name = "Build worker"; migrated.sourceImagePath = nil
        try migrated.save(to: directory)
        XCTAssertEqual(try VirtualMachineRecord.load(from: directory).displayBrand, .ubuntu)
    }

    func testMacBackendWinsAndUnknownFutureBrandIsReadable() throws {
        var mac = VirtualMachineRecord(name: "Ubuntu", system: .macOS)
        mac.guestBrand = "ubuntu"
        XCTAssertEqual(mac.displayBrand, .macOS)
        var linux = VirtualMachineRecord(name: "Web server", system: .linux)
        linux.guestBrand = "future-brand"
        let decoded = try JSONDecoder().decode(VirtualMachineRecord.self, from: JSONEncoder().encode(linux))
        XCTAssertEqual(decoded.displayBrand, .linux)
        XCTAssertEqual(decoded.guestBrand, "future-brand")
    }
}
