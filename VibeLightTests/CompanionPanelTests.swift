import XCTest
@testable import VibeLight

/// The iPad companion panel shown while a TV / monitor owns the launcher.
/// The panel itself is iOS-only SwiftUI the macOS test runner can't render,
/// so its wiring is pinned by source (scoped to the one struct body).
final class CompanionPanelTests: XCTestCase {

    // MARK: - The gate (UX-tv-attached-touch-dead-end)

    private func owns(useTV: Bool = true, tvConnected: Bool = true,
                      streaming: Bool = false, hasGamepad: Bool) -> Bool {
        AppState.companionPanelOwnsIPad(useTV: useTV, tvConnected: tvConnected,
                                        streaming: streaming, hasGamepad: hasGamepad)
    }

    /// The dead end: a TV takes no touch, so with no pad the panel must not
    /// swallow the iPad — the launcher stays there and the TV mirrors it.
    func testTVAttachedWithoutGamepadKeepsLauncherOnIPad() {
        XCTAssertFalse(owns(hasGamepad: false))
    }

    /// The owner's loved behaviour stays: with a pad, the TV takes over.
    func testTVAttachedWithGamepadShowsCompanionPanel() {
        XCTAssertTrue(owns(hasGamepad: true))
    }

    func testNoPanelWhenSettingOffOrNoTVOrStreaming() {
        XCTAssertFalse(owns(useTV: false, hasGamepad: true))
        XCTAssertFalse(owns(tvConnected: false, hasGamepad: true))
        XCTAssertFalse(owns(streaming: true, hasGamepad: true))
    }

    // MARK: - Source pins (checked by source only)

    /// RootView's idle companion overlay goes through the tested rule.
    func testRootViewGatesCompanionOnTheRule() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("VibeLight/UI/RootView.swift"),
                              encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "private var companionOwnsIPad: Bool {"))
        let end = try XCTUnwrap(text.range(of: "\n    }\n", range: start.upperBound..<text.endIndex))
        let getter = text[start.upperBound..<end.lowerBound]
        XCTAssertTrue(getter.contains("AppState.companionPanelOwnsIPad("))
        XCTAssertTrue(getter.contains("hasGamepad: state.controller.hasGamepad"))
        XCTAssertTrue(text.contains("if companionOwnsIPad {\n"
                                    + "                ExternalDisplayPlaceholder(streaming: false)"))
        XCTAssertFalse(text.contains("if tvActive && idle {"))
    }

    /// The owner removed "Use the iPad Instead" — the gamepad gate above is
    /// what keeps the iPad from being a dead end, so the button must not creep
    /// back in.
    func testCompanionPanelHasNoUseTheIPadButton() throws {
        let body = try placeholderSource()
        XCTAssertFalse(body.contains("Use the iPad Instead\")"))
        XCTAssertFalse(body.contains("onUseIPad"))
        XCTAssertFalse(body.contains("Button("))
    }

    /// The body of `ExternalDisplayPlaceholder`, from its declaration to the
    /// closing brace at column 0 — so a pin can't pass on text elsewhere.
    private func placeholderSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("VibeLight/UI/RootView.swift"),
                              encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "private struct ExternalDisplayPlaceholder: View {"))
        let end = try XCTUnwrap(text.range(of: "\n}\n", range: start.upperBound..<text.endIndex))
        return String(text[start.lowerBound..<end.upperBound])
    }

    /// UX-companion-geometry-readout: the "3840×2160 px · … pt @2×" line was a
    /// tuning aid in 42 % grey; it stays in the log, never on the panel.
    func testCompanionPanelShowsNoPixelReadout() throws {
        let body = try placeholderSource()
        XCTAssertFalse(body.contains("geometrySummary"))
        XCTAssertFalse(body.contains("design: .monospaced"))
    }
}
