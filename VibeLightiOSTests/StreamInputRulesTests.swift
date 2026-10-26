#if os(iOS)
import XCTest
import SwiftUI
@testable import VibeLight

/// The iPad stream's input rules (audit fix group G6A): which screen edges hold
/// back iOS's own swipes, and which route each typed key takes to the PC.
@MainActor
final class StreamInputRulesTests: XCTestCase {

    // MARK: - Edge swipes (UX-stream-edge-gestures-not-deferred)

    /// A live stream defers every edge, so one stray drag from the bottom can't
    /// go Home and (by default) close the game on the PC.
    func testEveryEdgeIsDeferredWhileStreaming() {
        XCTAssertEqual(RootView.deferredSystemEdges(streaming: true), .all)
    }

    /// The launcher keeps the normal one-swipe Home and Control Center.
    func testNoEdgeIsDeferredInTheLauncher() {
        XCTAssertEqual(RootView.deferredSystemEdges(streaming: false), [])
    }
}
#endif
