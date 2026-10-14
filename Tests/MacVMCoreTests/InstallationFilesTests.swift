import XCTest
@testable import MacVMCore

final class InstallationFilesTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacVM-images-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    func testPendingRestoreProtectedAndCompletedImageCanBeRemoved() throws {
        let image = root.appendingPathComponent("macOS.ipsw"); try Data("restore".utf8).write(to: image)
        var record = VirtualMachineRecord(name: "Mac", system: .macOS, cpuCount: 2)
        record.restoreImagePath = image.path
        let bundle = try VMStorage.createEmptyBundle(record: record, location: root)
        var entry = VMEntry(record: record, url: bundle)
        XCTAssertNotNil(InstallationFiles.deletionBlocker(image, entries: [entry]))
        XCTAssertThrowsError(try InstallationFiles.moveToTrash(image, entries: [entry], trash: { _ in XCTFail("Must not remove pending restore") }))
        record.installationPending = false; record.restoreImagePath = nil; try record.save(to: bundle); entry.record = record
        var removed: URL?
        try InstallationFiles.moveToTrash(image, entries: [entry], trash: { removed = $0 })
        XCTAssertEqual(removed, image)
    }
    func testMountedInstallerAndRunningMachineProtected() throws {
        var record = VirtualMachineRecord(name: "Linux", system: .linux, cpuCount: 2, diskGB: 16)
        let bundle = try VMStorage.createEmptyBundle(record: record, location: root)
        let iso = bundle.appendingPathComponent("Installer.iso"); try Data("iso".utf8).write(to: iso)
        var entry = VMEntry(record: record, url: bundle)
        XCTAssertThrowsError(try InstallationFiles.moveToTrash(iso, entries: [entry], trash: { _ in XCTFail() }))
        record.bootFromInstaller = false; try record.save(to: bundle); entry.record = record
        let lock = try VMLock(directory: bundle)
        XCTAssertThrowsError(try InstallationFiles.moveToTrash(iso, entries: [entry], trash: { _ in XCTFail() }))
        withExtendedLifetime(lock) {}
    }
    func testLeaseRejectsConcurrentRemovalAndReleasesAfterOperation() throws {
        let image = root.appendingPathComponent("test.iso"); try Data().write(to: image)
        var lease: ImageLease? = try ImageLease(url: image)
        XCTAssertThrowsError(try InstallationFiles.moveToTrash(image, entries: [], trash: { _ in XCTFail() }))
        withExtendedLifetime(lease) {}; lease = nil
        XCTAssertNoThrow(try InstallationFiles.moveToTrash(image, entries: [], trash: { _ in }))
    }
    func testListDeduplicatesAndRejectsSymlinksAndVirtualDisks() throws {
        let image = root.appendingPathComponent("test.iso"); try Data([1, 2, 3]).write(to: image)
        let symlink = root.appendingPathComponent("link.iso"); try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: image)
        let disk = root.appendingPathComponent("Disk.img"); try Data().write(to: disk)
        XCTAssertEqual(InstallationFiles.list(downloads: root, legacyCaches: [root], entries: []).map(\.url), [image])
        XCTAssertThrowsError(try InstallationFiles.moveToTrash(symlink, entries: [], trash: { _ in XCTFail() }))
        XCTAssertThrowsError(try InstallationFiles.moveToTrash(disk, entries: [], trash: { _ in XCTFail() }))
    }
    func testManagedUbuntuDisksAndPartialsAreRemovableButVMDiskIsNot() throws {
        let image = root.appendingPathComponent("MacVM-Ubuntu-26.04-123456abcdef-arm64.img")
        let partial = image.appendingPathExtension("download")
        let disk = root.appendingPathComponent("Disk.img")
        for url in [image, partial, disk] { try Data(repeating: 1, count: 512).write(to: url) }
        let files = InstallationFiles.list(downloads: root, legacyCaches: [], entries: [])
        XCTAssertEqual(Set(files.map(\.url)), [image, partial])
        var lease: ImageLease? = try ImageLease(url: image)
        XCTAssertNotNil(InstallationFiles.deletionBlocker(partial, entries: []))
        lease = nil
        withExtendedLifetime(lease) {}
        try InstallationFiles.moveToTrash(image, entries: [], trash: { try FileManager.default.removeItem(at: $0) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path))
        XCTAssertThrowsError(try InstallationFiles.moveToTrash(disk, entries: [], trash: { try FileManager.default.removeItem(at: $0) }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: disk.path))
    }

    func testSpaceChecksBothVolumesAndCombinedFootprint() {
        let g = VMStorage.gib
        XCTAssertNotNil(InstallationSpace.problem(system: .macOS, downloading: true, vmFree: 80*g, downloadsFree: 80*g, sameVolume: true))
        XCTAssertNil(InstallationSpace.problem(system: .macOS, downloading: true, vmFree: 64*g, downloadsFree: 32*g, sameVolume: false))
        XCTAssertNotNil(InstallationSpace.problem(system: .macOS, downloading: true, vmFree: 100*g, downloadsFree: 10*g, sameVolume: false))
        XCTAssertNil(InstallationSpace.problem(system: .linux, downloading: false, vmFree: 12*g, downloadsFree: 0, sameVolume: false))
    }
}
