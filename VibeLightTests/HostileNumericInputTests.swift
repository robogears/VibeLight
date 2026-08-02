import XCTest
@testable import VibeLight

/// Swift's fixed-width conversions TRAP on overflow — they crash the process
/// rather than corrupt it. That is the right default, and it means every place
/// an outside number is narrowed is a remote kill switch until it's handled.
///
/// Two such places existed: the host's `ServerCodecModeSupport`, converted to
/// `Int32` on the way into moonlight-common-c, and the updater's byte cap,
/// computed from the size advertised in the release JSON — the very field the
/// cap exists to distrust.
final class HostileNumericInputTests: XCTestCase {

    // MARK: - /serverinfo

    private func serverInfo(_ body: String) -> ServerInfo {
        let xml = "<root status_code=\"200\">\(body)</root>"
        guard let info = HostAPIClient.parseServerInfo(fromXML: Data(xml.utf8)) else {
            preconditionFailure("fixture XML must parse")
        }
        return info
    }

    func testCodecModeSupportBeyondInt32IsRejectedNotTrapped() {
        // Int64-representable but far past Int32.max: the old code parsed this
        // as Int and trapped at the Int32() conversion in the iOS engine.
        for hostile in ["9999999999", "2147483648", "-2147483649", "99999999999999999999"] {
            let info = serverInfo("<ServerCodecModeSupport>\(hostile)</ServerCodecModeSupport>")
            XCTAssertEqual(info.serverCodecModeSupport, 0,
                           "\(hostile) is not a valid codec mask — expected the 'no modes' fallback")
        }
    }

    func testValidCodecModeSupportStillParses() {
        XCTAssertEqual(serverInfo("<ServerCodecModeSupport>259</ServerCodecModeSupport>")
                        .serverCodecModeSupport, 259)
        XCTAssertEqual(serverInfo("<ServerCodecModeSupport>2147483647</ServerCodecModeSupport>")
                        .serverCodecModeSupport, 2_147_483_647)
        XCTAssertEqual(serverInfo("<ServerCodecModeSupport>0</ServerCodecModeSupport>")
                        .serverCodecModeSupport, 0)
    }

    func testMissingOrGarbageCodecModeSupportFallsBackToZero() {
        XCTAssertEqual(serverInfo("").serverCodecModeSupport, 0)
        XCTAssertEqual(serverInfo("<ServerCodecModeSupport>nope</ServerCodecModeSupport>")
                        .serverCodecModeSupport, 0)
    }

    func testOutOfRangeHttpsPortFallsBackToTheWellKnownPort() {
        for hostile in ["0", "65536", "-1", "999999999999", "banana"] {
            XCTAssertEqual(serverInfo("<HttpsPort>\(hostile)</HttpsPort>").httpsPort, 47984,
                           "\(hostile) is not a port")
        }
        XCTAssertEqual(serverInfo("<HttpsPort>47990</HttpsPort>").httpsPort, 47990)
    }

    // MARK: - Updater byte cap

    func testByteCapSurvivesAHostileAdvertisedSize() {
        // Each of these used to reach `Int64(Double(x) * 1.1)`, which traps once
        // the product leaves Int64's range.
        for hostile: Int64 in [.max, .max / 2, 9_000_000_000_000_000_000] {
            let cap = UpdateService.byteCap(forAdvertisedSize: hostile)
            XCTAssertEqual(cap, 2_000_000_000, "a hostile size must land on the 2 GB ceiling")
        }
        // The negative direction used to trap at Int64(inflated) too; it must
        // land on the floor, not crash.
        for hostile: Int64 in [.min, .min + 1, .min / 2] {
            XCTAssertEqual(UpdateService.byteCap(forAdvertisedSize: hostile), 500_000_000,
                           "a hostile negative size must land on the 500 MB floor")
        }
    }

    func testByteCapKeepsItsFloorAndCeiling() {
        // Small/absent/negative sizes get the 500 MB floor…
        XCTAssertEqual(UpdateService.byteCap(forAdvertisedSize: 0), 500_000_000)
        XCTAssertEqual(UpdateService.byteCap(forAdvertisedSize: -1), 500_000_000)
        XCTAssertEqual(UpdateService.byteCap(forAdvertisedSize: 12_345), 500_000_000)
        // …a realistic build gets the floor too (it's well under 500 MB)…
        XCTAssertEqual(UpdateService.byteCap(forAdvertisedSize: 40_000_000), 500_000_000)
        // …and a large-but-sane one gets 10% headroom.
        XCTAssertEqual(UpdateService.byteCap(forAdvertisedSize: 1_000_000_000),
                       1_100_000_000)
    }
}
