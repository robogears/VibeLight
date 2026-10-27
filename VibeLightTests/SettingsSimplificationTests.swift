import XCTest
@testable import VibeLight

/// The owner's settings trim (Oct 2026): Use TV / Monitor, Game
/// Optimizations, Quit Game on Disconnect and Quit Game on App Exit are no
/// longer options, and touch is on by default.
final class SettingsSimplificationTests: XCTestCase {

    /// A value saved before the trim (in settings or a preset) has no hidden
    /// effect left: each removed option reads as its old default.
    func testRemovedOptionsArePinnedOnDecode() throws {
        let json = #"{"externalDisplay":false,"gameOptimizations":false,"quitAppAfter":true,"stopStreamOnExit":false}"#
        let s = try JSONDecoder().decode(StreamSettings.self, from: Data(json.utf8))
        XCTAssertTrue(s.externalDisplay)
        XCTAssertTrue(s.gameOptimizations)
        XCTAssertFalse(s.quitAppAfter)
        XCTAssertTrue(s.stopStreamOnExit)
    }

    func testTouchIsOnByDefault() {
        XCTAssertTrue(StreamSettings().touchControls)
        XCTAssertTrue(StreamSettings().touchWithController)
    }

    func testRemovedRowsAreGone() {
        let rows = Set(AppState.SettingsRow.allCases.map(\.rawValue))
        for removed in ["externalDisplay", "gameOpt", "quitAppAfter", "stopStreamOnExit"] {
            XCTAssertFalse(rows.contains(removed), removed)
        }
        // Performance Stats stays: it is each preset's starting point for the
        // in-stream button.
        XCTAssertTrue(rows.contains("performanceOverlay"))
    }

    /// The in-stream button changes THIS stream only, never the setting —
    /// that would detach the active preset — and every launch starts from
    /// the setting again.
    func testStatsButtonNeverWritesTheSetting() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let engine = try String(contentsOf: root.appendingPathComponent("VibeLight/App/iOS/InProcessStreamEngine.swift"),
                                encoding: .utf8)
        let start = try XCTUnwrap(engine.range(of: "func togglePerformanceStats() {"))
        let end = try XCTUnwrap(engine.range(of: "\n    }\n", range: start.upperBound..<engine.endIndex))
        XCTAssertFalse(engine[start.upperBound..<end.lowerBound].contains("settings"))
        XCTAssertTrue(engine.contains("showPerfOverlay = settings.performanceOverlay"))
    }
}
