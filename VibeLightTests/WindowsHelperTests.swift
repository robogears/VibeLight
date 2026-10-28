import XCTest
@testable import VibeLight

/// Settings ▸ Windows Helper: VibeLight Helper on the PC (WindowsHelper/),
/// Match TV's sizes, and the greyed-out rule (owner: "blank out all of the
/// features that the helper will control if the user doesn't have the app
/// installed").
@MainActor
final class WindowsHelperTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "WindowsHelperTests-\(UUID().uuidString)"
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

    // MARK: - Match TV sizes

    /// The owner's numbers: Half is 4K → 1440p, Quarter (the default) is
    /// 4K → 1080p, Full is the TV's own.
    func testScalesOnA4KTV() {
        let tv = (width: 3840, height: 2160)
        XCTAssertEqual(TVMatchScale.streamSize(tv: tv, scale: .quarter)?.width, 1920)
        XCTAssertEqual(TVMatchScale.streamSize(tv: tv, scale: .quarter)?.height, 1080)
        XCTAssertEqual(TVMatchScale.streamSize(tv: tv, scale: .half)?.width, 2560)
        XCTAssertEqual(TVMatchScale.streamSize(tv: tv, scale: .half)?.height, 1440)
        XCTAssertEqual(TVMatchScale.streamSize(tv: tv, scale: .full)?.width, 3840)
        XCTAssertEqual(TVMatchScale.streamSize(tv: tv, scale: .full)?.height, 2160)
    }

    /// Never below 720p, never above the TV, always even, the TV's shape.
    func testSmallAndOddTVs() {
        let hd = (width: 1920, height: 1080)
        XCTAssertEqual(TVMatchScale.streamSize(tv: hd, scale: .quarter)?.width, 1280)
        XCTAssertEqual(TVMatchScale.streamSize(tv: hd, scale: .quarter)?.height, 720)
        XCTAssertEqual(TVMatchScale.streamSize(tv: hd, scale: .half)?.height, 720)
        let small = TVMatchScale.streamSize(tv: (width: 1280, height: 600), scale: .quarter)
        XCTAssertEqual(small?.height, 600)   // a TV smaller than 720p: its own size
        let ultrawide = TVMatchScale.streamSize(tv: (width: 3440, height: 1440), scale: .quarter)
        XCTAssertEqual(ultrawide?.width, 1720)
        XCTAssertEqual(ultrawide?.height, 720)
        let odd = TVMatchScale.streamSize(tv: (width: 2561, height: 1441), scale: .full)
        XCTAssertEqual(odd?.width, 2560)
        XCTAssertEqual(odd?.height, 1440)
        XCTAssertNil(TVMatchScale.streamSize(tv: (width: 0, height: 0), scale: .full))
    }

    func testRowLabelsSayWhatTheStreamBecomes() {
        XCTAssertEqual(TVMatchScale.quarter.label(tv: (width: 3840, height: 2160)), "Quarter · 1920×1080")
        XCTAssertEqual(TVMatchScale.half.label(tv: nil), "Half · 4K → 1440p")
        XCTAssertEqual(TVMatchScale.allCases, [.quarter, .half, .full])   // right = bigger
    }

    // MARK: - Settings

    func testDefaultsAreMatchTVOnAtQuarter() {
        XCTAssertTrue(AppState.storedMatchTV(in: defaults))
        XCTAssertEqual(AppState.storedTVMatchScale(in: defaults), .quarter)
        defaults.set("enormous", forKey: AppState.tvMatchScaleKey)
        XCTAssertEqual(AppState.storedTVMatchScale(in: defaults), .quarter)
        defaults.set(false, forKey: AppState.matchTVKey)
        defaults.set("half", forKey: AppState.tvMatchScaleKey)
        XCTAssertFalse(AppState.storedMatchTV(in: defaults))
        XCTAssertEqual(AppState.storedTVMatchScale(in: defaults), .half)
    }

    /// Its own tab, emitted by no other; the status row acts on select. The
    /// Mac gets the status (for Quit Stream and Game); Match TV is the iPad's.
    func testTheWindowsHelperTab() {
        XCTAssertEqual(AppState.SettingsTab.windowsHelper.title, "Windows Helper")
        XCTAssertEqual(AppState.SettingsTab.windowsHelper.rows, [.helperStatus])
        let tabsWithStatus = AppState.SettingsTab.allCases.filter { $0.rows.contains(.helperStatus) }
        XCTAssertEqual(tabsWithStatus, [.windowsHelper])
        XCTAssertTrue(AppState.SettingsRow.helperStatus.isAction)
        XCTAssertFalse(AppState.SettingsRow.matchTV.isAction)
        XCTAssertEqual(AppState.SettingsRow.helperStatus.focusID, "setting:helperStatus")
    }

    func testIPadRowsAndTheGreyedRule() throws {
        let state = try source("VibeLight/App/AppState.swift")
        XCTAssertTrue(state.contains("[.helperStatus, .matchTV, .tvResolution]"))
        XCTAssertTrue(state.contains("case .matchTV: !windowsHelperReady"))
        XCTAssertTrue(state.contains("case .tvResolution: !windowsHelperReady || !matchTV"))
        XCTAssertTrue(state.contains("if isUnavailable(row) { return }   // greyed: needs VibeLight Helper"))
        let view = try source("VibeLight/UI/SettingsView.swift")
        XCTAssertTrue(view.contains(".opacity(unavailable ? 0.4 : 1)"))
    }

    // MARK: - Match TV wiring (iPad)

    /// Only Match TV — on, with the helper, with a TV — changes the stream's
    /// size, and only the size: the frame rate and bitrate stay the preset's.
    func testOnlyMatchTVSizesTheStream() throws {
        let state = try source("VibeLight/App/AppState.swift")
        XCTAssertTrue(state.contains("guard matchTV, windowsHelperReady, let tv = attachedTVSize else { return nil }"))
        XCTAssertTrue(state.contains("            launch.width = size.width\n            launch.height = size.height\n        }"))
        XCTAssertFalse(state.contains("launch.fps ="))
        XCTAssertTrue(state.contains("let streamSettings = launchSettings   // Match TV: the TV's size"))
        // Plugged in / pulled out mid-stream: a restart, then the PC follows.
        XCTAssertTrue(state.contains("session.onResized = { [weak self] in self?.syncPCToStream() }"))
        XCTAssertTrue(state.contains("restorePC()   // Match TV: the PC goes back to normal"))
        let app = try source("VibeLight/App/iOS/VibeLightApp.swift")
        XCTAssertTrue(app.contains("ExternalDisplay.shared.onConnectionChange = { state.tvConnectionChanged() }"))
        let engine = try source("VibeLight/App/iOS/InProcessStreamEngine.swift")
        XCTAssertTrue(engine.contains("rejoin = Rejoin(app: app, attempt: 1, droppedAt: Date(), resize: resize)"))
    }

    // MARK: - Quit Stream and Game

    /// Beside Quit Stream Completely, held the same way, greyed and out of
    /// focus without the helper.
    func testQuitStreamAndGameOnTheCard() throws {
        let overlays = try source("VibeLight/UI/OverlayViews.swift")
        XCTAssertTrue(overlays.contains("OverlayButton(id: AppState.quitGameButtonID, title: \"Quit Stream and Game\""))
        XCTAssertTrue(overlays.contains("disabled: !state.windowsHelperReady)"))
        let state = try source("VibeLight/App/AppState.swift")
        XCTAssertTrue(state.contains("? [\"ended:resume\", \"ended:quit\", Self.quitGameButtonID, \"ended:home\"]"))
        XCTAssertTrue(state.contains("if case .sessionEnded = overlay, focus.focusedItemID == Self.quitGameButtonID {\n                quitStreamAndGame()"))
        XCTAssertEqual(AppState.quitGameGrace, 5)
    }

    // MARK: - Wire contract (WindowsHelper/VibeLightHelper.Core/Protocol.cs)

    func testRepliesDecode() throws {
        let match = try JSONDecoder().decode(WindowsHelperClient.MatchResult.self, from: Data("""
        {"ok":true,"display":{"device":"DISPLAY1","width":1920,"height":1080,"refreshHz":120},
         "game":{"title":"Elden Ring","process":"eldenring","exclusiveFullscreen":false},
         "gameFitted":true,"message":"Elden Ring now fills 1920×1080."}
        """.utf8))
        XCTAssertEqual(match.display?.refreshHz, 120)
        XCTAssertEqual(match.game?.title, "Elden Ring")
        XCTAssertTrue(match.gameFitted)
        // The helper leaves nulls out.
        let restore = try JSONDecoder().decode(WindowsHelperClient.MatchResult.self,
                                               from: Data(#"{"ok":true,"gameFitted":false,"message":"Nothing to put back."}"#.utf8))
        XCTAssertNil(restore.display)
        let quit = try JSONDecoder().decode(WindowsHelperClient.QuitResult.self,
                                            from: Data(#"{"ok":false,"forced":false,"message":"No game is running."}"#.utf8))
        XCTAssertNil(quit.title)
        let info = try JSONDecoder().decode(WindowsHelperClient.Info.self,
                                            from: Data(#"{"name":"VibeLight Helper","version":"1.0","hostName":"GAMING-PC"}"#.utf8))
        XCTAssertEqual(info.hostName, "GAMING-PC")
    }

    func testRequestsGoToThePCOnTheHelpersPort() {
        XCTAssertEqual(WindowsHelperClient.port, 47333)
        XCTAssertEqual(WindowsHelperClient.requestURL(address: "192.0.2.10", path: "/info")?.absoluteString,
                       "https://192.0.2.10:47333/info")
    }
}
