import XCTest
@testable import VibeLight

/// "Remember my last PC" persists the selection and restores it on launch. The
/// fragile part is RESTORE: a host's `id` changes representation between
/// launches (added:<ip> ↔ real uuid, Moonlight import present vs absent), so an
/// exact-id match alone silently loses the selection and falls back to the first
/// host — the bug the user hit ("it keeps defaulting back to the second PC").
/// `resolveSelectedHostID` recovers by stable address. These lock that in.
final class HostSelectionPersistenceTests: XCTestCase {

    private func host(id: String, name: String = "PC",
                      local: String? = nil, remote: String? = nil,
                      manual: String? = nil) -> StreamHost {
        StreamHost(id: id, name: name,
                   localAddress: local, localPort: 47989,
                   remoteAddress: remote, remotePort: 47989,
                   manualAddress: manual, manualPort: 47989,
                   macAddress: nil, serverCertPEM: nil, apps: [])
    }

    // Two hosts (fake/documentation values only). The order that bites: the PC
    // the user does NOT want first, the one they actually use second — so any
    // failed restore lands on the wrong one. (RFC 5737 + Tailscale CGNAT ranges.)
    private var hosts: [StreamHost] {
        [host(id: "uuid-pc-a", name: "First PC", local: "192.0.2.50", remote: "203.0.113.9"),
         host(id: "uuid-pc-b", name: "Second PC", local: "100.64.0.2", manual: "100.64.0.2")]
    }

    // MARK: - Exact id still wins (the happy path is unchanged)

    func testExactIDMatchRestoresThatHost() {
        let picked = AppState.resolveSelectedHostID(in: hosts, savedID: "uuid-pc-b", savedAddr: nil)
        XCTAssertEqual(picked, "uuid-pc-b", "a still-present id must restore verbatim")
    }

    // MARK: - The actual bug: id changed representation, address saves us

    func testAddressFallbackWhenIDNoLongerMatches() {
        // Saved id was the uuid; this launch represents the same PC as added:<ip>.
        let addedRepresentation = [
            host(id: "uuid-pc-a", name: "First PC", local: "192.0.2.50", remote: "203.0.113.9"),
            host(id: "added:100.64.0.2", name: "Second PC", manual: "100.64.0.2"),
        ]
        let picked = AppState.resolveSelectedHostID(
            in: addedRepresentation, savedID: "uuid-pc-b", savedAddr: "100.64.0.2")
        XCTAssertEqual(picked, "added:100.64.0.2",
                       "id no longer matches, but the saved address must recover the second PC — NOT fall to the first")
    }

    func testAddressFallbackMatchesAnyCandidateAddress() {
        // Saved the remote address; host now known by its local address.
        let picked = AppState.resolveSelectedHostID(
            in: hosts, savedID: "stale-id", savedAddr: "203.0.113.9")
        XCTAssertEqual(picked, "uuid-pc-a",
                       "a saved address matching ANY of the host's candidate addresses must restore it")
    }

    // MARK: - Fallbacks

    func testFallsBackToFirstWhenNothingMatches() {
        let picked = AppState.resolveSelectedHostID(
            in: hosts, savedID: "gone", savedAddr: "198.51.100.99")
        XCTAssertEqual(picked, "uuid-pc-a", "no match → first host, never nil-selection")
    }

    func testNilSavedStateFallsBackToFirst() {
        XCTAssertEqual(AppState.resolveSelectedHostID(in: hosts, savedID: nil, savedAddr: nil),
                       "uuid-pc-a")
    }

    func testEmptyHostsYieldsNil() {
        XCTAssertNil(AppState.resolveSelectedHostID(in: [], savedID: "x", savedAddr: "192.0.2.1"))
    }

    func testIDMatchPreferredOverAddressMatch() {
        // If both a saved id AND a saved address are present, the exact id wins.
        let picked = AppState.resolveSelectedHostID(
            in: hosts, savedID: "uuid-pc-b", savedAddr: "192.0.2.50")
        XCTAssertEqual(picked, "uuid-pc-b", "exact id takes precedence over the address fallback")
    }
}
