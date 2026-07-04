import XCTest
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
}
