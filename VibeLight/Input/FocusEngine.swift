import Foundation
import Observation

// MARK: - Content model

/// One vertically-stacked band of focusable content (a shelf, a grid, or a
/// vertical list). Sections are ordered top-to-bottom as handed to
/// `FocusEngine.setSections(_:)`.
///
/// Navigation is index-based within a section BY DESIGN: `LazyHStack` /
/// `LazyVGrid` drop the geometry of offscreen tiles, so any frame-based focus
/// search goes blind the moment a shelf scrolls. Ordinal math never does.
struct FocusSection: Identifiable, Sendable, Equatable {
    /// How items flow inside the section — this decides the directional math.
    enum Kind: Sendable, Equatable {
        /// One horizontal row: left/right move inside (clamped, no wrap),
        /// up/down leave the section.
        case shelf
        /// Row-major wrapping grid with a fixed column count. Left/right stay
        /// within the current row; up/down do row math and only leave the
        /// section past the first/last row. `columns` < 1 is treated as 1.
        case grid(columns: Int)
        /// One vertical column: up/down move inside before leaving; left/right
        /// are NOT consumed so the UI can repurpose them (e.g. sidebar ⇄ content).
        case vList
    }

    let id: String
    var kind: Kind
    var itemIDs: [String]
}

// MARK: - Engine

/// The custom spatial focus model that makes controller navigation possible.
///
/// macOS SwiftUI/AppKit focus is keyboard-only — game controllers never drive
/// it (that machinery is tvOS/UIKit). So VibeLight owns "what is focused" as
/// plain observable state, and every input source (controller d-pad/stick,
/// keyboard arrows, mouse hover) feeds the same engine. Fully deterministic,
/// animatable, and testable without a UI.
///
/// Feel notes (what makes it read as Big Picture / tvOS):
/// - **Per-section memory**: each section remembers the last index the user
///   sat on; re-entering restores it, so vertical round-trips don't lose your
///   place.
/// - **Fractional mapping**: entering a section you've never visited lands at
///   the horizontally-nearest slot (a shelf's rightmost tile drops into the
///   rightmost tile of the shelf below), so first contact still feels spatial.
/// - **No wrapping**: edges clamp. `handle(_:)` returns `false` on a clamped
///   edge so callers can play an "edge bump" haptic or ignore it.
///
/// Item IDs should be unique across sections. If the same underlying app
/// appears in two sections (e.g. "Recent" and "All"), namespace the IDs
/// per-section (`"recent:<uuid>"`) — the engine tolerates duplicates by
/// preferring the currently-focused section when resolving, but namespacing
/// keeps hover/scroll targeting unambiguous.
@MainActor
@Observable
final class FocusEngine {

    /// The focused item, or nil when nothing is focusable. Observable so tiles
    /// can compare against their own ID and animate. Mutate only through
    /// `focus(itemID:)` / `focusFirst()` / `handle(_:)` so per-section memory
    /// stays coherent.
    private(set) var focusedItemID: String?

    /// The section containing the focused item. Stored (not derived) so a
    /// duplicate item ID in another section can never confuse resolution.
    private(set) var focusedSectionID: String?

    /// Fired on every focus *item* change — including repairs inside
    /// `setSections(_:)` — with the old and new IDs. Intended for
    /// scroll-into-view and haptic ticks. Not fired when only the section
    /// changes while the item stays the same (item migrated between sections).
    @ObservationIgnored var onFocusChange: ((_ old: String?, _ new: String?) -> Void)?

    /// Current content, top-to-bottom. Not observed: the UI renders from its
    /// own library state; the engine only navigates it.
    @ObservationIgnored private var sections: [FocusSection] = []

    /// Per-section memory: section ID → last focused index. Deliberately NOT
    /// pruned when a section disappears — sections come and go across library
    /// refreshes (e.g. "Recent" empties) and the user expects their spot back.
    /// Stale indices are clamped on use.
    @ObservationIgnored private var memory: [String: Int] = [:]

    // MARK: Content updates

