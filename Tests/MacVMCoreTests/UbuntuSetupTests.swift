import XCTest
@testable import MacVMCore

final class UbuntuSetupTests: XCTestCase {
    func testAccountAndPublicKeyValidation() throws {
        for username in ["root", "_apt", "name;touch", "UPPER", "a\nb", String(repeating: "a", count: 33)] {
            XCTAssertThrowsError(try UbuntuSetup.validateUsername(username))
        }
        XCTAssertNoThrow(try UbuntuSetup.validateUsername("macvm-test"))
        XCTAssertThrowsError(try UbuntuSetup.validatePassword("short", confirmation: "short"))
        XCTAssertThrowsError(try UbuntuSetup.validatePassword("test-password", confirmation: "different"))
        XCTAssertNoThrow(try UbuntuSetup.validatePassword("test-password", confirmation: "test-password"))
        XCTAssertThrowsError(try UbuntuSetup.validatePublicKey("-----BEGIN OPENSSH PRIVATE KEY-----"))
        XCTAssertThrowsError(try UbuntuSetup.validatePublicKey("ssh-ed25519 " + Data(repeating: 0, count: 64).base64EncodedString()))
        let key = Data([0, 0, 0, 11]) + Data("ssh-ed25519".utf8) + Data([0, 0, 0, 32]) + Data(repeating: 1, count: 32)
        XCTAssertNoThrow(try UbuntuSetup.validatePublicKey("ssh-ed25519 " + key.base64EncodedString() + " test"))
        XCTAssertThrowsError(try UbuntuSetup.validatePublicKey("ssh-rsa " + key.base64EncodedString()))
    }
    func testProfileRequirementsAndNonSecretMetadata() throws {
        var record = VirtualMachineRecord(name: "Ubuntu", system: .linux, memoryGB: 2, diskGB: 16)
        record.ubuntuSetup = UbuntuSetup(profile: .gnome, username: "macvm-test")
        XCTAssertThrowsError(try VMStorage.validate(record))
        record.ubuntuSetup?.profile = .server
        XCTAssertNoThrow(try VMStorage.validate(record))
        record.networkEnabled = false
        XCTAssertThrowsError(try VMStorage.validate(record))
        record.ubuntuSetup?.completed = true
        XCTAssertNoThrow(try VMStorage.validate(record))
        let data = try JSONEncoder().encode(record)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("password"))
        XCTAssertEqual(try JSONDecoder().decode(VirtualMachineRecord.self, from: data), record)
    }
    func testOfficialCatalogSelectsOnlyExactArm64Disk() throws {
        let sha = String(repeating: "a", count: 64)
        let image = try UbuntuImageCatalog.parse("\(sha) *ubuntu-26.04-server-cloudimg-arm64.img\n", release: .resolute)
        XCTAssertEqual(image.sha256, sha)
        XCTAssertTrue(image.managedName.hasPrefix("MacVM-Ubuntu-26.04-"))
        XCTAssertThrowsError(try UbuntuImageCatalog.parse("\(sha) *ubuntu-26.04-server-cloudimg-amd64.img", release: .resolute))
        XCTAssertThrowsError(try UbuntuImageCatalog.parse("\(sha) *../ubuntu-26.04-server-cloudimg-arm64.img", release: .resolute))
        XCTAssertThrowsError(try UbuntuImageCatalog.parse("\(sha) *ubuntu-26.04-server-cloudimg-arm64.img\n\(sha) *ubuntu-26.04-server-cloudimg-arm64.img", release: .resolute))
    }
}
