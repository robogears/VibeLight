import XCTest
@testable import VibeLight

/// FocusEngine is pure state — every Big Picture navigation behavior is
/// asserted here without a UI. If a test in this file breaks, controller
/// navigation broke.
@MainActor
final class FocusEngineTests: XCTestCase {

    // MARK: - Fixtures

    /// Item IDs are "<section>-<index>" so assertions read spatially.
    private func ids(_ prefix: String, _ count: Int) -> [String] {
        (0..<count).map { "\(prefix)-\($0)" }
    }

    private func shelf(_ id: String, count: Int) -> FocusSection {
        FocusSection(id: id, kind: .shelf, itemIDs: ids(id, count))
    }

    private func grid(_ id: String, columns: Int, count: Int) -> FocusSection {
        FocusSection(id: id, kind: .grid(columns: columns), itemIDs: ids(id, count))
    }

    private func vList(_ id: String, count: Int) -> FocusSection {
        FocusSection(id: id, kind: .vList, itemIDs: ids(id, count))
    }

    private func makeEngine(_ sections: [FocusSection]) -> FocusEngine {
        let engine = FocusEngine()
        engine.setSections(sections)
        return engine
    }

    @discardableResult
    private func press(_ engine: FocusEngine, _ direction: MoveDirection) -> Bool {
        engine.handle(.move(direction))
    }

    // MARK: - Initial focus

    func testFocusFirstFocusesFirstItemOfFirstNonEmptySection() {
        let engine = makeEngine([shelf("A", count: 0), shelf("B", count: 3)])
        engine.focusFirst()
        XCTAssertEqual(engine.focusedItemID, "B-0")
        XCTAssertEqual(engine.focusedSectionID, "B")
    }

    func testFocusFirstWithNoItemsClearsFocus() {
        let engine = makeEngine([shelf("A", count: 0)])
        engine.focusFirst()
        XCTAssertNil(engine.focusedItemID)
        XCTAssertNil(engine.focusedSectionID)
    }

    func testMoveWithNoFocusEstablishesFocusAndConsumes() {
        let engine = makeEngine([shelf("A", count: 2)])
        XCTAssertTrue(press(engine, .down))
        XCTAssertEqual(engine.focusedItemID, "A-0")
    }

    func testMoveWithNoFocusableContentIsNotConsumed() {
        let engine = makeEngine([shelf("A", count: 0)])
        XCTAssertFalse(press(engine, .down))
        XCTAssertNil(engine.focusedItemID)
    }

    // MARK: - Shelf clamping

    func testShelfMovesLeftRightAndClampsWithoutWrap() {
        let engine = makeEngine([shelf("A", count: 3)])
        engine.focusFirst()

        XCTAssertFalse(press(engine, .left), "left edge must clamp, not wrap")
        XCTAssertEqual(engine.focusedItemID, "A-0")

        XCTAssertTrue(press(engine, .right))
        XCTAssertTrue(press(engine, .right))
        XCTAssertEqual(engine.focusedItemID, "A-2")

        XCTAssertFalse(press(engine, .right), "right edge must clamp, not wrap")
        XCTAssertEqual(engine.focusedItemID, "A-2")
    }

    func testSingleSectionVerticalMovesAreNotConsumed() {
        let engine = makeEngine([shelf("A", count: 3)])
        engine.focusFirst()
        XCTAssertFalse(press(engine, .up))
        XCTAssertFalse(press(engine, .down))
        XCTAssertEqual(engine.focusedItemID, "A-0")
    }

    func testNonNavigationEventsAreNotConsumed() {
        let engine = makeEngine([shelf("A", count: 3)])
        engine.focusFirst()
        XCTAssertFalse(engine.handle(.select))
        XCTAssertFalse(engine.handle(.back))
        XCTAssertFalse(engine.handle(.contextMenu))
        XCTAssertFalse(engine.handle(.detail))
        XCTAssertFalse(engine.handle(.settings))
        XCTAssertFalse(engine.handle(.quitChord))
        XCTAssertEqual(engine.focusedItemID, "A-0")
    }

