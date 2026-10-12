import XCTest
@testable import MacVMCore

final class GuestToolsAvailabilityTests: XCTestCase {
    func testChecksOnlyRunningMacOSGuests() {
        XCTAssertTrue(GuestToolsAvailability.shouldCheck(system: .macOS, phase: .running, restoring: false, busy: false))
        XCTAssertFalse(GuestToolsAvailability.shouldCheck(system: .linux, phase: .running, restoring: false, busy: false))
        for phase in [RuntimePhase.starting, .installing, .paused, .stopping, .stopped, .failed] {
            XCTAssertFalse(GuestToolsAvailability.shouldCheck(system: .macOS, phase: phase, restoring: false, busy: false))
        }
        XCTAssertFalse(GuestToolsAvailability.shouldCheck(system: .macOS, phase: .running, restoring: true, busy: false))
        XCTAssertFalse(GuestToolsAvailability.shouldCheck(system: .macOS, phase: .running, restoring: false, busy: true))
    }

    func testBootFailuresWaitBeforeOfferingInstallation() {
        var state = GuestToolsAvailability()
        state.record(connected: false, at: 100)
        state.record(connected: false, at: 144.9)
        XCTAssertEqual(state.status, .checking)
        XCTAssertFalse(state.shouldRemind)
        state.record(connected: false, at: 145)
        XCTAssertEqual(state.status, .notConnected)
        XCTAssertTrue(state.shouldRemind)
    }

    func testLateConnectionClearsWarningAndResetsGraceForSessionChanges() {
        var state = GuestToolsAvailability()
        state.record(connected: false, at: 100)
        state.record(connected: false, at: 145)
        state.record(connected: true, at: 160)
        XCTAssertEqual(state.status, .connected)
        XCTAssertFalse(state.shouldRemind)
        state.record(connected: false, at: 170)
        XCTAssertEqual(state.status, .checking)
        state.record(connected: true, at: 185)
        XCTAssertEqual(state.status, .connected)
    }

    func testLaterOrOpeningGuideSuppressesRepeatedAutomaticReminders() {
        var state = GuestToolsAvailability()
        state.record(connected: false, at: 0)
        state.record(connected: false, at: 45)
        state.markReminderShown()
        XCTAssertFalse(state.shouldRemind)
        state.suspend()
        state.record(connected: false, at: 1000)
        state.record(connected: false, at: 1045)
        XCTAssertEqual(state.status, .notConnected)
        XCTAssertFalse(state.shouldRemind)
    }

    func testPauseOrShutdownTimeDoesNotCountTowardMissingTools() {
        var state = GuestToolsAvailability()
        state.record(connected: false, at: 100)
        state.suspend()
        state.record(connected: false, at: 10000)
        XCTAssertEqual(state.status, .checking)
        state.record(connected: true, at: 10015)
        XCTAssertFalse(state.shouldRemind)
    }
}
