#if DEBUG
import Foundation

/// Debug-only switches that produce states the iOS Simulator can't reach on
/// its own (no TV, no game controller), so the real pixels can be checked
/// without hardware. Read once from the launch environment
/// (`SIMCTL_CHILD_VL_FAKE_TV=1 xcrun simctl launch …`). Never compiled into a
/// Release build; reads nothing private and touches no real host.
enum DebugInstruments {
    /// `VL_FAKE_TV=1` — `ExternalDisplay` reports a connected "Living Room TV"
    /// (no window), so the companion panel's gate can be exercised.
    static let fakeTV: Bool = ProcessInfo.processInfo.environment["VL_FAKE_TV"] == "1"

    /// `VL_FAKE_PAD=xbox|ps|generic` — `ControllerManager.hasGamepad` reports
    /// a connected gamepad, and `glyphStyle` draws that family's glyphs while
    /// no real pad is attached. nil when unset or unrecognised.
    static let fakePad: ControllerGlyphStyle? = {
        switch ProcessInfo.processInfo.environment["VL_FAKE_PAD"] {
        case "xbox": .xbox
        case "ps": .playStation
        case "generic", "1": .generic
        default: nil
        }
    }()

    /// A synthetic selected computer, "Gaming PC", for the empty-shelf states.
    enum FakeHost: String {
        case asleep, offline, unpaired
        case onlineEmpty = "online-empty"
        case notResponding = "notresponding"
    }

    /// `VL_FAKE_HOST=asleep|offline|unpaired|online-empty|notresponding` —
    /// replaces the computer list with one synthetic "Gaming PC" in that state
    /// and no games; it is never refreshed, woken or persisted.
    static let fakeHost: FakeHost? =
        ProcessInfo.processInfo.environment["VL_FAKE_HOST"].flatMap(FakeHost.init(rawValue:))

    enum FakeHostError: String { case long, restarting }

    /// `VL_FAKE_HOST_ERROR=long|restarting` — the header chip shows the
    /// longest saved-computers warning, or the grey "Restarting Gaming PC…".
    static let fakeHostError: FakeHostError? =
        ProcessInfo.processInfo.environment["VL_FAKE_HOST_ERROR"].flatMap(FakeHostError.init(rawValue:))
}
#endif