    // MARK: - Section memory

    func testSectionMemoryRestoredOnReentry() {
        let engine = makeEngine([shelf("A", count: 6), shelf("B", count: 6)])
        engine.focusFirst()
        press(engine, .right)
        press(engine, .right)                      // A-2
        XCTAssertTrue(press(engine, .down))        // enter B
        press(engine, .right)
        press(engine, .right)                      // B-(entry+2)
        let bSpot = engine.focusedItemID

        XCTAssertTrue(press(engine, .up))
        XCTAssertEqual(engine.focusedItemID, "A-2", "A must remember its last index")

        XCTAssertTrue(press(engine, .down))
        XCTAssertEqual(engine.focusedItemID, bSpot, "B must remember its last index")
    }

    func testMemoryTakesPriorityOverFractionalMapping() {
        let engine = makeEngine([shelf("A", count: 10), shelf("B", count: 10)])
        engine.focus(itemID: "B-1")                // B remembers index 1
        engine.focus(itemID: "A-9")
        XCTAssertTrue(press(engine, .down))
        XCTAssertEqual(engine.focusedItemID, "B-1",
                       "remembered index wins over the fractional default")
    }

    func testStaleMemoryClampsWhenSectionShrinks() {
        let engine = makeEngine([shelf("A", count: 1), shelf("B", count: 9)])
        engine.focus(itemID: "B-8")                // B remembers index 8
        press(engine, .up)                         // park on A-0
        engine.setSections([shelf("A", count: 1), shelf("B", count: 3)])
        XCTAssertTrue(press(engine, .down))
        XCTAssertEqual(engine.focusedItemID, "B-2", "stale memory clamps to the new end")
    }

    // MARK: - Fractional shelf→shelf mapping

    func testFractionalMappingShelfToShelfAtRightEdge() {
        let engine = makeEngine([shelf("A", count: 10), shelf("B", count: 5)])
        engine.focus(itemID: "A-9")                // fraction 1.0
        XCTAssertTrue(press(engine, .down))
        XCTAssertEqual(engine.focusedItemID, "B-4",
                       "rightmost tile maps to rightmost tile below")
    }

    func testFractionalMappingShelfToShelfMidway() {
        let engine = makeEngine([shelf("A", count: 10), shelf("B", count: 5)])
        engine.focus(itemID: "A-4")                // fraction 4/9 ≈ 0.44
        XCTAssertTrue(press(engine, .down))
        XCTAssertEqual(engine.focusedItemID, "B-2")
    }

    func testFractionalMappingUpwardsToWiderShelf() {
        let engine = makeEngine([shelf("A", count: 9), shelf("B", count: 3)])
        engine.focus(itemID: "B-2")                // fraction 1.0
        XCTAssertTrue(press(engine, .up))
        XCTAssertEqual(engine.focusedItemID, "A-8")
    }

    func testSingleItemShelfEntersAtStart() {
        let engine = makeEngine([shelf("A", count: 5), shelf("B", count: 1)])
        engine.focus(itemID: "A-4")
        XCTAssertTrue(press(engine, .down))
        XCTAssertEqual(engine.focusedItemID, "B-0")
    }

    // MARK: - Grid traversal

    // Grid G: 3 columns, 8 items → rows [0 1 2] [3 4 5] [6 7]
    func testGridHorizontalMovesClampWithinRow() {
        let engine = makeEngine([grid("G", columns: 3, count: 8)])
        engine.focus(itemID: "G-0")
        XCTAssertFalse(press(engine, .left))
        XCTAssertTrue(press(engine, .right))       // G-1
        XCTAssertTrue(press(engine, .right))       // G-2
        XCTAssertFalse(press(engine, .right), "no wrap into the next row")
        XCTAssertEqual(engine.focusedItemID, "G-2")

        engine.focus(itemID: "G-3")
        XCTAssertFalse(press(engine, .left), "row start clamps even mid-grid")
    }

