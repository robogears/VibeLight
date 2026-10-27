#if os(macOS)
import AppKit
import IOBluetooth

/// Turns Bluetooth game controllers off when VibeLight quits or the Mac's
/// displays go to sleep (owner's call), so a pad isn't left on draining its
/// battery after you've stopped playing.
///
/// macOS has no "power off" command for a controller; closing its Bluetooth
/// connection is the lever. PlayStation and Switch pads power down when
/// their host drops them (the same thing DS4Windows' "disconnect" relies
/// on); other pads blink while searching, then sleep on their own timer.
/// Only CLASSIC Bluetooth connections can be closed this way — an Xbox pad
/// on Bluetooth LE (Series-era firmware) isn't reachable through IOBluetooth
/// and is left alone.
///
/// iPadOS offers no equivalent: an app can't reach the system's Bluetooth
/// connections at all, so this is Mac-only.
@MainActor
enum ControllerPowerOff {

    /// Bluetooth class of device: major class Peripheral (0x05) with the
    /// joystick (1) or gamepad (2) subtype in the minor field's low four bits.
    /// Keyboards, mice and headsets never match, so nothing else is touched.
    nonisolated static func isGameController(major: UInt32, minor: UInt32) -> Bool {
        guard major == 0x05 else { return false }
        let subtype = minor & 0x0F
        return subtype == 0x01 || subtype == 0x02
    }

    /// Closes the connection of every connected Bluetooth game controller.
    static func disconnectAll() {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return }
        for device in devices
        where device.isConnected() && isGameController(major: device.deviceClassMajor,
                                                       minor: device.deviceClassMinor) {
            device.closeConnection()
        }
    }

    /// Display sleep → controllers off. Touching IOBluetooth here also makes
    /// macOS ask for Bluetooth access now, at launch — asked first at quit,
    /// the prompt would vanish with the app and the feature never work.
    static func install() -> NSObjectProtocol {
        _ = IOBluetoothDevice.pairedDevices()
        return NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { disconnectAll() }
        }
    }
}
#endif
