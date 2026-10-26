import XCTest
@testable import VibeLight

/// The menu-sound engine stops driving the audio output once nothing has
/// played for a while, and the next sound starts it again
/// (LIF-menu-sfx-engine-never-paused). The output is muted for the test, so
/// starting the engine makes no sound.
@MainActor
final class MenuSoundsIdleTests: XCTestCase {

    func testEnginePausesAfterTheIdleDelayAndRestartsOnTheNextSound() async throws {
        let sfx = MenuSFX()
        sfx.muteForTests()
        sfx.idlePauseDelay = .milliseconds(50)

        sfx.play(.move)
        guard sfx.isEngineRunning else {
            throw XCTSkip("This machine has no audio output for the engine to start on.")
        }

        // .move lasts 25 ms; allow generous slack for a loaded machine.
        for _ in 0..<60 where sfx.isEngineRunning {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(sfx.isEngineRunning, "the engine must stop holding the output once idle")

        sfx.play(.move)
        XCTAssertTrue(sfx.isEngineRunning, "the next sound restarts the paused engine")
        sfx.isEnabled = false
    }
}