    /// Replaces the content model, repairing focus if the focused item moved
    /// or vanished. Called on every library refresh, so the no-change path is
    /// a single equality check and everything else is one linear pass.
    ///
    /// Repair policy when the focused item is gone:
    /// 1. Same section still exists and is non-empty → nearest surviving index
    ///    (the item that now occupies the vanished slot, clamped to the end).
    /// 2. Section gone or empty → nearest non-empty section by ordinal
    ///    position (ties prefer downward), restoring that section's memory.
    /// 3. Nothing focusable at all → focus clears to nil.
    func setSections(_ newSections: [FocusSection]) {
        guard newSections != sections else { return }
        let oldSections = sections
        sections = newSections

        guard let itemID = focusedItemID else { return }

        // Focused item survived (possibly at a new index or in a new section):
        // keep it, refresh bookkeeping.
        if let loc = location(of: itemID) {
            let section = sections[loc.sectionIndex]
            memory[section.id] = loc.itemIndex
            if focusedSectionID != section.id { focusedSectionID = section.id }
            return
        }

        let oldSectionOrdinal = oldSections.firstIndex { $0.id == focusedSectionID }
        let oldItemIndex = oldSectionOrdinal.flatMap {
            oldSections[$0].itemIDs.firstIndex(of: itemID)
        }

        // Same section survived with items → land where the vanished item was.
        if let sectionIndex = sections.firstIndex(where: { $0.id == focusedSectionID }),
           !sections[sectionIndex].itemIDs.isEmpty {
            focusItem(at: oldItemIndex ?? memory[sections[sectionIndex].id] ?? 0,
                      inSection: sectionIndex)
            return
        }

        // Section gone/empty → nearest non-empty section by position.
        let anchor: Int
        if let survivingIndex = sections.firstIndex(where: { $0.id == focusedSectionID }) {
            anchor = survivingIndex
        } else {
            anchor = min(oldSectionOrdinal ?? 0, max(0, sections.count - 1))
        }
        if let target = nearestNonEmptySection(to: anchor) {
            focusItem(at: memory[sections[target].id] ?? 0, inSection: target)
        } else {
            clearFocus()
        }
    }

    // MARK: Focus mutation

    /// Focuses a specific item — mouse-hover parity so pointer and controller
    /// share one focus truth. Unknown IDs are ignored (a hover racing a
    /// library refresh must not crash or clear focus).
    func focus(itemID: String) {
        guard let loc = location(of: itemID) else { return }
        focusItem(at: loc.itemIndex, inSection: loc.sectionIndex)
    }

    /// Focuses the first item of the first non-empty section (initial focus
    /// after content load). Clears focus if nothing is focusable.
    func focusFirst() {
        _ = focusFirstIfPossible()
    }

    // MARK: Event handling

    /// Routes a semantic navigation event. Returns whether the engine consumed
    /// it: `false` means either the event isn't navigation (`.select`, `.back`,
    /// …) or the move hit a clamped edge — callers can use that for edge
    /// haptics or fallback handling. Any movement event while nothing is
    /// focused establishes initial focus and counts as consumed.
    func handle(_ event: NavigationEvent) -> Bool {
        switch event {
        case .move(let direction):
            return move(direction)
        case .prevSection:
            return jumpSection(step: -1)
        case .nextSection:
            return jumpSection(step: +1)
        case .select, .back, .contextMenu, .detail, .settings, .quitChord:
            return false
        }
    }

    // MARK: - Movement

