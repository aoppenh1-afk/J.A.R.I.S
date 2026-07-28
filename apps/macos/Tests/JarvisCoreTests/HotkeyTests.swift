import Carbon.HIToolbox
import XCTest
@testable import JarvisCore

final class HotkeyTests: XCTestCase {
    func testMapsPressedAndReleasedEvents() {
        XCTAssertEqual(HotkeyPhase(eventKind: UInt32(kEventHotKeyPressed)), .pressed)
        XCTAssertEqual(HotkeyPhase(eventKind: UInt32(kEventHotKeyReleased)), .released)
        XCTAssertNil(HotkeyPhase(eventKind: 999))
    }
}
