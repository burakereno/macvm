import XCTest
@testable import WindowsPrototypeCore

final class DisplayResizeTests: XCTestCase {
    func testWaitsForCapabilityAndPreservesScreenIdentity() throws {
        var resize = DisplayResize()
        resize.desired = try XCTUnwrap(DisplaySize(width: 3024, height: 1860))
        XCTAssertNil(resize.request())
        resize.receivedLayout(id: 7, flags: 1, width: 2560, height: 1600)
        XCTAssertEqual(resize.request(), Data([251,0,11,208,7,68,1,0,0,0,0,7,0,0,0,0,11,208,7,68,0,0,0,1]))
        XCTAssertNil(resize.request(), "Identical view updates must not flood the guest")
        resize.receivedLayout(id: 7, flags: 1, width: 3024, height: 1860)
        XCTAssertNil(resize.request())
        resize.desired = DisplaySize(width: 2000, height: 1300)
        XCTAssertNotNil(resize.request(), "Leaving fullscreen must request the window's pixel size")
    }
    func testBootModeChangeAllowsDesiredResolutionAgain() {
        var resize = DisplayResize()
        resize.desired = DisplaySize(width: 2560, height: 1664)
        resize.receivedLayout(id: 0, flags: 0, width: 1024, height: 768)
        XCTAssertNotNil(resize.request())
        resize.receivedLayout(id: 0, flags: 0, width: 2560, height: 1600)
        XCTAssertNotNil(resize.request())
    }
    func testForwardedAndRejectedRequestsDoNotResizeFramebuffer() {
        for status in [1,2,3,4,99] { XCTAssertFalse(DisplayResize.acceptsLayout(reason: 1, status: status)) }
        XCTAssertTrue(DisplayResize.acceptsLayout(reason: 1, status: 0))
        XCTAssertTrue(DisplayResize.acceptsLayout(reason: 0, status: 4))
    }
    func testInvalidOrOversizedDimensionsAreRejected() {
        XCTAssertNil(DisplaySize(width: 0, height: 0))
        XCTAssertNil(DisplaySize(width: Int.max, height: 1000))
        XCTAssertNil(DisplaySize(width: 8192, height: 8192))
        XCTAssertNotNil(DisplaySize(width: 5120, height: 2880))
    }
}
