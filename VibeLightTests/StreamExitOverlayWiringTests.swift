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
        let stop = try XCTUnwrap(engine.range(of: "setStreamInput(active: false)\n                    // Sound follows the picture"))
        let wait = try XCTUnwrap(engine.range(of: "try? await Task.sleep(for: StreamExitOverlay.fireDuration + .milliseconds(120))"))
        let leave = try XCTUnwrap(engine.range(of: "exitCurtain = 1\n                    disconnect()"))
        XCTAssertLessThan(stop.lowerBound, wait.lowerBound)
        XCTAssertLessThan(wait.lowerBound, leave.lowerBound)
    }

    /// Owner: an Alt+Tab ("maybe Win+Tab") button beside stats, and the TV
    /// panel's buttons stacked like the ones over the game.
    func testTaskViewButtonAndVerticalPanel() throws {
        let engine = try source("VibeLight/App/iOS/InProcessStreamEngine.swift")
        XCTAssertTrue(engine.contains("session.sendKeyboardEvent(KeyboardMap.leftWinVK, down: true, modifiers: win)"))
        XCTAssertTrue(engine.contains("session.sendKeyboardEvent(KeyboardMap.leftWinVK, down: false, modifiers: 0)"))
        let controls = try source("VibeLight/App/iOS/StreamControls.swift")
        XCTAssertTrue(controls.contains("controlButton(\"rectangle.on.rectangle\""))
        let root = try source("VibeLight/UI/RootView.swift")
        XCTAssertTrue(root.contains("onTaskView: { state.session.showTaskView() }"))
        XCTAssertTrue(root.contains("VStack(alignment: .trailing, spacing: 22) {\n                                companionButton(\"xmark\""))
    }

    /// Rejoin: a drop with the game still to rejoin holds the picture and
    /// retries instead of ending; B stops it; leaving the app keeps the game
    /// on the PC for the background window instead of /cancel-ing at once.
    func testRejoinAndAppExitWiring() throws {
        let engine = try source("VibeLight/App/iOS/InProcessStreamEngine.swift")
        XCTAssertTrue(engine.contains("beginRejoin(app: app, error: error)"))
        XCTAssertTrue(engine.contains("if rejoin != nil {   // a rejoin try that didn't connect"))
        let state = try source("VibeLight/App/AppState.swift")
        XCTAssertTrue(state.contains("if session.rejoin != nil {\n            if event == .back {"))
        XCTAssertTrue(state.contains("session.disconnect()   // the still-running card comes up underneath"))
        XCTAssertFalse(state.contains("await stopStreamForAppExit(budget: .milliseconds(2500))\n            session.disconnect()"),
                       "the old exit quit the game within 2.5 s")
        XCTAssertTrue(state.contains("presentPendingAppExitIfAny()"))
        let app = try source("VibeLight/App/iOS/VibeLightApp.swift")
        XCTAssertTrue(app.contains("state.handleAppDidBecomeActive()"))
        XCTAssertTrue(app.contains(".background { StreamNotices(interactive: false) }"))
        let root = try source("VibeLight/UI/RootView.swift")
        XCTAssertTrue(root.contains(".overlay { StreamNotices(showsPill: !dimmedOnTV) }"))
    }

    /// Link Governor: steps go through Vibepollo's runtime /bitrate, and the
    /// stats loop feeds it even with the HUD off.
    func testLinkGovernorWiring() throws {
        let api = try source("VibeLight/Core/HostAPIClient.swift")
        XCTAssertTrue(api.contains("path: \"/bitrate\""))
        let engine = try source("VibeLight/App/iOS/InProcessStreamEngine.swift")
        XCTAssertTrue(engine.contains("guard active, showPerfOverlay || governor != nil, let session else { return }"))
        XCTAssertTrue(engine.contains("let applied = try await api.setBitrate(kbps: step.to, for: host, at: address)"))
    }

    /// The grey pill takes no touches; only StreamView's corner swipe opens.
    func testTheCornerTapBelongsToTheGame() throws {
        let controls = try source("VibeLight/App/iOS/StreamControls.swift")
        XCTAssertFalse(controls.contains(".onTapGesture { reveal() }"))
        XCTAssertTrue(controls.contains(".onChange(of: pulls) { _, _ in reveal() }"))
        let view = try source("VibeLight/App/iOS/StreamView.swift")
        XCTAssertTrue(view.contains("engine.pullStreamControls()"))
    }

    /// Owner: "the outside ring thing twice". With Start still held after the
    /// fire, the Menu latch's own re-forward (not the ControllerManager) saw
    /// the whole chord and started a second hold, so Frame Trace traced again
    /// instead of the fire. Forwarding stops with stream input.
    func testHeldChordCannotStartASecondHold() throws {
        let engine = try source("VibeLight/App/iOS/InProcessStreamEngine.swift")
        XCTAssertTrue(engine.contains("private func setStreamInput(active: Bool) {\n        streamInputLive = active"))
        XCTAssertTrue(engine.contains("private func forward(_ pad: GCExtendedGamepad) {\n        guard streamInputLive, let session else { return }"))
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

/// Leaving the stream, audio (owner): the game goes muffled the moment the
/// chord is held, deeper as it fills, opens back up if let go, and fades to
/// silence during the fire — glided per sample in MoonlightSession.
final class LeaveAudioTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testMuffleFollowsTheHoldAndFadeFollowsTheFire() throws {
        let engine = try source("VibeLight/App/iOS/InProcessStreamEngine.swift")
        XCTAssertTrue(engine.contains("quitHoldStartedAt = Date()\n        // Owner: from the moment the chord is held"))
        XCTAssertTrue(engine.contains("session?.setAudioMuffle(Self.leaveMuffle(elapsed: elapsed))"))
        XCTAssertTrue(engine.contains("session?.setAudioMuffle(0)   // let go early"))
        XCTAssertTrue(engine.contains("session?.fadeOutAudio(over: Self.leaveAudioFade)"))
    }

    func testEffectsRunOnTheRenderThreadAndResetPerStream() throws {
        let audio = try source("VibeLight/Streaming/MoonlightSession.mm")
        XCTAssertTrue(audio.contains("ArApplyLeaveEffects((int16_t *)out"))
        XCTAssertTrue(audio.contains("sMuffleTarget.store(0.0f); sGainTarget.store(1.0f);"))
    }

    /// Owner: "a weird audio click … on launch". The Select chime was cut off
    /// mid-wave when the stream switched the audio session a few ms after the
    /// press; now the session changes only once the chime is over, and game
    /// audio fades in from its first samples instead of cutting in.
    func testLaunchHasNoClick() throws {
        let engine = try source("VibeLight/App/iOS/InProcessStreamEngine.swift")
        let take = try XCTUnwrap(engine.range(of: "await takeAudioSession()"))
        let resume = try XCTUnwrap(engine.range(of: "sessionUrl = try await api.resume("))
        XCTAssertLessThan(resume.lowerBound, take.lowerBound, "the session switches after the host requests")
        XCTAssertTrue(engine.contains("private func takeAudioSession() async {\n        await MenuSFX.handOffToStream()"))
        let sfx = try source("VibeLight/UI/MenuSFX.swift")
        XCTAssertTrue(sfx.contains("static func handOffToStream() async"))
        let audio = try source("VibeLight/Streaming/MoonlightSession.mm")
        XCTAssertTrue(audio.contains("sMuffle = 0.0f; sGain = 0.0f; sAwaitingFirstAudio = true;"))
        XCTAssertTrue(audio.contains("if (take == 0) return noErr;   // still silence: the fade-in waits for sound"))
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

    /// The engine never reads the display: its size reaches the stream only
    /// through Match TV, which the owner opted into (Settings ▸ Windows
    /// Helper; needs VibeLight Helper on the PC) — AppState's launchSettings
    /// and resize. See WindowsHelperTests.
    func testDisplaySizeReachesTheStreamOnlyThroughMatchTV() throws {
        let engine = try source("VibeLight/App/iOS/InProcessStreamEngine.swift")
        XCTAssertFalse(engine.contains("pixelSize"))
        let state = try source("VibeLight/App/AppState.swift")
        XCTAssertEqual(state.components(separatedBy: "ExternalDisplay.shared.pixelSize").count - 1, 1)
        XCTAssertTrue(state.contains("guard matchTV, windowsHelperReady, let tv = attachedTVSize else { return nil }"))
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
