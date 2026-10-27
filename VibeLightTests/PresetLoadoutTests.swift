import XCTest
@testable import VibeLight

/// Presets are "Live Loadout" (owner's pick of five): a short named list,
/// and the loaded preset stays marked when a setting changes — "edited",
/// with the change on the chip — instead of silently going dark.
final class PresetLoadoutTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: What the edited chip says

    func testChangesNameTheNumbers() {
        let couch = StreamSettings(width: 3840, height: 2160, fps: 120, bitrateKbps: 80_000)
        var tweaked = couch
        tweaked.bitrateKbps = 60_000
        XCTAssertEqual(StreamPreset.changes(from: couch, to: tweaked), ["80 → 60 Mbps"])
        tweaked.width = 1920; tweaked.height = 1080
        XCTAssertEqual(StreamPreset.changes(from: couch, to: tweaked).first, "4K → 1080p")
        XCTAssertEqual(StreamPreset.changes(from: couch, to: couch), [])
    }

    func testOtherChangesAreOneEntry() {
        let base = StreamSettings()
        var changed = base
        changed.touchControls.toggle()
        XCTAssertEqual(StreamPreset.changes(from: base, to: changed), ["other settings"])
    }

    // MARK: Names come from the settings, never "Preset 1"

    func testSuggestionsStartWithTheNumbers() {
        let s = StreamSettings(width: 3840, height: 2160, fps: 120, bitrateKbps: 80_000)
        let names = StreamPreset.nameSuggestions(for: s, hostName: "Gaming PC", taken: [])
        XCTAssertEqual(names.first, "4K · 120")
        XCTAssertTrue(names.contains("Gaming PC"))
        XCTAssertFalse(names.contains { $0.hasPrefix("Preset ") })
    }

    func testSuggestionsSkipTakenNamesAndKeepTheCurrentOneFirst() {
        let s = StreamSettings(width: 1920, height: 1080, fps: 60, bitrateKbps: 20_000)
        let fresh = StreamPreset.nameSuggestions(for: s, hostName: nil, taken: ["1080p · 60"])
        XCTAssertEqual(fresh.first, "1080p · 60 2")
        let rename = StreamPreset.nameSuggestions(for: s, hostName: nil, current: "Tailscale", taken: [])
        XCTAssertEqual(rename.first, "Tailscale")
        XCTAssertTrue(rename.contains("Remote"))
    }

    // MARK: Wiring (AppState needs a live app, so pinned by source)

    /// The marker no longer drops on a change; A on the edited chip keeps the
    /// change, in place (same id and name).
    func testEditedPresetStaysMarkedAndAUpdatesIt() throws {
        let app = try source("VibeLight/App/AppState.swift")
        XCTAssertFalse(app.contains("activePresetSlot = nil"))
        XCTAssertTrue(app.contains("if id == activePresetID && isActivePresetEdited { updateActivePreset() }"))
        XCTAssertTrue(app.contains("presets[i].settings = settings"))
        XCTAssertTrue(app.contains("var isActivePresetEdited: Bool { activePreset.map { $0.settings != settings } ?? false }"))
    }

    /// Delete is immediate with Undo on the toast (Y); no confirm card.
    func testDeleteIsUndoableNotConfirmed() throws {
        let app = try source("VibeLight/App/AppState.swift")
        XCTAssertTrue(app.contains("showPresetToast(verb: \"Deleted\", name: removed.name, undo:"))
        XCTAssertTrue(app.contains("if canUndoPresetChange { undoPresetChange() }"))
        let overlays = try source("VibeLight/UI/OverlayViews.swift")
        XCTAssertFalse(overlays.contains("ConfirmClearPresetCard"))
    }

    /// The six-slot store moves over once: slot order and ids kept, empty
    /// slots dropped, unreadable slots kept as bytes, the loaded slot's id
    /// carried over.
    func testSlotStoreMigratesInOrder() throws {
        let app = try source("VibeLight/App/AppState.swift")
        XCTAssertTrue(app.contains("return (decoded.slots.compactMap { $0 }, decoded.raw.compactMap { $0 }, activeID, true)"))
        XCTAssertTrue(app.contains("private static let presetsKey = \"vibelight.presets.v3\""))
    }

    /// Owner: the "Using …" toast needs a fade when it goes. It stays mounted
    /// and fades its opacity out, rather than being removed mid-frame.
    func testToastFadesOut() throws {
        let overlays = try source("VibeLight/UI/OverlayViews.swift")
        XCTAssertTrue(overlays.contains("withAnimation(.easeInOut(duration: 0.6)) { visible = false }"))
        let root = try source("VibeLight/UI/RootView.swift")
        XCTAssertTrue(root.contains("PresetToastHost()"))
        XCTAssertFalse(root.contains("if let toast = state.presetToast"))
    }

    /// The row has no empty slots: chips, then "+" only when the settings
    /// aren't saved anywhere; Settings lost its slot strip for a pill.
    func testRowAndSettings() throws {
        let app = try source("VibeLight/App/AppState.swift")
        XCTAssertTrue(app.contains("presets.map { \"preset:\\($0.id)\" } + (offersSaveCurrentPreset ? [\"preset:add\"] : [])"))
        let settings = try source("VibeLight/UI/SettingsView.swift")
        XCTAssertTrue(settings.contains("PresetStatusPill()"))
        XCTAssertFalse(settings.contains("SettingsPresetSlot"))
    }
}