    func testGridRaggedLastRowClampsRightAtFinalItem() {
        let engine = makeEngine([grid("G", columns: 3, count: 8)])
        engine.focus(itemID: "G-7")                // last row col 1; col 2 doesn't exist
        XCTAssertFalse(press(engine, .right))
        XCTAssertEqual(engine.focusedItemID, "G-7")
    }

    func testGridVerticalRowMath() {
        let engine = makeEngine([grid("G", columns: 3, count: 8)])
        engine.focus(itemID: "G-1")
        XCTAssertTrue(press(engine, .down))
        XCTAssertEqual(engine.focusedItemID, "G-4")
        XCTAssertTrue(press(engine, .down))
        XCTAssertEqual(engine.focusedItemID, "G-7")
        XCTAssertTrue(press(engine, .up))
        XCTAssertEqual(engine.focusedItemID, "G-4")
        XCTAssertTrue(press(engine, .up))
        XCTAssertEqual(engine.focusedItemID, "G-1")
    }

    func testGridDownIntoRaggedLastRowClampsToFinalItem() {
        let engine = makeEngine([grid("G", columns: 3, count: 8)])
        engine.focus(itemID: "G-5")                // row 1 col 2; row 2 has no col 2
        XCTAssertTrue(press(engine, .down))
        XCTAssertEqual(engine.focusedItemID, "G-7")
    }

    func testGridExitsPastFirstAndLastRow() {
        let engine = makeEngine([
            shelf("A", count: 3),
            grid("G", columns: 3, count: 8),
            shelf("C", count: 2),
        ])
        engine.focus(itemID: "G-1")                // top row, col 1 → fraction 0.5
        XCTAssertTrue(press(engine, .up))
        XCTAssertEqual(engine.focusedSectionID, "A")
        XCTAssertEqual(engine.focusedItemID, "A-1", "col fraction maps into the shelf")

        engine.focus(itemID: "G-7")                // last row → down exits
        XCTAssertTrue(press(engine, .down))
        XCTAssertEqual(engine.focusedSectionID, "C")
        XCTAssertEqual(engine.focusedItemID, "C-1", "col 1 of 3 (0.5) maps to item 1 of 2")
    }

    func testGridBoundaryExitsAreNotConsumedWithoutNeighbor() {
        let engine = makeEngine([grid("G", columns: 3, count: 8)])
        engine.focus(itemID: "G-1")
        XCTAssertFalse(press(engine, .up))
        engine.focus(itemID: "G-7")
        XCTAssertFalse(press(engine, .down))
    }

    func testGridEntryFromAboveMapsFractionIntoTopRow() {
        let engine = makeEngine([shelf("A", count: 10), grid("G", columns: 3, count: 8)])
        engine.focus(itemID: "A-9")                // fraction 1.0
        XCTAssertTrue(press(engine, .down))
        XCTAssertEqual(engine.focusedItemID, "G-2", "enters top row at the mapped column")
    }

    func testGridEntryFromBelowLandsInRaggedLastRow() {
        let engine = makeEngine([grid("G", columns: 3, count: 8), shelf("B", count: 10)])
        engine.focus(itemID: "B-9")                // fraction 1.0 → col 2, but last row ends at col 1
        XCTAssertTrue(press(engine, .up))
        XCTAssertEqual(engine.focusedItemID, "G-7",
                       "ragged last row clamps the mapped column to its final item")
    }

    func testSingleColumnGridBehavesLikeVerticalTraversal() {
        let engine = makeEngine([grid("G", columns: 1, count: 3)])
        engine.focus(itemID: "G-0")
        XCTAssertTrue(press(engine, .down))
        XCTAssertEqual(engine.focusedItemID, "G-1")
        XCTAssertFalse(press(engine, .right))
        XCTAssertFalse(press(engine, .left))
    }

