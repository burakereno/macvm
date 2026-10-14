import XCTest
@testable import MacVMCore

final class UbuntuSeedTests: XCTestCase {
    private var record: VirtualMachineRecord {
        var value = VirtualMachineRecord(name: "Automatic Ubuntu", system: .linux, cpuCount: 2, memoryGB: 4, diskGB: 32)
        value.ubuntuSetup = UbuntuSetup(username: "macvmtest")
        return value
    }
    func testSeedContainsHashedAccountAndFixedGuestOnlyServices() throws {
        let hash = try SHA512Crypt.hash(password: "public-dummy-test", salt: "test", rounds: 1000)
        let data = try UbuntuSeed.userData(record: record, passwordHash: hash)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("public-dummy-test"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data.dropFirst("#cloud-config\n".utf8.count)) as? [String: Any])
        let user = try XCTUnwrap((json["users"] as? [[String: Any]])?.first)
        XCTAssertEqual(user["hashed_passwd"] as? String, hash)
        XCTAssertEqual(user["sudo"] as? [String], ["ALL=(ALL) ALL"])
        XCTAssertEqual(json["ssh_pwauth"] as? Bool, false)
        let script = try XCTUnwrap((json["write_files"] as? [[String: Any]])?.first?["content"] as? String)
        XCTAssertFalse(script.contains(hash))
        XCTAssertTrue(script.contains("packages.done"))
        XCTAssertTrue(script.contains("dpkg --configure -a"))
        XCTAssertFalse(script.contains("curl"))
        XCTAssertThrowsError(try UbuntuSeed.userData(record: record, passwordHash: "plaintext"))
    }
    func testLogReadsOnlyBoundedRegularGuestOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: UbuntuProvisioning.folder(in: root), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = UbuntuProvisioning.folder(in: root).appendingPathComponent("Setup.log")
        try Data(repeating: 65, count: 600000).write(to: log)
        XCTAssertEqual(try UbuntuProvisioning.logText(directory: root).utf8.count, 524288)
        try Data("\u{001b}[32mready\u{001b}[0m\r\n".utf8).write(to: log)
        XCTAssertEqual(try UbuntuProvisioning.logText(directory: root), "ready\n")
        try FileManager.default.removeItem(at: log)
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: root.appendingPathComponent("outside"))
        XCTAssertThrowsError(try UbuntuProvisioning.logText(directory: root))
    }
    func testStatusRejectsForeignOversizeAndLinkedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: UbuntuProvisioning.folder(in: root), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = UbuntuProvisioning.folder(in: root).appendingPathComponent("Status.json")
        let good = UbuntuProvisionStatus(instanceID: UbuntuProvisioning.instanceID(record), stage: .ready)
        // Use one record identity throughout the test.
        let machine = record
        let status = UbuntuProvisionStatus(instanceID: UbuntuProvisioning.instanceID(machine), stage: .desktop)
        try JSONEncoder().encode(status).write(to: url)
        XCTAssertEqual(UbuntuProvisioning.read(record: machine, directory: root)?.stage, .desktop)
        try JSONEncoder().encode(good).write(to: url)
        XCTAssertNil(UbuntuProvisioning.read(record: machine, directory: root))
        try Data(repeating: 32, count: 16385).write(to: url)
        XCTAssertNil(UbuntuProvisioning.read(record: machine, directory: root))
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: root.appendingPathComponent("anything"))
        XCTAssertNil(UbuntuProvisioning.read(record: machine, directory: root))
    }
}
