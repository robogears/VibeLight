import XCTest
@testable import VibeLight

/// Locks in the SEV-02 argument-injection guard: the host-controlled operands
/// (address + raw app name, both parsed verbatim from the host's XML) must
/// always follow a `--` end-of-options separator so a value beginning with `-`
/// can never be parsed as a Moonlight CLI flag.
final class StreamArgumentsTests: XCTestCase {

    func testHostControlledOperandsComeAfterDoubleDash() {
        let args = StreamSessionManager.streamArguments(
            address: "--evil-address",
            rawAppName: "--exec=/bin/sh",
            settings: .fallback
        )
        guard let dashIdx = args.firstIndex(of: "--") else {
            return XCTFail("args must contain a -- end-of-options separator")
        }
        // The action stays first; the two operands are the FINAL two elements.
        XCTAssertEqual(args.first, "stream")
        XCTAssertEqual(Array(args.suffix(2)), ["--evil-address", "--exec=/bin/sh"])
        // Nothing before "--" is a host operand (so neither can be read as a flag).
        let beforeDash = args[..<dashIdx]
        XCTAssertFalse(beforeDash.contains("--evil-address"))
        XCTAssertFalse(beforeDash.contains("--exec=/bin/sh"))
        XCTAssertLessThan(dashIdx, args.count - 2, "-- must precede the operands")
    }

    func testSettingsFlagsPrecedeTheSeparator() {
        var s = StreamSettings.fallback
        s.width = 2560; s.height = 1440; s.fps = 120
        let args = StreamSessionManager.streamArguments(
            address: "1.2.3.4", rawAppName: "Desktop", settings: s)
        let dashIdx = args.firstIndex(of: "--")!
        let flags = args[..<dashIdx]
        XCTAssertTrue(flags.contains("2560x1440"), "resolution flag must precede --")
        XCTAssertTrue(flags.contains("120"), "fps flag must precede --")
        XCTAssertEqual(Array(args.suffix(2)), ["1.2.3.4", "Desktop"])
    }
}
