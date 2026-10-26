import XCTest
import GameController
@testable import VibeLight

/// A key held when the hardware keyboard disconnects never delivers its
/// release, so the controller manager must tell the stream engine, which then
/// sends key-ups for everything still down on the PC
/// (LIF-stream-keys-stuck-after-keyboard-loss). The engine side is wiring
/// (`setStreamInput` → `releaseHeldKeys`) and is checked by source only.
@MainActor
final class KeyboardDisconnectTests: XCTestCase {

    func testKeyboardDisconnectIsReportedToTheStream() {
        let manager = ControllerManager()
        defer { manager.stop() }
        var reports = 0
        manager.onKeyboardDisconnected = { reports += 1 }

        // Posted on the main thread; the observer runs on .main, so delivery
        // is synchronous.
        NotificationCenter.default.post(name: .GCKeyboardDidDisconnect, object: nil)

        XCTAssertEqual(reports, 1)
    }

    func testKeyboardConnectIsNotReportedAsADisconnect() {
        let manager = ControllerManager()
        defer { manager.stop() }
        var reports = 0
        manager.onKeyboardDisconnected = { reports += 1 }

        NotificationCenter.default.post(name: .GCKeyboardDidConnect, object: nil)

        XCTAssertEqual(reports, 0)
    }
}