    // MARK: - Vertical list traversal

    func testVListTraversalBoundariesAndUnconsumedHorizontal() {
        let engine = makeEngine([
            shelf("A", count: 2),
            vList("V", count: 3),
            shelf("C", count: 2),
        ])
        engine.focusFirst()                        // A-0
        XCTAssertTrue(press(engine, .down))
        XCTAssertEqual(engine.focusedItemID, "V-0", "entering from above lands at the top")

        XCTAssertFalse(press(engine, .left), "vList leaves left/right to the UI")
        XCTAssertFalse(press(engine, .right))

        XCTAssertTrue(press(engine, .down))        // V-1
        XCTAssertTrue(press(engine, .down))        // V-2
        XCTAssertTrue(press(engine, .down))        // exits to C
        XCTAssertEqual(engine.focusedItemID, "C-0")

        XCTAssertTrue(press(engine, .up))
        XCTAssertEqual(engine.focusedItemID, "V-2", "vList memory restored on re-entry")

        XCTAssertTrue(press(engine, .up))          // V-1
        XCTAssertTrue(press(engine, .up))          // V-0
        XCTAssertTrue(press(engine, .up))          // exits to A
        XCTAssertEqual(engine.focusedItemID, "A-0")
    }

    func testVListEntryFromBelowLandsAtBottom() {
        let engine = makeEngine([vList("V", count: 3), shelf("B", count: 2)])
        engine.focus(itemID: "B-1")
        XCTAssertTrue(press(engine, .up))
        XCTAssertEqual(engine.focusedItemID, "V-2")
    }

    // MARK: - Empty-section skipping

    func testEmptySectionsAreSkippedInVerticalTraversal() {
        let engine = makeEngine([
            shelf("A", count: 2),
            shelf("Empty", count: 0),
            shelf("C", count: 3),
        ])
        engine.focusFirst()
        XCTAssertTrue(press(engine, .down))
        XCTAssertEqual(engine.focusedSectionID, "C", "empty section must not swallow the press")
        XCTAssertTrue(press(engine, .up))
        XCTAssertEqual(engine.focusedSectionID, "A")
    }

    // MARK: - prevSection / nextSection

    func testSectionJumpsSkipEmptyAndClampAtEnds() {
        let engine = makeEngine([
            shelf("A", count: 2),
            shelf("Empty", count: 0),
            shelf("C", count: 3),
            shelf("TrailingEmpty", count: 0),
        ])
        engine.focusFirst()
        XCTAssertFalse(engine.handle(.prevSection), "already at the first section")

        XCTAssertTrue(engine.handle(.nextSection))
        XCTAssertEqual(engine.focusedSectionID, "C")

        XCTAssertFalse(engine.handle(.nextSection),
                       "a trailing empty section is not a jump target")
        XCTAssertEqual(engine.focusedSectionID, "C")

        XCTAssertTrue(engine.handle(.prevSection))
        XCTAssertEqual(engine.focusedSectionID, "A")
    }

    func testSectionJumpRestoresMemory() {
        let engine = makeEngine([shelf("A", count: 5), shelf("B", count: 5)])
        engine.focus(itemID: "B-3")
        engine.focus(itemID: "A-1")
        XCTAssertTrue(engine.handle(.nextSection))
        XCTAssertEqual(engine.focusedItemID, "B-3")
    }

    func testSectionJumpWithNoFocusEstablishesFocus() {
        let engine = makeEngine([shelf("A", count: 2)])
        XCTAssertTrue(engine.handle(.nextSection))
        XCTAssertEqual(engine.focusedItemID, "A-0")
    }

    // MARK: - setSections robustness

