import XCTest

/// The leave-stream hold (Start + Select + L1 + R1) fades the video and shows
/// a ring. That feedback used to exist only on the iPad, so with a TV attached
/// the screen people were watching showed nothing. iOS-only UI the macOS
/// runner can't render, so the wiring is pinned by source.
final class StreamExitOverlayWiringTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testIPadAndTVDrawTheSameExitOverlay() throws {
        let root = try source("VibeLight/UI/RootView.swift")
        XCTAssertTrue(root.contains(".overlay { StreamExitOverlay() }"))
        let app = try source("VibeLight/App/iOS/VibeLightApp.swift")
        XCTAssertTrue(app.contains("ExternalDisplay.shared.setStreamOverlayBuilder"))
        XCTAssertTrue(app.contains("rootView: StreamExitOverlay()"))
    }

    /// The TV overlay is installed with each display's stream window.
    func testTVInstallsTheOverlayOnConnect() throws {
        let display = try source("VibeLight/App/iOS/ExternalDisplay.swift")
        let start = try XCTUnwrap(display.range(of: "func sceneConnected(_ ws: UIWindowScene) {"))
        let end = try XCTUnwrap(display.range(of: "\n    }\n", range: start.upperBound..<display.endIndex))
        XCTAssertTrue(display[start.upperBound..<end.lowerBound].contains("installStreamOverlay()"))
    }
}
