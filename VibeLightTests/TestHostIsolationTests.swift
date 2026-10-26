import AppKit
import XCTest
@testable import VibeLight

/// The Mac unit tests run inside a copy of the app (project.yml TEST_HOST) that
/// has the real app's bundle id, so whatever the app does at launch it does to
/// the owner's REAL preferences, client identity, box-art cache and PCs.
/// (audit QUA-macos-tests-boot-real-app)
final class TestHostIsolationTests: XCTestCase {

    func testOnlyXCTestsOwnVariableMarksATestHost() {
        XCTAssertTrue(AppDelegate.isHostingUnitTests(
            environment: ["XCTestConfigurationFilePath": "/private/tmp/run.xctestconfiguration"]))
        XCTAssertFalse(AppDelegate.isHostingUnitTests(environment: [:]),
                       "a normal launch must boot the launcher")
        XCTAssertFalse(AppDelegate.isHostingUnitTests(environment: ["PATH": "/usr/bin:/bin"]))
    }

    /// The wiring: under the real test run the launcher never came up. Its
    /// full-screen window is the visible half of booting AppState.
    @MainActor
    func testTheTestHostDidNotOpenTheLauncher() {
        XCTAssertFalse(NSApp.windows.contains { $0 is BigPictureWindow },
                       "the test host booted the launcher against the owner's real data")
        XCTAssertNotEqual(NSApp.activationPolicy(), .regular,
                          "the test host must stay out of the Dock and never take focus")
    }
}