    private func move(_ direction: MoveDirection) -> Bool {
        guard let itemID = focusedItemID, let loc = location(of: itemID) else {
            return focusFirstIfPossible()
        }
        let section = sections[loc.sectionIndex]
        let count = section.itemIDs.count

        switch section.kind {
        case .shelf:
            switch direction {
            case .left:
                guard loc.itemIndex > 0 else { return false }
                focusItem(at: loc.itemIndex - 1, inSection: loc.sectionIndex)
                return true
            case .right:
                guard loc.itemIndex < count - 1 else { return false }
                focusItem(at: loc.itemIndex + 1, inSection: loc.sectionIndex)
                return true
            case .up:
                return exitVertically(from: loc, step: -1)
            case .down:
                return exitVertically(from: loc, step: +1)
            }

        case .grid(let columns):
            let cols = max(1, columns)
            let row = loc.itemIndex / cols
            let col = loc.itemIndex % cols
            let lastRow = (count - 1) / cols
            switch direction {
            case .left:
                guard col > 0 else { return false }
                focusItem(at: loc.itemIndex - 1, inSection: loc.sectionIndex)
                return true
            case .right:
                // Two clamps: the row's right edge, and the ragged end of the
                // last row (item index past the final item doesn't exist).
                guard col < cols - 1, loc.itemIndex + 1 < count else { return false }
                focusItem(at: loc.itemIndex + 1, inSection: loc.sectionIndex)
                return true
            case .up:
                guard row > 0 else { return exitVertically(from: loc, step: -1) }
                focusItem(at: loc.itemIndex - cols, inSection: loc.sectionIndex)
                return true
            case .down:
                guard row < lastRow else { return exitVertically(from: loc, step: +1) }
                // Ragged last row: clamp to its final item rather than refusing.
                focusItem(at: min(loc.itemIndex + cols, count - 1), inSection: loc.sectionIndex)
                return true
            }

        case .vList:
            switch direction {
            case .up:
                guard loc.itemIndex > 0 else { return exitVertically(from: loc, step: -1) }
                focusItem(at: loc.itemIndex - 1, inSection: loc.sectionIndex)
                return true
            case .down:
                guard loc.itemIndex < count - 1 else { return exitVertically(from: loc, step: +1) }
                focusItem(at: loc.itemIndex + 1, inSection: loc.sectionIndex)
                return true
            case .left, .right:
                return false
            }
        }
    }

    /// Section jump (LB/RB). Reuses the vertical-exit path so memory and
    /// fractional entry behave identically to d-pad traversal.
    private func jumpSection(step: Int) -> Bool {
        guard let itemID = focusedItemID, let loc = location(of: itemID) else {
            return focusFirstIfPossible()
        }
        return exitVertically(from: loc, step: step)
    }

    /// Leaves the current section vertically into the nearest non-empty
    /// neighbor (empty sections are skipped — they have nothing to focus and
    /// must not swallow a d-pad press). Returns false at the top/bottom edge.
    private func exitVertically(
        from loc: (sectionIndex: Int, itemIndex: Int), step: Int
    ) -> Bool {
        guard let target = nonEmptySectionIndex(from: loc.sectionIndex, step: step) else {
            return false
        }
        let fraction = horizontalFraction(
            section: sections[loc.sectionIndex], itemIndex: loc.itemIndex
        )
        let entry: VerticalEntry = step > 0 ? .fromTop : .fromBottom
        focusItem(at: entryIndex(into: sections[target], entry: entry, fraction: fraction),
                  inSection: target)
        return true
    }

    // MARK: - Spatial mapping

    /// Which edge a vertical move enters a section through — decides the row
    /// for grids and the end for vertical lists.
    private enum VerticalEntry { case fromTop, fromBottom }

    /// 0…1 horizontal position of an item within its section, used to map
    /// focus spatially across sections without any geometry. `nil` for
    /// vertical lists (they have no meaningful horizontal extent).
    private func horizontalFraction(section: FocusSection, itemIndex: Int) -> Double? {
        switch section.kind {
        case .shelf:
            let count = section.itemIDs.count
            guard count > 1 else { return 0 }
            return Double(itemIndex) / Double(count - 1)
        case .grid(let columns):
            let cols = max(1, columns)
            guard cols > 1 else { return 0 }
            return Double(itemIndex % cols) / Double(cols - 1)
        case .vList:
            return nil
        }
    }

