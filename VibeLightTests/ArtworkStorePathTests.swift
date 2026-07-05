import XCTest
@testable import VibeLight

/// The box-art cache builds filesystem paths from host-supplied identifiers
/// (host.id, app.uuid from the /applist XML). A hostile value must never escape
/// the cache directory (SEV-01). These lock in `ArtworkStore.safeComponent`.
final class ArtworkStorePathTests: XCTestCase {

    // MARK: - Safe tokens pass through verbatim (stable cache keys)

    func testValidIdentifiersUnchanged() {
        // Real GameStream UUIDs and CRC32-derived integer IDs.
        for token in ["A1B2C3D4-5E6F-7890-ABCD-EF0123456789",
                      "steam", "desktop", "1234567890", "app_01", "a.b-c_d"] {
            XCTAssertEqual(ArtworkStore.safeComponent(token), token,
                           "\(token) is a safe token and should be used verbatim")
        }
    }

    // MARK: - Hostile values are hashed away (no traversal possible)

    func testTraversalInputsAreNeutralized() {
        let hostile = [
            "../../../../tmp/evil",
            "../../Library/LaunchAgents/x",
            "/etc/passwd",
            "a/b",
            "..",
            ".",
            "",                              // empty
            String(repeating: "z", count: 200),   // over-long
            "emoji😀",                       // non-ASCII
            "back\\slash",
            "nul\0byte",
        ]
        for value in hostile {
            let out = ArtworkStore.safeComponent(value)
            // Hashed values are 64 lowercase hex chars.
            XCTAssertEqual(out.count, 64, "\(value.debugDescription) should hash to 64 chars")
            XCTAssertTrue(out.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) },
                          "\(value.debugDescription) should hash to lowercase hex")
        }
    }

    // MARK: - The invariant: output is ALWAYS a single, separator-free component

    func testOutputNeverContainsPathSeparatorsOrDotDot() {
        let inputs = ["ok", "../x", "/y", "a/b/c", "..", ".", "", "白", "a\\b",
                      "..%2f", "....//....//"]
        for value in inputs {
            let out = ArtworkStore.safeComponent(value)
            XCTAssertFalse(out.contains("/"), "\(value.debugDescription) -> must not contain '/'")
            XCTAssertFalse(out.contains("\\"), "\(value.debugDescription) -> must not contain '\\'")
            XCTAssertNotEqual(out, "..", "\(value.debugDescription) -> must not be '..'")
            XCTAssertNotEqual(out, ".", "\(value.debugDescription) -> must not be '.'")
            XCTAssertFalse(out.isEmpty, "\(value.debugDescription) -> must not be empty")
        }
    }

    // MARK: - Determinism (cache stability)

    func testHashingIsDeterministic() {
        XCTAssertEqual(ArtworkStore.safeComponent("../evil"),
                       ArtworkStore.safeComponent("../evil"))
        XCTAssertNotEqual(ArtworkStore.safeComponent("../evil"),
                          ArtworkStore.safeComponent("../evil2"))
    }
}
