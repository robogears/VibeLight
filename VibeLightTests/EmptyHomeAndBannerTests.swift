import XCTest
@testable import VibeLight

/// Visual batch 3H. The header chip's banner stops cutting messages off and
/// keeps normal progress out of error orange (UX-host-banner-truncates); an
/// empty games shelf says why and offers the next step, and the hint bar never
/// offers "Play" with nothing to play (UX-empty-home-no-invitation).
final class EmptyHomeAndBannerTests: XCTestCase {

    // MARK: Banner copy and choice

    /// 420 pt at 13 pt medium fits ~65 characters a line; two lines ≈ 130.
    func testSavedComputersWarningsFitTwoLinesAndLeadWithWhatHappened() {
        let some = AppState.someSavedHostsUnreadableMessage
        let all = AppState.savedHostsUnreadableMessage
        XCTAssertLessThanOrEqual(some.count, 130, "must fit the chip's two lines without '…'")
        XCTAssertLessThanOrEqual(all.count, 130, "must fit the chip's two lines without '…'")
        XCTAssertTrue(some.hasPrefix("Some saved computers couldn't be read"))
        XCTAssertTrue(all.hasPrefix("Your saved computers couldn't be read"))
        XCTAssertTrue(some.contains("Nothing was deleted"), "the reassurance must survive the cut")
        XCTAssertTrue(all.contains("Nothing was deleted"), "the reassurance must survive the cut")
    }

    func testRestartingIsANoticeNotAnError() {
        XCTAssertEqual(AppState.hostBanner(error: nil, notice: "Restarting Gaming PC…",
                                           online: false, hasMAC: true),
                       .notice("Restarting Gaming PC…"),
                       "normal progress must not wear error orange, nor read as 'asleep'")
    }

    func testARealErrorIsNeverHiddenByANoticeOrAsleep() {
        XCTAssertEqual(AppState.hostBanner(error: "Pair it again.", notice: "Restarting Gaming PC…",
                                           online: false, hasMAC: true),
                       .error("Pair it again."))
    }

    func testPlainOfflineStatesAndOnline() {
        XCTAssertEqual(AppState.hostBanner(error: nil, notice: nil, online: false, hasMAC: true), .status("asleep"))
        XCTAssertEqual(AppState.hostBanner(error: nil, notice: nil, online: false, hasMAC: false), .status("offline"))
        XCTAssertNil(AppState.hostBanner(error: nil, notice: nil, online: true, hasMAC: true))
    }

    // MARK: Empty shelf

    private func shelf(hasHost: Bool = true, isPaired: Bool = true, online: Bool = false,
                       notResponding: Bool = false, hasError: Bool = false,
                       canWake: Bool = false, waking: Bool = false) -> AppState.EmptyShelf {
        AppState.emptyShelf(hasHost: hasHost, isPaired: isPaired, online: online,
                            notResponding: notResponding, hasError: hasError,
                            canWake: canWake, waking: waking)
    }

    func testNoComputerInvitesAddingOne() {
        XCTAssertEqual(shelf(hasHost: false), .noComputer)
        // Its button is the header's `header:addhost`, emitted in the header
        // section — the shelf section must not emit a second id for it.
        XCTAssertEqual(AppState.emptyShelfFocusIDs(.noComputer), [])
    }

    func testUnpairedComputerOffersPairing() {
        XCTAssertEqual(shelf(isPaired: false, online: true), .notPaired)
        XCTAssertEqual(AppState.emptyShelfFocusIDs(.notPaired), ["shelf:pair"])
    }

    func testAsleepOffersWakeAndWakingDropsTheButton() {
        XCTAssertEqual(shelf(canWake: true), .asleep)
        XCTAssertEqual(AppState.emptyShelfFocusIDs(.asleep), ["shelf:wake"])
        XCTAssertEqual(shelf(canWake: true, waking: true), .waking)
        XCTAssertEqual(AppState.emptyShelfFocusIDs(.waking), [],
                       "the panel draws a spinner while waking — no focusable id")
    }

    func testOfflineNotRespondingAndNoGamesOfferNoButton() {
        XCTAssertEqual(shelf(), .offline)
        XCTAssertEqual(shelf(notResponding: true), .notResponding)
        XCTAssertEqual(shelf(online: true), .noGames)
        for state in [AppState.EmptyShelf.offline, .notResponding, .noGames, .problem] {
            XCTAssertEqual(AppState.emptyShelfFocusIDs(state), [], "\(state)")
        }
    }

