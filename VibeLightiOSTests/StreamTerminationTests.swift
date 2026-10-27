#if os(iOS)
import XCTest
@testable import VibeLight

final class StreamTerminationTests: XCTestCase {
    private let app = StreamApp(id: 1, rawName: "Game", uuid: nil, idx: nil,
                               isHDRSupported: false, isHidden: false)

    func testMissingVideoDoesNotLookLikeANormalReturnToTheMenu() {
        for error in [-100, -101, -102, -103, -104, 1234] {
            let phase = InProcessStreamEngine.terminationPhase(
                error: error, remoteQuitRequested: false, app: app)
            guard case .failed(let message) = phase else {
                XCTFail("Error \(error) was hidden as an ordinary game exit")
                continue
            }
            XCTAssertTrue(message.contains(String(error)))
        }
    }

    func testNormalHostExitKeepsTheExistingEndScreen() {
        XCTAssertEqual(InProcessStreamEngine.terminationPhase(
            error: 0, remoteQuitRequested: false, app: app), .ending(app))
    }

    func testExplicitFullQuitDoesNotShowATransportError() {
        XCTAssertEqual(InProcessStreamEngine.terminationPhase(
            error: -102, remoteQuitRequested: true, app: app), .ending(app))
    }

    func testMissingAppStillPreservesUnexpectedFailure() {
        guard case .failed = InProcessStreamEngine.terminationPhase(
            error: -101, remoteQuitRequested: false, app: nil) else {
            return XCTFail("A missing app must not erase the failure reason")
        }
        XCTAssertEqual(InProcessStreamEngine.terminationPhase(
            error: 0, remoteQuitRequested: false, app: nil), .idle)
    }
}
#endif
