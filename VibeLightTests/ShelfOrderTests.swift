import XCTest
@testable import VibeLight

/// Owner: whatever is running on the PC (Desktop, Steam Big Picture, a game)
/// is always the far-left tile.
final class ShelfOrderTests: XCTestCase {
    private func app(_ id: Int, _ name: String, idx: Int? = nil) -> StreamApp {
        StreamApp(id: id, rawName: name, uuid: nil, idx: idx, isHDRSupported: false, isHidden: false)
    }

    private func order(_ apps: [StreamApp], running: Int?, launched: [Int: Date] = [:]) -> [String] {
        apps.sorted {
            AppState.shelfPrecedes($0, $1, runningID: running,
                                   lastA: launched[$0.id] ?? .distantPast,
                                   lastB: launched[$1.id] ?? .distantPast)
        }.map(\.name)
    }

    func testRunningAppBeatsRecency() {
        let apps = [app(1, "Desktop", idx: 0), app(2, "Steam Big Picture", idx: 1), app(3, "Hades", idx: 2)]
        let now = Date()
        XCTAssertEqual(order(apps, running: 2, launched: [3: now, 1: now.addingTimeInterval(-60)]),
                       ["Steam Big Picture", "Hades", "Desktop"])
    }

    func testNothingRunningKeepsRecencyThenHostOrder() {
        let apps = [app(1, "Desktop", idx: 0), app(2, "Steam Big Picture", idx: 1), app(3, "Hades", idx: 2)]
        XCTAssertEqual(order(apps, running: nil, launched: [3: Date()]),
                       ["Hades", "Desktop", "Steam Big Picture"])
    }

    /// A running id that isn't on the shelf (hidden app, stale list) changes nothing.
    func testUnknownRunningIDChangesNothing() {
        let apps = [app(1, "Desktop", idx: 0), app(2, "Steam Big Picture", idx: 1)]
        XCTAssertEqual(order(apps, running: 99), ["Desktop", "Steam Big Picture"])
    }
}

/// Owner: the games row holds still "until it really needs to change", then
/// moves just enough, and never past either end.
final class ShelfScrollTests: XCTestCase {
    private let viewport: CGFloat = 1440   // iPad / TV design canvas width

    private func geometry(at offset: CGFloat = 0, count: Int = 12) -> ShelfScroll.Geometry {
        ShelfScroll.Geometry(offset: offset, viewport: viewport, content: ShelfScroll.contentWidth(count: count))
    }

    private func left(_ i: Int) -> CGFloat { ShelfScroll.leading + CGFloat(i) * (ShelfScroll.tile + ShelfScroll.spacing) }

    /// Owner: one step right from the first game moved the whole row and left
    /// the second half off-screen. While the tile (and a peek past it) is on
    /// screen, nothing moves at all.
    func testFirstTilesNeverMoveTheRow() {
        for i in 0..<5 {
            XCTAssertEqual(ShelfScroll.offset(index: i, from: geometry()), 0, "tile \(i)")
        }
    }

    /// Past the edge it moves just enough: the tile plus the margin, one tile per step.
    func testMovesOnlyWhatItMust() {
        let x5 = ShelfScroll.offset(index: 5, from: geometry())
        XCTAssertEqual(x5, left(5) + ShelfScroll.tile + ShelfScroll.margin - viewport, accuracy: 0.01)
        let x6 = ShelfScroll.offset(index: 6, from: geometry(at: x5))
        XCTAssertEqual(x6 - x5, ShelfScroll.tile + ShelfScroll.spacing, accuracy: 0.01)
        // Stepping back while the tile is still in view: no movement.
        XCTAssertEqual(ShelfScroll.offset(index: 5, from: geometry(at: x6)), x6, accuracy: 0.01)
    }

    /// Going left past the edge brings the tile back in with the same margin.
    func testGoingLeftRevealsTheTile() {
        let far = ShelfScroll.offset(index: 11, from: geometry())
        let x = ShelfScroll.offset(index: 2, from: geometry(at: far))
        XCTAssertEqual(x, left(2) - ShelfScroll.margin, accuracy: 0.01)
    }

    func testNeverScrollsPastEitherEnd() {
        let g = geometry()
        XCTAssertEqual(ShelfScroll.offset(index: 11, from: g), g.content - viewport, accuracy: 0.01)
        XCTAssertEqual(ShelfScroll.offset(index: 0, from: geometry(at: 500)), 0)
    }

    func testShortRowNeverMoves() {
        for i in 0..<4 { XCTAssertEqual(ShelfScroll.offset(index: i, from: geometry(count: 4)), 0) }
    }

    /// The legacy (iOS 17) anchor asks for exactly the computed spot.
    func testAnchorLandsTheTileWhereTheOffsetSays() {
        let a = ShelfScroll.anchor(index: 1, offset: 0, viewport: viewport)
        let left = a.x * (viewport - ShelfScroll.tile)
        XCTAssertEqual(left, ShelfScroll.leading + ShelfScroll.tile + ShelfScroll.spacing, accuracy: 0.01)
    }

    /// The row scrolls by exact offsets on current systems.
    func testShelfScrollsToExactOffsets() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let home = try String(contentsOf: root.appendingPathComponent("VibeLight/UI/HomeView.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains("withAnimation(Theme.focusSpring) { position.scrollTo(x: x) }"))
        XCTAssertTrue(home.contains(".onScrollGeometryChange(for: ShelfScroll.Geometry.self)"))
    }
}
