import XCTest
@testable import VibeLight

/// Mac: quitting VibeLight or the display sleeping closes the Bluetooth
/// connection of game controllers only — never a keyboard, mouse or headset.
final class ControllerPowerOffTests: XCTestCase {
    private func matches(cod: UInt32) -> Bool {
        // Class of device → IOBluetooth's major (bits 8–12) and minor (bits 2–7).
        ControllerPowerOff.isGameController(major: (cod >> 8) & 0x1F, minor: (cod >> 2) & 0x3F)
    }

    func testGamepadsAndJoysticksMatch() {
        XCTAssertTrue(matches(cod: 0x002508))   // DualSense / DUALSHOCK 4: peripheral, gamepad
        XCTAssertTrue(matches(cod: 0x000504))   // peripheral, joystick
    }

    func testOtherDevicesNeverMatch() {
        XCTAssertFalse(matches(cod: 0x002540))  // keyboard
        XCTAssertFalse(matches(cod: 0x002580))  // mouse
        XCTAssertFalse(matches(cod: 0x240404))  // headset (audio/video major)
        XCTAssertFalse(matches(cod: 0x5A020C))  // phone
    }

    func testQuitDisconnectsButNotWhileHostingTests() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let main = try String(contentsOf: root.appendingPathComponent("VibeLight/App/main.swift"), encoding: .utf8)
        XCTAssertTrue(main.contains("if !Self.isHostingUnitTests() { ControllerPowerOff.disconnectAll() }"))
        XCTAssertTrue(main.contains("screenSleepObserver = ControllerPowerOff.install()"))
    }
}