    func testVanishedItemRefocusesNearestIndexInSameSection() {
        let engine = makeEngine([shelf("A", count: 5)])
        engine.focus(itemID: "A-2")
        // A-2 removed; the item that slides into slot 2 is A-3.
        engine.setSections([
            FocusSection(id: "A", kind: .shelf, itemIDs: ["A-0", "A-1", "A-3", "A-4"]),
        ])
        XCTAssertEqual(engine.focusedItemID, "A-3")
        XCTAssertEqual(engine.focusedSectionID, "A")
    }

    func testVanishedItemAtEndClampsToNewLastItem() {
        let engine = makeEngine([shelf("A", count: 5)])
        engine.focus(itemID: "A-4")
        engine.setSections([
            FocusSection(id: "A", kind: .shelf, itemIDs: ["A-0", "A-1"]),
        ])
        XCTAssertEqual(engine.focusedItemID, "A-1")
    }

    func testVanishedSectionRefocusesNearestSection() {
        let engine = makeEngine([
            shelf("A", count: 2), shelf("B", count: 2), shelf("C", count: 2),
        ])
        engine.focus(itemID: "B-1")
        engine.setSections([shelf("A", count: 2), shelf("C", count: 2)])
        XCTAssertEqual(engine.focusedSectionID, "C", "nearest section by ordinal position")
        XCTAssertNotNil(engine.focusedItemID)
    }

    func testVanishedLastSectionFallsBackToPrecedingSection() {
        let engine = makeEngine([
            shelf("A", count: 2), shelf("B", count: 2), shelf("C", count: 2),
        ])
        engine.focus(itemID: "C-0")
        engine.setSections([shelf("A", count: 2), shelf("B", count: 2)])
        XCTAssertEqual(engine.focusedSectionID, "B")
    }

    func testSurvivingItemKeepsFocusWhenItMovesBetweenSections() {
        let engine = makeEngine([
            FocusSection(id: "A", kind: .shelf, itemIDs: ["a0", "a1"]),
            FocusSection(id: "B", kind: .shelf, itemIDs: ["b0"]),
        ])
        engine.focus(itemID: "a1")

        var changes: [(String?, String?)] = []
        engine.onFocusChange = { changes.append(($0, $1)) }

        engine.setSections([
            FocusSection(id: "A", kind: .shelf, itemIDs: ["a0"]),
            FocusSection(id: "B", kind: .shelf, itemIDs: ["b0", "a1"]),
        ])
        XCTAssertEqual(engine.focusedItemID, "a1", "item survived the refresh")
        XCTAssertEqual(engine.focusedSectionID, "B", "section bookkeeping follows the item")
        XCTAssertTrue(changes.isEmpty, "same item → no focus-change callback")

        // Memory must track the item's new home: re-entry lands on it.
        press(engine, .up)
        press(engine, .down)
        XCTAssertEqual(engine.focusedItemID, "a1")
    }

