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

/// Owner: the games row holds still for the first few tiles, keeps the
/// selected tile in the middle after that, and holds still at the end.
final class ShelfScrollTests: XCTestCase {
    private let viewport: CGFloat = 1440   // iPad / TV design canvas width

    func testFirstTilesNeverMoveTheRow() {
        for i in 0..<3 {
            XCTAssertEqual(ShelfScroll.offset(index: i, count: 12, viewport: viewport), 0, "tile \(i)")
        }
    }

    func testMiddleTilesSitInTheMiddle() {
        let i = 6
        let offset = ShelfScroll.offset(index: i, count: 12, viewport: viewport)
        let centre = ShelfScroll.leading + CGFloat(i) * (ShelfScroll.tile + ShelfScroll.spacing) + ShelfScroll.tile / 2
        XCTAssertEqual(centre - offset, viewport / 2, accuracy: 0.01)
    }

    func testLastTilesNeverScrollPastTheEnd() {
        let count = 12
        let content = ShelfScroll.leading + CGFloat(count) * ShelfScroll.tile
            + CGFloat(count - 1) * ShelfScroll.spacing + ShelfScroll.trailing
        let end = content - viewport
        XCTAssertEqual(ShelfScroll.offset(index: count - 1, count: count, viewport: viewport), end, accuracy: 0.01)
        XCTAssertEqual(ShelfScroll.offset(index: count - 2, count: count, viewport: viewport), end, accuracy: 0.01)
    }

    func testShortRowNeverMoves() {
        for i in 0..<4 { XCTAssertEqual(ShelfScroll.offset(index: i, count: 4, viewport: viewport), 0) }
    }

    /// The anchor asks for exactly the computed spot: at the start a tile
    /// stays where it already is.
    func testAnchorLandsTheTileWhereTheOffsetSays() {
        let a = ShelfScroll.anchor(index: 1, offset: 0, viewport: viewport)
        let left = a.x * (viewport - ShelfScroll.tile)
        XCTAssertEqual(left, ShelfScroll.leading + ShelfScroll.tile + ShelfScroll.spacing, accuracy: 0.01)
    }
}
