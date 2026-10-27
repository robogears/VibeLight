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