    func testAllContentVanishingClearsFocus() {
        let engine = makeEngine([shelf("A", count: 2)])
        engine.focusFirst()
        var changes: [(String?, String?)] = []
        engine.onFocusChange = { changes.append(($0, $1)) }

        engine.setSections([])
        XCTAssertNil(engine.focusedItemID)
        XCTAssertNil(engine.focusedSectionID)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].0, "A-0")
        XCTAssertNil(changes[0].1)
    }

    func testIdenticalSetSectionsIsANoOp() {
        let sections = [shelf("A", count: 3), grid("G", columns: 2, count: 4)]
        let engine = makeEngine(sections)
        engine.focusFirst()
        var changes: [(String?, String?)] = []
        engine.onFocusChange = { changes.append(($0, $1)) }

        engine.setSections(sections)
        XCTAssertEqual(engine.focusedItemID, "A-0")
        XCTAssertTrue(changes.isEmpty)
    }

    func testMemorySurvivesSectionDisappearingAndReturning() {
        let engine = makeEngine([shelf("A", count: 2), shelf("B", count: 5)])
        engine.focus(itemID: "B-3")
        engine.focus(itemID: "A-0")

        engine.setSections([shelf("A", count: 2)])            // B vanishes (refresh hiccup)
        engine.setSections([shelf("A", count: 2), shelf("B", count: 5)])  // B returns
        XCTAssertTrue(press(engine, .down))
        XCTAssertEqual(engine.focusedItemID, "B-3", "memory outlives a transient refresh")
    }

    // MARK: - focus(itemID:) hover parity

    func testFocusItemIDSetsFocusAndMemory() {
        let engine = makeEngine([shelf("A", count: 3), shelf("B", count: 3)])
        engine.focus(itemID: "B-2")
        XCTAssertEqual(engine.focusedItemID, "B-2")
        XCTAssertEqual(engine.focusedSectionID, "B")

        press(engine, .up)
        XCTAssertTrue(press(engine, .down))
        XCTAssertEqual(engine.focusedItemID, "B-2", "hover focus feeds section memory")
    }

    func testFocusUnknownItemIDIsIgnored() {
        let engine = makeEngine([shelf("A", count: 3)])
        engine.focusFirst()
        engine.focus(itemID: "ghost")
        XCTAssertEqual(engine.focusedItemID, "A-0")
        XCTAssertEqual(engine.focusedSectionID, "A")
    }

    // MARK: - onFocusChange

    func testOnFocusChangeFiresWithOldAndNew() {
        let engine = makeEngine([shelf("A", count: 3)])
        var changes: [(String?, String?)] = []
        engine.onFocusChange = { changes.append(($0, $1)) }

        engine.focusFirst()
        press(engine, .right)
        XCTAssertEqual(changes.count, 2)
        XCTAssertNil(changes[0].0)
        XCTAssertEqual(changes[0].1, "A-0")
        XCTAssertEqual(changes[1].0, "A-0")
        XCTAssertEqual(changes[1].1, "A-1")
    }

    func testOnFocusChangeDoesNotFireForRefocusOfSameItem() {
        let engine = makeEngine([shelf("A", count: 3)])
        engine.focusFirst()
        var changes: [(String?, String?)] = []
        engine.onFocusChange = { changes.append(($0, $1)) }

        engine.focus(itemID: "A-0")                // hover over the already-focused tile
        engine.focusFirst()
        XCTAssertTrue(changes.isEmpty, "no-op refocus must not spam haptics/scrolls")
    }

    func testOnFocusChangeFiresForSetSectionsRepair() {
        let engine = makeEngine([shelf("A", count: 3)])
        engine.focus(itemID: "A-1")
        var changes: [(String?, String?)] = []
        engine.onFocusChange = { changes.append(($0, $1)) }

        engine.setSections([
            FocusSection(id: "A", kind: .shelf, itemIDs: ["A-0", "A-2"]),
        ])
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].0, "A-1")
        XCTAssertEqual(changes[0].1, "A-2")
    }

    // MARK: - Duplicate item IDs across sections

    func testDuplicateIDResolvesToFocusedSection() {
        // Same app surfaced in "Recent" and "All" — moving right from the grid
        // copy must move within the grid, not the shelf.
        let engine = makeEngine([
            FocusSection(id: "recent", kind: .shelf, itemIDs: ["dupe", "r1"]),
            FocusSection(id: "all", kind: .grid(columns: 2), itemIDs: ["g0", "dupe", "g2"]),
        ])
        engine.focus(itemID: "g0")
        press(engine, .right)                      // → "dupe" inside the grid
        XCTAssertEqual(engine.focusedItemID, "dupe")
        XCTAssertEqual(engine.focusedSectionID, "all")

        XCTAssertTrue(press(engine, .down), "row math applies in the grid copy's section")
        XCTAssertEqual(engine.focusedItemID, "g2")
        XCTAssertEqual(engine.focusedSectionID, "all")
    }
}
