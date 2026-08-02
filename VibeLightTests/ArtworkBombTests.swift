import XCTest
@testable import VibeLight

/// Box art arrives from the host, so its *decoded* size is host-controlled.
///
/// The 16 MB response cap bounds the bytes on the wire and says nothing about
/// what those bytes expand to: PNG and JPEG both squeeze a flat image to almost
/// nothing, so a 30000×30000 tile is a few hundred KB in flight and ~3.6 GB once
/// decoded — and it would be written to the cache, so every launch afterwards
/// re-decoded it. These lock in the dimension ceiling.
final class ArtworkBombTests: XCTestCase {

    func testRealBoxArtSizesAreAccepted() {
        // GameStream's native art, SteamGridDB's largest grids, and a generous
        // poster — all legitimate, none should be refused.
        for size in [(300, 400), (600, 900), (920, 430), (1920, 2880), (5000, 8000)] {
            XCTAssertTrue(ArtworkStore.isPlausibleArtSize(size),
                          "\(size.0)×\(size.1) is real box art and must be accepted")
        }
    }

    func testDecompressionBombsAreRefused() {
        for size in [(30_000, 30_000),      // ~3.6 GB decoded, ~KB on the wire
                     (100_000, 100),        // absurd on one axis only
                     (100, 100_000),
                     (8_193, 8_193),        // just past the per-side ceiling
                     (10_000, 10_000)] {    // 100 MP, past the pixel budget
            XCTAssertFalse(ArtworkStore.isPlausibleArtSize(size),
                           "\(size.0)×\(size.1) must be refused")
        }
    }

    func testDegenerateSizesAreRefused() {
        for size in [(0, 0), (0, 400), (300, 0), (-1, 400), (300, -1)] {
            XCTAssertFalse(ArtworkStore.isPlausibleArtSize(size),
                           "\(size.0)×\(size.1) is not an image")
        }
    }

    func testTheCeilingItselfIsOnTheAcceptedSide() {
        // Exactly at both limits: allowed. One past either: refused. (The
        // multiply happens only after both sides are bounded, so the pixel
        // check can never overflow.)
        XCTAssertTrue(ArtworkStore.isPlausibleArtSize((ArtworkStore.maxArtDimension, 4_000)))
        XCTAssertFalse(ArtworkStore.isPlausibleArtSize((ArtworkStore.maxArtDimension + 1, 4_000)))
        XCTAssertTrue(ArtworkStore.isPlausibleArtSize((5_000, ArtworkStore.maxArtPixels / 5_000)))
        XCTAssertFalse(ArtworkStore.isPlausibleArtSize((5_000, ArtworkStore.maxArtPixels / 5_000 + 1)))
    }
}
