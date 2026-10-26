import XCTest
@testable import VibeLight

/// The iPad companion panel shown while a TV / monitor owns the launcher.
/// The panel itself is iOS-only SwiftUI the macOS test runner can't render,
/// so its wiring is pinned by source (scoped to the one struct body).
final class CompanionPanelTests: XCTestCase {

    // MARK: - Source pins (checked by source only)

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
