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

    /// Frame Trace (owner's pick): two accent lines from the top centre, each
    /// trimmed to half the progress, meeting at the bottom.
    func testExitOverlayIsFrameTrace() throws {
        let root = try source("VibeLight/UI/RootView.swift")
        XCTAssertTrue(root.contains("private struct ScreenPerimeter: Shape"))
        XCTAssertTrue(root.contains("frame.trim(from: 0, to: p / 2)"))
        XCTAssertTrue(root.contains("Leaving the stream "))
    }

    /// Fire stops input at once but tears the stream view down only after the
    /// swell to black — disconnecting in the same turn cut it off.
    func testFireWaitsForTheSwellBeforeTeardown() throws {
        let engine = try source("VibeLight/App/iOS/InProcessStreamEngine.swift")
        let stop = try XCTUnwrap(engine.range(of: "setStreamInput(active: false)\n                    try? await Task.sleep(for: StreamExitOverlay.fireDuration"))
        let leave = try XCTUnwrap(engine.range(of: "exitCurtain = 1\n                    disconnect()"))
        XCTAssertLessThan(stop.lowerBound, leave.lowerBound)
    }

    /// Owner: black for about a second while the stream closes, then a slow
    /// fade into the menu — on the iPad and on the TV launcher.
    func testCurtainCoversTeardownThenFadesSlowly() throws {
        let engine = try source("VibeLight/App/iOS/InProcessStreamEngine.swift")
        XCTAssertTrue(engine.contains("nonisolated static let leaveHoldSeconds = 1.7"))
        XCTAssertTrue(engine.contains("disconnect()\n                    try? await Task.sleep(for: Self.exitBlackHold)\n                    exitCurtain = 0"))
        let root = try source("VibeLight/UI/RootView.swift")
        XCTAssertEqual(root.components(separatedBy: ".overlay { ExitCurtain() }").count - 1, 2,
                       "one curtain on the iPad, one on the TV launcher")
    }

    /// The stats task re-checks cancellation after its sleep, or a turned-off
    /// HUD came back frozen one second later.
    func testStatsTaskStopsAfterCancellation() throws {
        let engine = try source("VibeLight/App/iOS/InProcessStreamEngine.swift")
        XCTAssertTrue(engine.contains("guard !Task.isCancelled, let self, let session else { return }"))
    }

    /// The TV overlay is installed with each display's stream window.
    func testTVInstallsTheOverlayOnConnect() throws {
        let display = try source("VibeLight/App/iOS/ExternalDisplay.swift")
        let start = try XCTUnwrap(display.range(of: "func sceneConnected(_ ws: UIWindowScene) {"))
        let end = try XCTUnwrap(display.range(of: "\n    }\n", range: start.upperBound..<display.endIndex))
        XCTAssertTrue(display[start.upperBound..<end.lowerBound].contains("installStreamOverlay()"))
    }
}

/// Plugging a TV in or out mid-stream (owner: perfect continuity).
final class TVHandOffTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Without a TV the companion holds lit with a fresh clock, so plugging
    /// one in shows "Playing on …" instead of going straight to black; and
    /// the screen taking the picture gets a keyframe.
    func testHandOffKeepsThePanelAndRequestsAKeyframe() throws {
        let engine = try source("VibeLight/App/iOS/InProcessStreamEngine.swift")
        XCTAssertTrue(engine.contains("if companionLive != wasLive {\n                    wasLive = companionLive\n                    session?.requestKeyframe()"))
        XCTAssertTrue(engine.contains("if companionView != .panel { setCompanionView(.panel) }\n                    lastCompanionActivity = .now\n                    continue"))
    }

    /// Stream quality never depends on the display: nothing feeds the TV's
    /// size into the stream settings.
    func testDisplaySizeNeverReachesStreamSettings() throws {
        let engine = try source("VibeLight/App/iOS/InProcessStreamEngine.swift")
        XCTAssertFalse(engine.contains("pixelSize"))
    }
}

/// Frame Trace follows the clock between the engine's 40 ms steps (owner:
/// smoother). iOS-only types, so pinned by source.
final class ExitOverlaySmoothnessTests: XCTestCase {
    func testOverlayRedrawsEveryFrameFromTheHoldStart() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("VibeLight/UI/RootView.swift"), encoding: .utf8)
        // Runs through the fire too: the close / diamond / black follows the clock.
        XCTAssertTrue(view.contains("TimelineView(.animation(paused: p == nil))"))
        // The old swell (a stroke grown past the screen) ended on the whole game.
        XCTAssertFalse(view.contains("lineWidth: fired ? 2 * hypot("))
        XCTAssertTrue(view.contains("startedAt: state.session.quitHoldStartedAt"))
        XCTAssertFalse(view.contains(".animation(.linear(duration: 0.05), value: state.session.streamQuitProgress)"))
    }
}

/// The starting card is Poster Lift (owner's pick of five): the pressed tile
/// lifts to centre, real steps underneath, grows into the stream.
final class PosterLiftWiringTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testStartingCardIsPosterLift() throws {
        let overlays = try source("VibeLight/UI/OverlayViews.swift")
        XCTAssertTrue(overlays.contains("case .sessionHUD:\n                PosterLiftCard()"))
        XCTAssertFalse(overlays.contains("struct SessionHUD"))
        XCTAssertTrue(overlays.contains("liftOff(from: lift?.artFrames[state.liftSourceID ?? \"app:\\(state.appKey(app))\"], to: frame)"))
    }

    /// Tiles report where their art is, in the launcher's shared space, and
    /// hide while lifted; each launcher (iPad, TV) keeps its own positions.
    func testTilesFeedTheLift() throws {
        let tile = try source("VibeLight/UI/AppTileView.swift")
        XCTAssertTrue(tile.contains("lift?.artFrames[focusID] = $0"))
        XCTAssertTrue(tile.contains(".opacity(isLifted ? 0 : 1)"))
        let root = try source("VibeLight/UI/RootView.swift")
        XCTAssertTrue(root.contains("@State private var lift = LiftGeometry()"))
        XCTAssertTrue(root.contains(".coordinateSpace(.named(LiftGeometry.space))"))
    }

    /// The status line shows the engine's real steps; the TV keeps the
    /// launcher (and the card) until the first frame, then cross-fades.
    func testRealStepsAndTheTVHandOff() throws {
        let engine = try source("VibeLight/App/iOS/InProcessStreamEngine.swift")
        for step in ["launchStep = .checkingHost", "launchStep = .starting(resume: info.runningAppID != nil)",
                     "launchStep = .connecting", "launchStep = .waitingForVideo"] {
            XCTAssertTrue(engine.contains(step), step)
        }
        XCTAssertTrue(engine.contains("ExternalDisplay.shared.showStream()"))
        let tv = try source("VibeLight/App/iOS/ExternalDisplay.swift")
        XCTAssertTrue(tv.contains("func showStream()"))
        XCTAssertTrue(tv.contains("if streamShowing { window.rootViewController = streamVC } else { showLauncher() }"))
    }

    /// Engines that can't see their steps (the Mac's helper) report none, so
    /// the card falls back to the phase.
    func testEnginesWithoutStepsReportNone() throws {
        let contracts = try source("VibeLight/Core/Contracts.swift")
        XCTAssertTrue(contracts.contains("extension StreamEngine {\n    /// Engines that can't see their steps"))
        XCTAssertTrue(contracts.contains("var launchStep: LaunchStep? { nil }"))
    }
}