    func testAnErrorIsNeverShownAsAsleep() {
        XCTAssertEqual(shelf(hasError: true, canWake: true), .problem)
    }

    // MARK: Hint bar

    func testHomeSelectHintNamesTheButtonItPresses() {
        XCTAssertEqual(HintBarView.homeSelectLabel(focusedID: "header:addhost", hasApps: false), "Add Computer")
        XCTAssertEqual(HintBarView.homeSelectLabel(focusedID: "shelf:pair", hasApps: false), "Pair Computer")
        XCTAssertEqual(HintBarView.homeSelectLabel(focusedID: "shelf:wake", hasApps: false), "Wake Computer")
        XCTAssertEqual(HintBarView.homeSelectLabel(focusedID: "app:1", hasApps: true), "Play")
    }

    func testNoPlayHintWithNothingToPlay() {
        XCTAssertNil(HintBarView.homeSelectLabel(focusedID: "header:host", hasApps: false))
        XCTAssertNil(HintBarView.homeSelectLabel(focusedID: nil, hasApps: false))
    }

    // MARK: Wiring (checked by source only — the views can't run in a test)

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(of start: String, until end: String, in text: String) throws -> Substring {
        let s = try XCTUnwrap(text.range(of: start), "missing \(start)")
        let e = try XCTUnwrap(text.range(of: end, range: s.upperBound..<text.endIndex))
        return text[s.upperBound..<e.lowerBound]
    }

    /// One view per focus id: `header:addhost` is drawn only by the empty
    /// panel (the corner pill is gone), and the panel's other buttons come
    /// from the same rule rebuildFocus emits.
    func testEmptyPanelIsTheOnlyViewForItsIDs() throws {
        let home = try source("VibeLight/UI/HomeView.swift")
        XCTAssertEqual(home.components(separatedBy: "\"header:addhost\"").count - 1, 1,
                       "header:addhost must be drawn by exactly one view")
        XCTAssertFalse(home.contains("AddComputerButton()"), "the corner pill would be a second view")
        let panel = try body(of: "private struct EmptyShelfPanel: View {", until: "\n}\n", in: home)
        XCTAssertTrue(panel.contains("OverlayButton(id: \"header:addhost\""))
        XCTAssertTrue(panel.contains("ForEach(AppState.emptyShelfFocusIDs(shelf)"))
        let shelf = try body(of: "private struct AppShelf: View {", until: "private var shelf: some View {", in: home)
        XCTAssertTrue(shelf.contains("if let empty = state.emptyShelf {"))
    }

    func testRebuildFocusEmitsTheEmptyShelfIDs() throws {
        let app = try source("VibeLight/App/AppState.swift")
        let rebuild = try body(of: "private func rebuildFocus() {", until: "focus.setSections(sections)", in: app)
        XCTAssertTrue(rebuild.contains(
            "id: \"apps\", kind: .shelf,\n"
            + "                    itemIDs: emptyShelf.map(Self.emptyShelfFocusIDs)\n"
            + "                        ?? apps.map { \"app:\\(appKey($0))\" }"),
            "the apps section must emit the empty panel's ids while it is drawn")
    }

    /// Waking swaps the panel's Wake button for a spinner and back; focus must
    /// be rebuilt both times so the engine never holds an id nothing draws.
    func testWakeRebuildsFocusWhenWakingStartsAndLapses() throws {
        let app = try source("VibeLight/App/AppState.swift")
        let wake = try body(of: "func wakeSelectedHost() {", until: "\n    func wakeHost(", in: app)
        XCTAssertEqual(wake.components(separatedBy: "rebuildFocus()").count - 1, 2, String(wake))
    }

    func testChipBannerWrapsInsteadOfTruncating() throws {
        let home = try source("VibeLight/UI/HomeView.swift")
        let chip = try body(of: "private struct HostChip: View {", until: "\n}\n", in: home)
        XCTAssertTrue(chip.contains("switch state.hostBanner {"))
        XCTAssertTrue(chip.contains(".lineLimit(2)"))
        XCTAssertFalse(chip.contains(".lineLimit(1)"), "one line cut the reassurance off with '…'")
    }
}