    /// Where focus lands when entering a section: remembered index first
    /// (clamped — content may have shrunk since), otherwise the
    /// nearest-relative slot mapped from the incoming horizontal fraction.
    private func entryIndex(
        into section: FocusSection, entry: VerticalEntry, fraction: Double?
    ) -> Int {
        let count = section.itemIDs.count
        if let remembered = memory[section.id] {
            return min(max(0, remembered), count - 1)
        }
        switch section.kind {
        case .shelf:
            guard let fraction, count > 1 else { return 0 }
            return Int((fraction.clamped01 * Double(count - 1)).rounded())
        case .grid(let columns):
            let cols = max(1, columns)
            var col = 0
            if let fraction, cols > 1 {
                col = Int((fraction.clamped01 * Double(cols - 1)).rounded())
            }
            switch entry {
            case .fromTop:
                return min(col, count - 1)
            case .fromBottom:
                // Land in the last row; clamp for ragged rows shorter than `col`.
                let lastRowStart = ((count - 1) / cols) * cols
                return min(lastRowStart + col, count - 1)
            }
        case .vList:
            return entry == .fromTop ? 0 : count - 1
        }
    }

    // MARK: - Lookup

    /// Resolves an item ID to (section, index). Prefers the currently-focused
    /// section so duplicate IDs across sections (same app in "Recent" and
    /// "All") resolve to the copy the user is actually on.
    private func location(of itemID: String) -> (sectionIndex: Int, itemIndex: Int)? {
        if let sid = focusedSectionID,
           let s = sections.firstIndex(where: { $0.id == sid }),
           let i = sections[s].itemIDs.firstIndex(of: itemID) {
            return (s, i)
        }
        for (s, section) in sections.enumerated() {
            if let i = section.itemIDs.firstIndex(of: itemID) { return (s, i) }
        }
        return nil
    }

    /// Next non-empty section walking `step` (±1) from `start`, or nil.
    private func nonEmptySectionIndex(from start: Int, step: Int) -> Int? {
        var i = start + step
        while i >= 0 && i < sections.count {
            if !sections[i].itemIDs.isEmpty { return i }
            i += step
        }
        return nil
    }

    /// Nearest non-empty section to an ordinal position, scanning outward.
    /// Ties prefer downward — after a refresh, content below reads as the
    /// natural continuation.
    private func nearestNonEmptySection(to anchor: Int) -> Int? {
        guard !sections.isEmpty else { return nil }
        let anchor = min(max(anchor, 0), sections.count - 1)
        for offset in 0..<sections.count {
            for candidate in [anchor + offset, anchor - offset]
            where candidate >= 0 && candidate < sections.count {
                if !sections[candidate].itemIDs.isEmpty { return candidate }
            }
        }
        return nil
    }

    // MARK: - Focus plumbing

    @discardableResult
    private func focusFirstIfPossible() -> Bool {
        guard let index = sections.firstIndex(where: { !$0.itemIDs.isEmpty }) else {
            clearFocus()
            return false
        }
        focusItem(at: 0, inSection: index)
        return true
    }

    /// Single funnel for every focus change: clamps the index, records section
    /// memory, updates observable state, and fires the change callback exactly
    /// once (and never for no-op re-focus, so hover events don't spam haptics).
    private func focusItem(at itemIndex: Int, inSection sectionIndex: Int) {
        let section = sections[sectionIndex]
        guard !section.itemIDs.isEmpty else {
            clearFocus()
            return
        }
        let clamped = min(max(0, itemIndex), section.itemIDs.count - 1)
        memory[section.id] = clamped
        if focusedSectionID != section.id { focusedSectionID = section.id }
        let new = section.itemIDs[clamped]
        let old = focusedItemID
        guard old != new else { return }
        focusedItemID = new
        onFocusChange?(old, new)
    }

    private func clearFocus() {
        if focusedSectionID != nil { focusedSectionID = nil }
        guard let old = focusedItemID else { return }
        focusedItemID = nil
        onFocusChange?(old, nil)
    }
}

private extension Double {
    /// Fractions are computed from trusted indices, but clamp anyway — a
    /// rounding artifact must never index out of bounds.
    var clamped01: Double { Swift.min(Swift.max(self, 0), 1) }
}
