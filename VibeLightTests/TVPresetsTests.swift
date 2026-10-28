import XCTest
@testable import VibeLight

/// TV Presets (Settings ▸ Video, iPad): one remembered preset per TV,
/// swapped in for the presets row while that TV is plugged in, and followed
/// mid-game with Match TV.
@MainActor
final class TVPresetsTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TVPresetsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private let modes4K = [(width: 3840, height: 2160), (width: 1920, height: 1080), (width: 1280, height: 720)]

    // MARK: - Knowing a TV

    /// The HDMI name can arrive a moment after the TV, so it only labels the
    /// chip: the same TV keeps one key with or without it.
    func testATVKeepsItsKeyWhetherOrNotIOSNamesIt() {
        let named = TVIdentity(hdmiName: "LG TV", width: 3840, height: 2160, maxFPS: 120, modes: modes4K)
        let unnamed = TVIdentity(hdmiName: nil, width: 3840, height: 2160, maxFPS: 120, modes: Array(modes4K.reversed()))
        XCTAssertEqual(named.key, unnamed.key)
        XCTAssertEqual(named.name, "LG TV")
        XCTAssertEqual(unnamed.name, "4K TV · 120 Hz")
        XCTAssertEqual(TVIdentity(hdmiName: "HDMI", width: 1920, height: 1080, maxFPS: 60, modes: []).name, "1080p TV")
    }

    /// Different TVs (another refresh rate, other modes) are different TVs.
    func testDifferentTVsGetDifferentKeys() {
        let a = TVIdentity(hdmiName: nil, width: 3840, height: 2160, maxFPS: 120, modes: modes4K)
        let b = TVIdentity(hdmiName: nil, width: 3840, height: 2160, maxFPS: 60, modes: modes4K)
        let c = TVIdentity(hdmiName: nil, width: 3840, height: 2160, maxFPS: 120, modes: Array(modes4K.prefix(2)))
        XCTAssertNotEqual(a.key, b.key)
        XCTAssertNotEqual(a.key, c.key)
    }

    // MARK: - A new TV's preset

    /// Owner: the TV's native resolution and refresh rate, at 50 Mbps; the
    /// rest comes from the settings in use before.
    func testANewTVStartsAtItsNativeResolutionAndRefreshAt50Mbps() {
        var base = StreamSettings.fallback
        base.touchControls = false
        let tv = TVIdentity(hdmiName: "LG TV", width: 3840, height: 2160, maxFPS: 120, modes: modes4K)
        let preset = TVPreset.starting(for: tv, from: base)
        XCTAssertEqual(preset.settings.width, 3840)
        XCTAssertEqual(preset.settings.height, 2160)
        XCTAssertEqual(preset.settings.fps, 120)
        XCTAssertEqual(preset.settings.bitrateKbps, 50_000)
        XCTAssertFalse(preset.settings.touchControls)
        XCTAssertEqual(preset.name, "LG TV")
        XCTAssertEqual(preset.key, tv.key)
        XCTAssertEqual(TVPreset.startingFPS(maxFPS: 0), 60)   // iOS didn't say
    }

    func testTVPresetsAreStoredAndAnUnreadableOneIsSkipped() throws {
        let tv = TVIdentity(hdmiName: nil, width: 1920, height: 1080, maxFPS: 60, modes: [])
        let good = TVPreset.starting(for: tv, from: .fallback)
        var list = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode([good])) as? [Any])
        list.append(["key": 5])
        defaults.set(try JSONSerialization.data(withJSONObject: list), forKey: AppState.tvPresetsKey)
        XCTAssertEqual(AppState.storedTVPresets(in: defaults), [good])
    }

    // MARK: - Wiring

    /// Its own row on the iPad's Video tab; TV Resolution steps aside while
    /// it's on (owner); the TV's preset stands alone in the row.
    func testTheRowAndWhatItTakesOver() throws {
        XCTAssertEqual(AppState.SettingsRow.tvPresets.title, "TV Presets")
        let state = try source("VibeLight/App/AppState.swift")
        XCTAssertTrue(state.contains("[.resolution, .fps, .bitrate, .adaptiveBitrate, .tvPresets]"))
        XCTAssertTrue(state.contains("case .tvResolution: !windowsHelperReady || !matchTV || tvPresetsEnabled"))
        XCTAssertTrue(state.contains("var canSaveNewPreset: Bool { liveTV == nil && presets.count < Self.maxPresets }"))
        XCTAssertTrue(state.contains("if liveTV == nil { ids.append(\"presetmenu:delete\") }"))
        // Edits while a TV is live go to its preset, never over the usual ones.
        XCTAssertTrue(state.contains("            if liveTV != nil {\n                saveLiveTVPreset()\n                return\n            }\n            persistSettings()"))
    }

    /// Mid-game, with Match TV, the stream restarts with the TV preset's
    /// size, frame rate and bitrate, and the PC's display follows its frame rate.
    func testMidGameTheWholePresetFollowsTheTV() throws {
        let state = try source("VibeLight/App/AppState.swift")
        XCTAssertTrue(state.contains("if !session.resize(width: settings.width, height: settings.height, fps: settings.fps,\n                               bitrateKbps: settings.bitrateKbps, reason: reason) {"))
        XCTAssertTrue(state.contains("let refreshHz = liveTV != nil ? settings.fps : nil"))
        let engine = try source("VibeLight/App/iOS/InProcessStreamEngine.swift")
        XCTAssertTrue(engine.contains("func resize(width: Int, height: Int, fps: Int?, bitrateKbps: Int?, reason: String) -> Bool {"))
        XCTAssertTrue(engine.contains("governor = adaptiveBitrate ? LinkGovernor(ceilingKbps: newBitrate, fps: newFPS) : nil"))
        let app = try source("VibeLight/App/iOS/VibeLightApp.swift")
        XCTAssertTrue(app.contains("state.refreshTVPreset()"))
    }
}
