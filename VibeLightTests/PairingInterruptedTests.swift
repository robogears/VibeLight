import XCTest
@testable import VibeLight

/// iPad pairing: phase 1 waits for the PIN, and typing it in Safari on the
/// same iPad backgrounds VibeLight — iOS then suspends it and kills the
/// pending request. These pin the copy that steers people away from that and
/// the error that names it, instead of "Couldn't reach the computer".
final class PairingInterruptedTests: XCTestCase {

    func testUnreachableAfterLeavingTheAppSaysWhy() {
        XCTAssertEqual(AppState.unreachablePairingStatus(leftAppWhileWaiting: true),
                       .failed(AppState.pairingInterruptedMessage))
    }

    func testUnreachableWithoutLeavingStaysUnreachable() {
        XCTAssertEqual(AppState.unreachablePairingStatus(leftAppWhileWaiting: false), .unreachable)
    }

    func testIPadInstructionsPointAwayFromThisDevice() {
        let text = AppState.pairingInstructions(webUIURL: "https://10.0.0.2:47990", on: .iOS)
        XCTAssertTrue(text.contains("https://10.0.0.2:47990"))
        XCTAssertTrue(text.contains("not this one"))
        XCTAssertTrue(text.contains("Keep VibeLight open"))
    }

    func testMacInstructionsUnchanged() {
        XCTAssertEqual(AppState.pairingInstructions(webUIURL: "https://10.0.0.2:47990", on: .macOS),
                       "Open your host's web UI at https://10.0.0.2:47990 and type the PIN.")
    }

    // MARK: - Source pins (iOS-only code the macOS runner can't execute)

    /// The background hook runs BEFORE the streaming-only guard, or an idle
    /// launcher (the only state pairing happens in) would never reach it.
    func testBackgroundHookHoldsPairingBeforeTheStreamGuard() throws {
        let text = try appStateSource()
        let start = try XCTUnwrap(text.range(of: "func handleAppDidEnterBackground() {"))
        let body = text[start.upperBound...]
        let hold = try XCTUnwrap(body.range(of: "holdPairingInBackground()"))
        let guardLive = try XCTUnwrap(body.range(of: "guard let app = leftApp else { return }"))
        XCTAssertLessThan(hold.lowerBound, guardLive.lowerBound)
    }

    /// Every pairing exit goes through setPairingKeepAwake(false), so that is
    /// where the background assertion must end — never left to expire.
    func testEndingPairingEndsTheBackgroundAssertion() throws {
        let text = try appStateSource()
        let start = try XCTUnwrap(text.range(of: "private func setPairingKeepAwake(_ on: Bool) {"))
        let end = try XCTUnwrap(text.range(of: "\n    }\n", range: start.upperBound..<text.endIndex))
        XCTAssertTrue(text[start.upperBound..<end.lowerBound].contains("if !on { endBGPairTask() }"))
    }

    // MARK: - Pre-pairing reachability check

    /// The failure names the address, the port and the system's reason.
    func testPortUnreachableMessageSaysWhereAndWhy() {
        let msg = HostPairing.portUnreachableMessage(address: "100.64.1.2", error: URLError(.timedOut))
        XCTAssertTrue(msg.contains("100.64.1.2"))
        XCTAssertTrue(msg.contains("47989"))
        XCTAssertTrue(msg.contains(URLError(.timedOut).localizedDescription))
    }

    /// The check runs before the ten-minute phase-1 request is ever sent, or a
    /// dead port still looks like "Waiting for pairing…".
    func testReachabilityCheckRunsBeforeGetServerCert() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("VibeLight/Core/HostPairing.swift"),
                              encoding: .utf8)
        let check = try XCTUnwrap(text.range(of: "path: \"/serverinfo\", query: \"\", timeout: 5)"))
        let phase1 = try XCTUnwrap(text.range(of: "phrase=getservercert"))
        XCTAssertLessThan(check.lowerBound, phase1.lowerBound)
        XCTAssertTrue(text.contains("return .failed(Self.portUnreachableMessage(address: address, error: error))"))
    }

    /// An unpaired computer's plain-HTTP name is display-only: never its uuid.
    func testUnpairedNameLookupNeverAdoptsIdentity() throws {
        let text = try appStateSource()
        let start = try XCTUnwrap(text.range(of: "private func learnUnpairedHostName(_ host: StreamHost) {"))
        let end = try XCTUnwrap(text.range(of: "\n    }\n", range: start.upperBound..<text.endIndex))
        let body = text[start.upperBound..<end.lowerBound]
        XCTAssertTrue(body.contains("upgradeAddedHost(ip: ip, uuid: nil, name: name)"))
        XCTAssertFalse(body.contains("mac:"))
    }

    private func appStateSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("VibeLight/App/AppState.swift"),
                          encoding: .utf8)
    }
}
