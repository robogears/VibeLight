import XCTest
@testable import VibeLight

/// The still-running card is Poster Rest (owner's pick of five): the poster
/// you started the game from, LIVE, with Resume / a held Quit / Back to
/// Library beside it.
final class PosterRestTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: Wording

    func testPlayedTime() {
        XCTAssertEqual(AppState.playedText(20), "played under a minute")
        XCTAssertEqual(AppState.playedText(42 * 60 + 30), "played 42 min")
        XCTAssertEqual(AppState.playedText(60 * 60), "played 1 h")
        XCTAssertEqual(AppState.playedText(65 * 60), "played 1 h 5 min")
        XCTAssertEqual(AppState.playedText(-5), "played under a minute")
    }

    func testStatusLine() {
        XCTAssertEqual(AppState.endedStatusLine(game: "Ridgeline", host: "Gaming PC", closed: false, played: 42 * 60),
                       "Still running on Gaming PC · played 42 min")
        XCTAssertEqual(AppState.endedStatusLine(game: "Ridgeline", host: "Gaming PC", closed: true, played: nil),
                       "Ridgeline has closed on Gaming PC")
        // Put up by leaving the app mid-stream: it says why it's there.
        XCTAssertEqual(AppState.endedStatusLine(game: "Ridgeline", host: "Gaming PC", closed: false, played: nil,
                                                leftApp: true),
                       "You left VibeLight · still running on Gaming PC")
    }

    // MARK: Wiring (AppState and the views need a live app, so pinned by source)

    func testCardIsPosterRest() throws {
        let overlays = try source("VibeLight/UI/OverlayViews.swift")
        XCTAssertTrue(overlays.contains("case .sessionEnded(let app):\n                PosterRestCard(app: app)"))
        XCTAssertFalse(overlays.contains("struct SessionEndedCard"))
        // Resume carries on into Poster Lift from this card's poster.
        XCTAssertTrue(overlays.contains("lift?.artFrames[AppState.endedPosterID] = frame"))
        let app = try source("VibeLight/App/AppState.swift")
        XCTAssertTrue(app.contains("launch(app, liftFrom: Self.endedPosterID)"))
    }

    /// Opens on Quit (owner) — safe, because Quit is never one press: a tap
    /// only nudges, and the hold (A, Return or a press) arrives as .quitChord.
    func testQuitNeedsAHold() throws {
        let app = try source("VibeLight/App/AppState.swift")
        XCTAssertTrue(app.contains("focus.focus(itemID: \"ended:quit\")\n        watchEndedGame(app)"))
        XCTAssertTrue(app.contains("case \"ended:quit\":\n                    // A tap."))
        XCTAssertTrue(app.contains("endedQuitNudges += 1"))
        let pads = try source("VibeLight/Input/ControllerManager.swift")
        XCTAssertTrue(pads.contains("kind: .quitGameButton, duration: Tuning.buttonHold, event: .quitChord"))
        XCTAssertTrue(pads.contains("self?.selectButtonChanged(pressed: pressed, source: .pad)"))
        // The button fills itself, so the ring stays away for that hold.
        let root = try source("VibeLight/UI/RootView.swift")
        XCTAssertTrue(root.contains("hold.kind != .quitGameButton"))
    }

    /// Owner: after the hold, the card fades out slowly instead of snapping
    /// away — it keeps its closing look (no snap back as the hold clears).
    func testQuitFadesTheCardOut() throws {
        let app = try source("VibeLight/App/AppState.swift")
        XCTAssertTrue(app.contains("if case .sessionEnded(let app) = overlay { fadeOutEndedCard(app) }"))
        XCTAssertTrue(app.contains("try? await Task.sleep(for: .seconds(Self.endedQuitFade))"))
        let overlays = try source("VibeLight/UI/OverlayViews.swift")
        XCTAssertTrue(overlays.contains(".opacity(quitting ? 0 : 1)"))
        XCTAssertTrue(overlays.contains("if quitting { return 1 }"))
    }

    /// Nothing on the card takes Select / Back until the curtain has lifted.
    func testInputWaitsForTheCurtain() throws {
        let app = try source("VibeLight/App/AppState.swift")
        XCTAssertTrue(app.contains("if event == .select || event == .back, !endedAcceptsInput { return }"))
        XCTAssertTrue(app.contains("if session.exitCurtain > 0 { return false }"))
    }

    /// A drop mid-stream lands here with the reason; a failed launch is
    /// still the error card.
    func testDropLandsOnTheCard() throws {
        let app = try source("VibeLight/App/AppState.swift")
        XCTAssertTrue(app.contains("if let live = liveStream {\n                    presentSessionEnded(live.app, dropReason: message)\n                } else {\n                    presentOverlay(.error(message))"))
        // A quit that fails is never mistaken for a drop.
        XCTAssertTrue(app.contains("// Not a drop: a quit that fails must surface as the error card.\n        liveStream = nil"))
    }

    /// If the PC closes the game while the card is up: Play Again, no Quit.
    func testClosedOnThePCDropsQuit() throws {
        let app = try source("VibeLight/App/AppState.swift")
        XCTAssertTrue(app.contains("? [\"ended:resume\", \"ended:home\"]"))
        XCTAssertTrue(app.contains("setEndedClosed(answer.info.runningAppID != app.id)"))
        let overlays = try source("VibeLight/UI/OverlayViews.swift")
        XCTAssertTrue(overlays.contains("title: closed ? \"Play Again\" : \"Resume Stream\""))
    }
}
