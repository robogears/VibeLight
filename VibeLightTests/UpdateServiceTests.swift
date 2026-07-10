import XCTest
import CryptoKit
@testable import VibeLight

/// The version-compare and release-parsing logic gate whether we download and
/// execute a new build — so they get real coverage, including the host pin.
final class UpdateServiceTests: XCTestCase {

    // MARK: Version comparison

    func testNewerPatchMinorMajor() {
        XCTAssertTrue(UpdateService.isNewer("0.1.2", than: "0.1.1"))
        XCTAssertTrue(UpdateService.isNewer("0.2.0", than: "0.1.9"))
        XCTAssertTrue(UpdateService.isNewer("1.0.0", than: "0.9.9"))
    }

    func testNotNewerWhenEqualOrOlder() {
        XCTAssertFalse(UpdateService.isNewer("0.1.1", than: "0.1.1"))
        XCTAssertFalse(UpdateService.isNewer("0.1.0", than: "0.1.1"))
        XCTAssertFalse(UpdateService.isNewer("0.9.9", than: "1.0.0"))
    }

    func testNumericNotStringComparison() {
        // "10" must beat "9" — the classic string-compare bug.
        XCTAssertTrue(UpdateService.isNewer("0.10.0", than: "0.9.0"))
        XCTAssertTrue(UpdateService.isNewer("0.1.10", than: "0.1.9"))
    }

    func testLeadingVAndMismatchedSegmentLengths() {
        XCTAssertTrue(UpdateService.isNewer("v0.1.2", than: "0.1.1"))
        XCTAssertTrue(UpdateService.isNewer("0.2", than: "0.1.9"))     // 0.2(.0) > 0.1.9
        XCTAssertFalse(UpdateService.isNewer("0.1", than: "0.1.0"))    // equal
    }

    // MARK: Host pinning

    func testAssetURLPinnedToGitHub() {
        XCTAssertNotNil(UpdateService.validatedAssetURL(
            "https://github.com/robogears/VibeLight/releases/download/v0.1.2/VibeLight-0.1.2-arm64.zip"))
        XCTAssertNotNil(UpdateService.validatedAssetURL(
            "https://objects.githubusercontent.com/gh/abc/VibeLight.zip"))
    }

    func testAssetURLRejectsNonGitHubAndPlainHTTP() {
        XCTAssertNil(UpdateService.validatedAssetURL("http://github.com/x/VibeLight.zip")) // not https
        XCTAssertNil(UpdateService.validatedAssetURL("https://evil.example.com/VibeLight.zip"))
        XCTAssertNil(UpdateService.validatedAssetURL("https://github.com.evil.com/VibeLight.zip"))
        XCTAssertNil(UpdateService.validatedAssetURL("not a url"))
    }

    // MARK: Release parsing

    func testParsePicksArm64ZipAsset() throws {
        let json = """
        {
          "tag_name": "v0.1.2",
          "html_url": "https://github.com/robogears/VibeLight/releases/tag/v0.1.2",
          "body": "notes here",
          "assets": [
            {"name": "Source.zip", "browser_download_url": "https://github.com/robogears/VibeLight/x86.zip", "size": 1},
            {"name": "VibeLight-0.1.2-arm64.zip", "browser_download_url": "https://github.com/robogears/VibeLight/releases/download/v0.1.2/VibeLight-0.1.2-arm64.zip", "size": 84934656}
          ]
        }
        """.data(using: .utf8)!
        let release = try UpdateService.parseRelease(json)
        XCTAssertEqual(release.version, "0.1.2")           // leading v stripped
        XCTAssertTrue(release.assetURL.absoluteString.contains("arm64.zip"))
        XCTAssertEqual(release.assetSize, 84_934_656)
        XCTAssertEqual(release.notes, "notes here")
    }

    func testParseThrowsWhenNoUsableAsset() {
        let json = """
        {"tag_name": "v0.1.2", "assets": [
          {"name": "notes.txt", "browser_download_url": "https://github.com/x/notes.txt", "size": 1}
        ]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try UpdateService.parseRelease(json))
    }

    func testParseRejectsOffHostAsset() {
        // Even a correctly-named asset must be rejected if it isn't on GitHub.
        let json = """
        {"tag_name": "v0.1.2", "assets": [
          {"name": "VibeLight-0.1.2-arm64.zip", "browser_download_url": "https://evil.example.com/VibeLight-0.1.2-arm64.zip", "size": 1}
        ]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try UpdateService.parseRelease(json))
    }

    func testParseRejectsNonArm64Zip() {
        // A ".zip" that isn't the "-arm64.zip" asset must NOT be accepted — there
        // is no generic-zip fallback (audit QOL-any-zip-arch-fallback).
        let json = """
        {"tag_name": "v0.1.2", "assets": [
          {"name": "VibeLight-0.1.2-x86_64.zip", "browser_download_url": "https://github.com/robogears/VibeLight/x86.zip", "size": 1}
        ]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try UpdateService.parseRelease(json))
    }

    // MARK: Checksum sidecar (the last integrity gate before self-install)

    func testSidecarHashExtraction() {
        let h = String(repeating: "a", count: 64)
        // `shasum`-style "<hash>  <file>", bare hash, and uppercase all yield the hash.
        XCTAssertEqual(UpdateService.sidecarExpectedHash(from: "\(h)  VibeLight-0.1.2-arm64.zip\n"), h)
        XCTAssertEqual(UpdateService.sidecarExpectedHash(from: h), h)
        XCTAssertEqual(UpdateService.sidecarExpectedHash(from: h.uppercased()), h)
    }

    func testSidecarHashRejectsMalformed() {
        XCTAssertNil(UpdateService.sidecarExpectedHash(from: "not a hash"))
        XCTAssertNil(UpdateService.sidecarExpectedHash(from: String(repeating: "a", count: 63))) // too short
        XCTAssertNil(UpdateService.sidecarExpectedHash(from: String(repeating: "z", count: 64))) // non-hex
        XCTAssertNil(UpdateService.sidecarExpectedHash(from: ""))
    }

    func testSha256HexAgainstKnownVectors() throws {
        let fm = FileManager.default
        func hash(of bytes: Data) throws -> String {
            let tmp = fm.temporaryDirectory.appendingPathComponent("vl-test-\(UUID().uuidString).bin")
            try bytes.write(to: tmp)
            defer { try? fm.removeItem(at: tmp) }
            return try UpdateService.sha256Hex(ofFileAt: tmp)
        }
        // Standard NIST SHA-256 test vectors.
        XCTAssertEqual(try hash(of: Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try hash(of: Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testSha256HexHandlesMultiChunkFile() throws {
        // Larger than the 1 MiB streaming chunk, to exercise the read loop.
        let fm = FileManager.default
        let big = Data(repeating: 0x5A, count: 3_000_000)
        let tmp = fm.temporaryDirectory.appendingPathComponent("vl-test-\(UUID().uuidString).bin")
        try big.write(to: tmp)
        defer { try? fm.removeItem(at: tmp) }
        // Cross-check against CryptoKit over the whole buffer.
        let expected = SHA256.hash(data: big).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try UpdateService.sha256Hex(ofFileAt: tmp), expected)
    }
}
