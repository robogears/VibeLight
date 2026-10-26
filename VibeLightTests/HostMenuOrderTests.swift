import XCTest
@testable import VibeLight

/// The Computers menu lists the computer you're on first, then a divider, then
/// the rest (owner, 26 Oct 2026). `hostMenuOrder` is the single source of that
/// order: the card draws it and rebuildFocus emits it, so these pin the rule.
final class HostMenuOrderTests: XCTestCase {

    private func host(_ id: String) -> StreamHost {
        StreamHost(id: id, name: id,
                   localAddress: nil, localPort: 47989,
                   remoteAddress: nil, remotePort: 47989,
                   manualAddress: nil, manualPort: 47989,
                   macAddress: nil, serverCertPEM: nil, apps: [])
    }

    private let hosts = ["pc-a", "pc-b", "pc-c", "pc-d"]

    private func order(_ ids: [String], selected: String?) -> [String] {
        AppState.hostMenuOrder(hosts: ids.map(host), selectedID: selected).map(\.id)
    }

    func testSelectedComputerMovesToTheTop() {
        XCTAssertEqual(order(hosts, selected: "pc-c"), ["pc-c", "pc-a", "pc-b", "pc-d"],
                       "the computer you're on must be listed first")
    }

    func testTheOthersKeepTheirOrder() {
        XCTAssertEqual(order(hosts, selected: "pc-d"), ["pc-d", "pc-a", "pc-b", "pc-c"],
                       "lifting the selected computer must not reshuffle the rest")
    }

    func testAlreadyFirstIsUnchanged() {
        XCTAssertEqual(order(hosts, selected: "pc-a"), hosts)
    }

    func testNoOrUnknownSelectionLeavesTheListAlone() {
        XCTAssertEqual(order(hosts, selected: nil), hosts)
        XCTAssertEqual(order(hosts, selected: "gone"), hosts)
    }

    func testSingleComputerIsUnchanged() {
        XCTAssertEqual(order(["pc-a"], selected: "pc-a"), ["pc-a"])
    }

    func testDividerOnlyWhenTheSelectedComputerHasOthersBelowIt() {
        let many = hosts.map(host)
        XCTAssertTrue(AppState.hostMenuHasDivider(hosts: many, selectedID: "pc-b"))
        XCTAssertFalse(AppState.hostMenuHasDivider(hosts: many, selectedID: nil),
                       "no selection: nothing was lifted, so nothing to separate")
        XCTAssertFalse(AppState.hostMenuHasDivider(hosts: many, selectedID: "gone"))
        XCTAssertFalse(AppState.hostMenuHasDivider(hosts: [host("pc-a")], selectedID: "pc-a"),
                       "one computer: a divider would separate it from nothing")
        XCTAssertFalse(AppState.hostMenuHasDivider(hosts: [], selectedID: nil))
    }
}
