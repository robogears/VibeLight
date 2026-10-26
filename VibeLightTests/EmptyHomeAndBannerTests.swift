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

    /// With no readable computer left the "some" wording's "your other
    /// computers still work" is false — and the no-computer panel shows it.
    func testUnreadableWarningNeverMentionsOtherComputersWhenNoneAreLeft() {
        XCTAssertEqual(AppState.savedHostsWarning(blobUnreadable: false, unreadableCount: 1, readableCount: 0),
                       AppState.savedHostsUnreadableMessage)
        XCTAssertEqual(AppState.savedHostsWarning(blobUnreadable: false, unreadableCount: 1, readableCount: 2),
                       AppState.someSavedHostsUnreadableMessage)
        XCTAssertEqual(AppState.savedHostsWarning(blobUnreadable: true, unreadableCount: 0, readableCount: 0),
                       AppState.savedHostsUnreadableMessage)
        XCTAssertNil(AppState.savedHostsWarning(blobUnreadable: false, unreadableCount: 0, readableCount: 0))
        XCTAssertNil(AppState.savedHostsWarning(blobUnreadable: false, unreadableCount: 0, readableCount: 3))
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

    private func shelf(hasHost: Bool = true, isPaired: Bool = true, checked: Bool = true,
                       online: Bool = false,
                       notResponding: Bool = false, hasError: Bool = false,
                       canWake: Bool = false, waking: Bool = false) -> AppState.EmptyShelf {
        AppState.emptyShelf(hasHost: hasHost, isPaired: isPaired, checked: checked, online: online,
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

    /// Before the selected computer first answers, the shelf is empty only
    /// because nothing has loaded: an awake PC must not read "asleep" with a
    /// Wake button (a stray A would send a magic packet), nor "No games".
    func testNothingIsClaimedBeforeTheComputerFirstAnswers() {
        XCTAssertEqual(shelf(checked: false, canWake: true), .checking)
        XCTAssertEqual(shelf(checked: false, online: true), .checking)
        XCTAssertEqual(AppState.emptyShelfFocusIDs(.checking), [])
        // Pairing is known locally, so it needn't wait for an answer.
        XCTAssertEqual(shelf(isPaired: false, checked: false), .notPaired)
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

    /// Starting the wake from the shelf's button removes that button; focus
    /// must land on the header's Wake button (still drawn while waking), not
    /// fall down to a preset slot where a second A replaces the settings.
    func testWakingFromTheShelfMovesFocusToTheHeaderWakeButton() throws {
        let app = try source("VibeLight/App/AppState.swift")
        let wake = try body(of: "func wakeSelectedHost() {", until: "\n    func wakeHost(", in: app)
        let first = try XCTUnwrap(wake.range(of: "rebuildFocus()"))
        let tail = wake[first.upperBound...]
        let move = try XCTUnwrap(tail.range(of: "if wasOnShelfWake { focus.focus(itemID: \"header:power\") }"),
                                 String(wake))
        XCTAssertNil(tail[..<move.lowerBound].range(of: "rebuildFocus()"),
                     "focus must move right after the rebuild that drops shelf:wake")
        XCTAssertTrue(wake.contains("let wasOnShelfWake = focus.focusedItemID == \"shelf:wake\""))
        // header:power is still emitted while waking only because its gate
        // ignores the waking state.
        let gate = try body(of: "var canWakeSelectedHost: Bool {", until: "}", in: app)
        XCTAssertFalse(gate.contains("wakingHostID"), String(gate))
    }

    /// "Pair Computer" must start pairing, not just open the Computers menu.
    func testPairComputerStartsPairing() throws {
        let app = try source("VibeLight/App/AppState.swift")
        let branch = try body(of: "} else if focus.focusedItemID == \"shelf:pair\" {",
                              until: "} else if focus.focusedItemID == \"header:restart\" {", in: app)
        XCTAssertTrue(branch.contains("openHostMenu()\n"
                                      + "                if let host = selectedHost, needsPairing(host) { beginPairing(host) }"),
                      String(branch))
    }

    /// A computer whose certificate changed (or that now refuses us) needs
    /// pairing again: the empty shelf must offer Pair Computer, so it is
    /// judged by needsPairing, not by whether a certificate is stored.
    func testEmptyShelfOffersPairingWhenPairingBroke() throws {
        let app = try source("VibeLight/App/AppState.swift")
        let shelfVar = try body(of: "var emptyShelf: EmptyShelf? {", until: "\n    }\n", in: app)
        XCTAssertTrue(shelfVar.contains("isPaired: host.map { !needsPairing($0) } ?? false"), String(shelfVar))
        XCTAssertFalse(shelfVar.contains("host?.isPaired"), String(shelfVar))
        let home = try source("VibeLight/UI/HomeView.swift")
        let panel = try body(of: "private struct EmptyShelfPanel: View {", until: "\n}\n", in: home)
        XCTAssertTrue(panel.contains("case .notPaired: state.selectedHost?.isPaired == true ? \"Pair \\(name) again\""),
                      "a computer that was paired needs pairing AGAIN, not 'yet'")
    }

    /// The saved-computers warning on the no-computer panel is chosen by
    /// savedHostsWarning and drawn in warning orange.
    func testLaunchWarningUsesTheRuleAndPanelDrawsItOrange() throws {
        let app = try source("VibeLight/App/AppState.swift")
        let load = try body(of: "let savedHosts = Self.loadAddedHosts()", until: "let savedPresets = Self.loadPresets()", in: app)
        XCTAssertTrue(load.contains("Self.savedHostsWarning(blobUnreadable: savedHosts.blobUnreadable,"), String(load))
        XCTAssertTrue(load.contains("readableCount: hosts.count)"), String(load))
        XCTAssertFalse(load.contains("hostError = Self.someSavedHostsUnreadableMessage"), String(load))
        let home = try source("VibeLight/UI/HomeView.swift")
        let panel = try body(of: "private struct EmptyShelfPanel: View {", until: "\n}\n", in: home)
        XCTAssertTrue(panel.contains("private var isWarning: Bool { shelf == .noComputer && state.hostError != nil }"))
        XCTAssertTrue(panel.contains(".foregroundStyle(isWarning ? Color.orange"), String(panel))
    }

    /// The "answered yet" flag belongs to one computer: switching or removing
    /// the selected one must reset it, or the next one is judged on the last
    /// one's answer.
    func testSelectionChangesResetTheAnsweredFlag() throws {
        let app = try source("VibeLight/App/AppState.swift")
        let select = try body(of: "func selectHost(_ id: String) {", until: "\n    }\n", in: app)
        XCTAssertTrue(select.contains("selectedHostChecked = false"), String(select))
        let remove = try body(of: "let wasSelected = selectedHostID == host.id", until: "rebuildFocus()", in: app)
        XCTAssertTrue(remove.contains("selectedHostChecked = false"), String(remove))
    }

    func testChipBannerWrapsInsteadOfTruncating() throws {
        let home = try source("VibeLight/UI/HomeView.swift")
        let chip = try body(of: "private struct HostChip: View {", until: "\n}\n", in: home)
        XCTAssertTrue(chip.contains("switch state.hostBanner {"))
        XCTAssertTrue(chip.contains(".lineLimit(2)"))
        XCTAssertFalse(chip.contains(".lineLimit(1)"), "one line cut the reassurance off with '…'")
    }

    /// Removing your only computer must not leave its error on the empty
    /// panel ("fix the computer you just removed"); a warning about the
    /// saved list itself stays (3H last review).
    func testRemovingTheSelectedComputerDropsItsErrorButKeepsTheListWarning() throws {
        XCTAssertNil(AppState.hostErrorAfterRemovingSelected("Gaming PC refused the connection."))
        XCTAssertNil(AppState.hostErrorAfterRemovingSelected(nil))
        XCTAssertEqual(AppState.hostErrorAfterRemovingSelected(AppState.savedHostsUnreadableMessage),
                       AppState.savedHostsUnreadableMessage)
        XCTAssertEqual(AppState.hostErrorAfterRemovingSelected(AppState.someSavedHostsUnreadableMessage),
                       AppState.someSavedHostsUnreadableMessage)
        let app = try source("VibeLight/App/AppState.swift")
        let remove = try body(of: "let wasSelected = selectedHostID == host.id", until: "rebuildFocus()", in: app)
        XCTAssertTrue(remove.contains("hostError = Self.hostErrorAfterRemovingSelected(hostError)"), String(remove))
    }

    /// A refresh that fails after the person switched computers (or removed
    /// the one being checked) must write nothing onto the new selection — the
    /// removed computer's games used to stay on the shelf with no computer
    /// selected (3H last review). Checked by source only.
    func testAFailedRefreshForAComputerNoLongerSelectedChangesNothing() throws {
        let app = try source("VibeLight/App/AppState.swift")
        let typed = try body(of: "} catch let error as HostAPIError {", until: "serverInfo = nil", in: app)
        XCTAssertTrue(typed.contains("guard selectionStillThisHost() else { return }"), String(typed))
        let other = try body(of: "apps = displayApps(from: rememberedApps(for: host))\n            selectedHostChecked = true\n        } catch {",
                             until: "serverInfo = nil", in: app)
        XCTAssertTrue(other.contains("guard selectionStillThisHost() else { return }"), String(other))
    }
}
