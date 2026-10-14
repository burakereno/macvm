import XCTest
import WindowsPrototypeCore
import IOKit.hidsystem

final class WindowsKeyboardTests: XCTestCase {
    func testPhysicalKeysIgnoreHostTurkishAndDeadKeyCharacters() {
        XCTAssertEqual(WindowsKeyboard.keysym(keyCode: 34), 0x69)
        XCTAssertEqual(WindowsKeyboard.keysym(keyCode: 41), 0x3b)
        XCTAssertEqual(WindowsKeyboard.keysym(keyCode: 42), 0x5c)
        XCTAssertEqual(WindowsKeyboard.keysym(keyCode: 47), 0x2e)
        XCTAssertEqual(WindowsKeyboard.keysym(keyCode: 36), 0xff0d)
        XCTAssertNil(WindowsKeyboard.keysym(keyCode: 255))
    }
    func testRightAltAndWindowsKeysRemainDistinct() {
        XCTAssertEqual(WindowsKeyboard.modifier(keyCode: 58), 0xffe9)
        XCTAssertEqual(WindowsKeyboard.modifier(keyCode: 61), 0xffea)
        XCTAssertEqual(WindowsKeyboard.modifier(keyCode: 55), 0xffeb)
        XCTAssertEqual(WindowsKeyboard.modifier(keyCode: 54), 0xffec)
    }
    func testModifierSnapshotPreservesAltGrAndClearsReleasedSide() {
        let option = UInt(NX_ALTERNATEMASK)
        XCTAssertEqual(WindowsKeyboard.modifiers(rawFlags: option | UInt(NX_DEVICERALTKEYMASK)), [0xffea])
        let shift = UInt(NX_SHIFTMASK)
        XCTAssertEqual(WindowsKeyboard.modifiers(rawFlags: shift | UInt(NX_DEVICELSHIFTKEYMASK | NX_DEVICERSHIFTKEYMASK)), [0xffe1, 0xffe2])
        XCTAssertEqual(WindowsKeyboard.modifiers(rawFlags: shift | UInt(NX_DEVICERSHIFTKEYMASK)), [0xffe2])
        XCTAssertEqual(WindowsKeyboard.modifiers(rawFlags: UInt(NX_CONTROLMASK | NX_COMMANDMASK)), [0xffe3, 0xffeb])
        XCTAssertEqual(WindowsKeyboard.modifiers(rawFlags: 0), [])
    }
}
