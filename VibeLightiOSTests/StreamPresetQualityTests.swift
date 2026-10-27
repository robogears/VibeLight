#if os(iOS)
import XCTest
@testable import VibeLight

final class StreamPresetQualityTests: XCTestCase {
    private func restoredPreset(_ settings: StreamSettings) throws -> StreamPreset {
        let saved = StreamPreset(id: "quality-test", name: "Preset", settings: settings)
        return try JSONDecoder().decode(StreamPreset.self, from: JSONEncoder().encode(saved))
    }

    func testTVKeepsTheSaved720p60Preset() throws {
        let preset = try restoredPreset(StreamSettings(
            width: 1280, height: 720, fps: 60, bitrateKbps: 20_000, externalDisplay: true))

        XCTAssertEqual(InProcessStreamEngine.settingsForStream(preset.settings), preset.settings)
    }

    func testTVKeepsTheSaved1080p120Preset() throws {
        let preset = try restoredPreset(StreamSettings(
            width: 1920, height: 1080, fps: 120, bitrateKbps: 40_000, externalDisplay: true))

        XCTAssertEqual(InProcessStreamEngine.settingsForStream(preset.settings), preset.settings)
    }

    func testTVKeeps4K120WhenItIsActuallySelected() throws {
        let preset = try restoredPreset(StreamSettings(
            width: 3840, height: 2160, fps: 120, bitrateKbps: 100_000, externalDisplay: true))

        XCTAssertEqual(InProcessStreamEngine.settingsForStream(preset.settings), preset.settings)
    }

    func testTVRoutingDoesNotChangeQualityAndSDRDoesNotMutateThePreset() throws {
        let preset = try restoredPreset(StreamSettings(
            width: 2560, height: 1440, fps: 60, bitrateKbps: 60_000, hdr: true,
            externalDisplay: true))
        var expected = preset.settings
        expected.hdr = false

        XCTAssertEqual(InProcessStreamEngine.settingsForStream(preset.settings), expected)
        XCTAssertTrue(preset.settings.hdr, "Preparing the stream must not rewrite a saved preset")

        var ipadSettings = preset.settings
        ipadSettings.externalDisplay = false
        var ipadExpected = expected
        ipadExpected.externalDisplay = false
        XCTAssertEqual(InProcessStreamEngine.settingsForStream(ipadSettings), ipadExpected)
    }
}
#endif
