import XCTest
import Darwin
import GuestControl

final class GuestControlTests: XCTestCase {
    func testPreloginShutdownRequiresRootAndKnownEmptySessionList() {
        XCTAssertTrue(GuestControl.mayShutDownWithoutSession(consoleUser: nil, consoleUID: 0, processUID: 0, hasUserSessions: false))
        XCTAssertTrue(GuestControl.mayShutDownWithoutSession(consoleUser: "loginwindow", consoleUID: 0, processUID: 0, hasUserSessions: false))
        // A fast-user-switched session, unknown census, and a locked desktop
        // must never take the system path that cannot ask apps to save documents.
        XCTAssertFalse(GuestControl.mayShutDownWithoutSession(consoleUser: "loginwindow", consoleUID: 0, processUID: 0, hasUserSessions: true))
        XCTAssertFalse(GuestControl.mayShutDownWithoutSession(consoleUser: nil, consoleUID: 0, processUID: 0, hasUserSessions: nil))
        XCTAssertFalse(GuestControl.mayShutDownWithoutSession(consoleUser: "test", consoleUID: 501, processUID: 0, hasUserSessions: false))
        XCTAssertFalse(GuestControl.mayShutDownWithoutSession(consoleUser: nil, consoleUID: 501, processUID: 0, hasUserSessions: false))
        XCTAssertFalse(GuestControl.mayShutDownWithoutSession(consoleUser: nil, consoleUID: 0, processUID: 501, hasUserSessions: false))
    }

    func testOnlyActiveOrPreloginSessionCanHandleShutdown() {
        XCTAssertTrue(GuestControl.isActiveSession(consoleUser: nil, consoleUID: 0, processUID: 92))
        XCTAssertTrue(GuestControl.isActiveSession(consoleUser: "loginwindow", consoleUID: 0, processUID: 0))
        XCTAssertFalse(GuestControl.isActiveSession(consoleUser: nil, consoleUID: 0, processUID: 501))
        XCTAssertFalse(GuestControl.isActiveSession(consoleUser: "loginwindow", consoleUID: 0, processUID: 501))
        XCTAssertTrue(GuestControl.isActiveSession(consoleUser: "test", consoleUID: 501, processUID: 501))
        XCTAssertFalse(GuestControl.isActiveSession(consoleUser: "other", consoleUID: 502, processUID: 501))
        XCTAssertFalse(GuestControl.isActiveSession(consoleUser: "test", consoleUID: 501, processUID: 92))
    }

    private func withSockets(_ body: (Int32, Int32) throws -> Void) throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        pair.forEach(GuestControl.configure)
        try body(pair[0], pair[1])
    }

    func testFragmentedFramesAndSeparateMessages() throws {
        try withSockets { writer, reader in
            for byte in (GuestControl.shutdown + "\n" + GuestControl.accepted + "\n").utf8 {
                var byte = byte
                XCTAssertEqual(send(writer, &byte, 1, 0), 1)
            }
            XCTAssertEqual(try GuestControl.readFrame(from: reader), GuestControl.shutdown)
            XCTAssertEqual(try GuestControl.readFrame(from: reader), GuestControl.accepted)
        }
    }

    func testRejectsUnterminatedOversizedAndInvalidUTF8Frames() throws {
        try withSockets { writer, reader in
            let bytes = [UInt8](repeating: 65, count: GuestControl.maxFrameBytes)
            _ = bytes.withUnsafeBytes { send(writer, $0.baseAddress, $0.count, 0) }
            XCTAssertThrowsError(try GuestControl.readFrame(from: reader))
        }
        try withSockets { writer, reader in
            let bytes: [UInt8] = [255, 10]
            _ = bytes.withUnsafeBytes { send(writer, $0.baseAddress, $0.count, 0) }
            XCTAssertThrowsError(try GuestControl.readFrame(from: reader))
        }
    }

    func testClosedPeerAndEmbeddedNewlineFail() throws {
        try withSockets { writer, reader in
            XCTAssertThrowsError(try GuestControl.writeFrame("SHUTDOWN\nSHUTDOWN", to: writer))
            Darwin.shutdown(writer, SHUT_RDWR)
            XCTAssertThrowsError(try GuestControl.readFrame(from: reader))
            Darwin.shutdown(reader, SHUT_WR)
            XCTAssertThrowsError(try GuestControl.writeFrame(GuestControl.shutdown, to: reader))
        }
    }
}
