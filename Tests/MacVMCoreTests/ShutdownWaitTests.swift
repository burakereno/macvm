import XCTest
@testable import MacVMCore

final class ShutdownWaitTests: XCTestCase {
    func testUnresponsiveGuestTimesOutOnceWithoutBeingMarkedStopped() {
        var wait = ShutdownWait()
        XCTAssertTrue(wait.begin(at: 100))
        XCTAssertEqual(wait.check(isStopped: false, at: 129.9), .waiting)
        XCTAssertEqual(wait.check(isStopped: false, at: 130), .timedOut)
        XCTAssertFalse(wait.isPending)
        XCTAssertNil(wait.check(isStopped: false, at: 160))
    }

    func testRepeatedShutdownDoesNotExtendDeadline() {
        var wait = ShutdownWait()
        wait.begin(at: 100)
        XCTAssertFalse(wait.begin(at: 129))
        XCTAssertEqual(wait.check(isStopped: false, at: 130), .timedOut)
    }

    func testGuestStopWinsEvenAtDeadline() {
        var wait = ShutdownWait()
        wait.begin(at: 100)
        XCTAssertEqual(wait.check(isStopped: true, at: 130), .stopped)
        XCTAssertNil(wait.check(isStopped: true, at: 131))
    }

    func testFinishedOrForcedStopCancelsOldDeadline() {
        var wait = ShutdownWait()
        wait.begin(at: 100)
        wait.clear()
        XCTAssertNil(wait.check(isStopped: false, at: 150))
        XCTAssertTrue(wait.begin(at: 200))
        XCTAssertEqual(wait.check(isStopped: false, at: 201), .waiting)
    }
}
