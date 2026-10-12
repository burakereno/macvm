import XCTest
import GuestControl
@testable import MacVMCore

final class SharingTests: XCTestCase {
    func testMultipleGuestsCanRunButExcludeApplicationReplacement() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var first: AppUsageLock? = try AppUsageLock(exclusive: false, url: url)
        var second: AppUsageLock? = try AppUsageLock(exclusive: false, url: url)
        XCTAssertThrowsError(try AppUsageLock(exclusive: true, url: url))
        withExtendedLifetime(first) {}; withExtendedLifetime(second) {}; first = nil; second = nil
        let update = try AppUsageLock(exclusive: true, url: url)
        XCTAssertThrowsError(try AppUsageLock(exclusive: false, url: url))
        withExtendedLifetime(update) {}
    }
    func testOldMachineConfigurationKeepsSharingDisabled() throws {
        let record = VirtualMachineRecord(name: "Existing", system: .linux)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        object.removeValue(forKey: "sharedFolders"); object.removeValue(forKey: "clipboardSharingEnabled"); object.removeValue(forKey: "sourceImagePath")
        let old = try JSONDecoder().decode(VirtualMachineRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.clipboardSharingEnabled); XCTAssertNil(old.sharedFolders)
    }
    func testSharingRoundTripAndNamesCannotShadowInstallerShare() throws {
        var record = VirtualMachineRecord(name: "Sharing", system: .linux, cpuCount: 2)
        record.clipboardSharingEnabled = true
        record.sharedFolders = [SharedFolder(name: "Projects", path: "/tmp/projects")]
        XCTAssertNoThrow(try VMStorage.validate(record))
        let imported = record.withoutHostSharing()
        XCTAssertEqual(imported.id, record.id); XCTAssertEqual(imported.name, record.name)
        XCTAssertNil(imported.sharedFolders); XCTAssertEqual(imported.clipboardSharingEnabled, false)
        XCTAssertTrue(record.clipboardSharingEnabled == true)
        XCTAssertEqual(try JSONDecoder().decode(VirtualMachineRecord.self, from: JSONEncoder().encode(record)), record)
        for name in ["../outside", "..", "MacVM Guest Tools", ""] {
            record.sharedFolders = [SharedFolder(name: name, path: "/tmp")]
            XCTAssertThrowsError(try VMStorage.validate(record))
        }
    }
    func testClipboardPreservesUnicodeQuotesAndNewlines() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        let message = GuestControl.ClipboardMessage(text: "Türkçe 🖥️ \"quotes\"\nsecond line", changeCount: 42)
        try GuestControl.writeClipboard(message, to: descriptors[0])
        XCTAssertEqual(try GuestControl.readClipboard(from: descriptors[1]), message)
    }
    func testOversizedClipboardFrameRejectedBeforeAllocation() throws {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        var header: UInt32 = 0xffffffff
        _ = withUnsafeBytes(of: &header) { send(descriptors[0], $0.baseAddress, 4, 0) }
        XCTAssertThrowsError(try GuestControl.readClipboard(from: descriptors[1]))
    }
}
