import XCTest
@testable import VibeLight

/// The dot beside a computer's name (owner: red when the PC isn't answering,
/// not orange), and the matching "is offline" wording.
final class HostDotTests: XCTestCase {
    private func dot(online: Bool = false, checked: Bool = true,
                     notResponding: Bool = false, hasError: Bool = false) -> AppState.HostDot {
        AppState.hostDot(online: online, checked: checked,
                         notResponding: notResponding, hasError: hasError)
    }

    func testOnlineIsGreen() {
        XCTAssertEqual(dot(online: true), .online)
    }

    /// A stuck service (it accepted the connection, never replied) and
    /// nothing-there (asleep / offline records no error) are both red.
    func testNotAnsweringIsRed() {
        XCTAssertEqual(dot(notResponding: true, hasError: true), .unreachable)
        XCTAssertEqual(dot(), .unreachable)
    }

    /// The PC answered, with a problem ("pair it again"): still orange.
    func testAnsweredWithAProblemStaysOrange() {
        XCTAssertEqual(dot(hasError: true), .attention)
    }

    /// Before the first check there's no answer yet to judge — never red.
    func testUncheckedIsNeverRed() {
        XCTAssertEqual(dot(checked: false), .attention)
        XCTAssertEqual(dot(checked: false, notResponding: true, hasError: true), .attention)
    }

    func testNotRespondingSaysOffline() {
        XCTAssertEqual(HostAPIError.notResponding("Gaming PC").localizedDescription, "Gaming PC is offline")
    }
}

/// The chip already shows the name, so its banner doesn't repeat it.
final class ChipBannerTextTests: XCTestCase {
    func testDropsTheLeadingHostName() {
        XCTAssertEqual(AppState.chipBannerText("UAE Server is offline", hostName: "UAE Server"), "is offline")
    }

    func testOtherMessagesAreUnchanged() {
        XCTAssertEqual(AppState.chipBannerText("Pair UAE Server again", hostName: "UAE Server"),
                       "Pair UAE Server again")
        XCTAssertEqual(AppState.chipBannerText("UAE Serverless is offline", hostName: "UAE Server"),
                       "UAE Serverless is offline")
        XCTAssertEqual(AppState.chipBannerText("is offline", hostName: ""), "is offline")
    }

    /// `.frame(maxWidth:)` stretched short text to the full cap.
    func testChipBannerHugsItsText() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let home = try String(contentsOf: root.appendingPathComponent("VibeLight/UI/HomeView.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains("WidthCap(max: 420) {"))
        XCTAssertFalse(home.contains(".frame(maxWidth: 420, alignment: .leading)"))
    }
}
