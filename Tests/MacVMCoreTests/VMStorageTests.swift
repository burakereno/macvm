import XCTest
@testable import MacVMCore

final class VMStorageTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacVMTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }

    private func linuxMachine() throws -> VMEntry {
        var record = VirtualMachineRecord(name: "Linux", system: .linux, cpuCount: 2, memoryGB: 2, diskGB: 16)
        record.bootFromInstaller = false
        let url = try VMStorage.createEmptyBundle(record: record, location: root)
        try VMConfigurationFactory.prepareLinux(at: url)
        return VMEntry(record: record, url: url)
    }

    func testSparseDiskAndRoundTrip() throws {
        let entry = try linuxMachine()
        XCTAssertEqual(try VMStorage.validateBundle(at: entry.url), entry.record)
        let attributes = try FileManager.default.attributesOfItem(atPath: entry.url.appendingPathComponent("Disk.img").path)
        XCTAssertEqual(attributes[.size] as? UInt64, 16 * VMStorage.gib)
        XCTAssertLessThan(VMStorage.allocatedBytes(at: entry.url.appendingPathComponent("Disk.img")), 1024 * 1024)
    }

    func testLockPreventsConcurrentRunnerAndClone() throws {
        let entry = try linuxMachine()
        var lock: VMLock? = try VMLock(directory: entry.url)
        XCTAssertTrue(VMLock.isHeld(at: entry.url))
        XCTAssertThrowsError(try VMLock(directory: entry.url))
        XCTAssertThrowsError(try VMStorage.clone(entry, to: root))
        withExtendedLifetime(lock) {}
        lock = nil
        XCTAssertFalse(VMLock.isHeld(at: entry.url))
    }

    func testCloneHasIndependentIdentityAndDisk() throws {
        let entry = try linuxMachine()
        let disk = entry.url.appendingPathComponent("Disk.img")
        let handle = try FileHandle(forWritingTo: disk)
        try handle.write(contentsOf: Data("original".utf8)); try handle.close()
        let clone = try VMStorage.clone(entry, to: root)
        XCTAssertNotEqual(clone.id, entry.id)
        XCTAssertNotEqual(clone.record.macAddress, entry.record.macAddress)
        XCTAssertEqual(try VMStorage.validateBundle(at: clone.url), clone.record)
        let copyHandle = try FileHandle(forWritingTo: clone.url.appendingPathComponent("Disk.img"))
        try copyHandle.write(contentsOf: Data("modified".utf8)); try copyHandle.close()
        let originalHandle = try FileHandle(forReadingFrom: disk)
        XCTAssertEqual(try originalHandle.read(upToCount: 8), Data("original".utf8)); try originalHandle.close()
    }

    func testRejectUnsupportedSchemaAndDiskSymlink() throws {
        let entry = try linuxMachine()
        var future = entry.record; future.schemaVersion = 2
        try future.save(to: entry.url)
        XCTAssertThrowsError(try VirtualMachineRecord.load(from: entry.url))
        try entry.record.save(to: entry.url)
        let disk = entry.url.appendingPathComponent("Disk.img")
        try FileManager.default.removeItem(at: disk)
        let outside = root.appendingPathComponent("outside.img")
        try Data().write(to: outside)
        try FileManager.default.createSymbolicLink(at: disk, withDestinationURL: outside)
        XCTAssertThrowsError(try VMStorage.validateBundle(at: entry.url))
    }

    func testRejectInvalidResources() throws {
        var record = VirtualMachineRecord(name: "", system: .macOS)
        XCTAssertThrowsError(try VMStorage.validate(record, hostCPUs: 8, hostMemory: 16 * VMStorage.gib))
        record.name = "Test"; record.cpuCount = 9
        XCTAssertThrowsError(try VMStorage.validate(record, hostCPUs: 8, hostMemory: 16 * VMStorage.gib))
        record.cpuCount = 2; record.memoryGB = 17
        XCTAssertThrowsError(try VMStorage.validate(record, hostCPUs: 8, hostMemory: 16 * VMStorage.gib))
        record.memoryGB = 4; record.diskGB = 16
        XCTAssertThrowsError(try VMStorage.validate(record, hostCPUs: 8, hostMemory: 16 * VMStorage.gib))
    }

    func testIncompleteMacOSCannotBeCloned() throws {
        let record = VirtualMachineRecord(name: "Installing", system: .macOS, cpuCount: 2, memoryGB: 4)
        let url = try VMStorage.createEmptyBundle(record: record, location: root)
        XCTAssertThrowsError(try VMStorage.clone(VMEntry(record: record, url: url), to: root))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
    }

    func testPortableMachineCanBeImportedBeforeReducingResources() throws {
        let entry = try linuxMachine()
        var record = entry.record
        record.cpuCount = ProcessInfo.processInfo.activeProcessorCount + 1
        record.memoryGB = Int(ProcessInfo.processInfo.physicalMemory / VMStorage.gib) + 1
        try record.save(to: entry.url)
        XCTAssertEqual(try VMStorage.validateBundle(at: entry.url), record)
        XCTAssertThrowsError(try VMConfigurationFactory.make(record: record, directory: entry.url))
    }
}
