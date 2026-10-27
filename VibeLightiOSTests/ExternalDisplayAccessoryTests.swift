#if os(iOS)
import XCTest
import UIKit
@testable import VibeLight

@MainActor
final class ExternalDisplayAccessoryTests: XCTestCase {
    func testLoadingMainInterfaceRegistersExternalDisplay() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Scene accessories require iOS 27") }
        let controller = ExternalDisplayAccessoryController()
        defer { controller.unregisterExternalDisplay() }

        controller.loadViewIfNeeded()

        let registration = try XCTUnwrap(controller.registration)
        XCTAssertTrue(registration.isEnabled)
        XCTAssertFalse(controller.view.isUserInteractionEnabled)
    }

    func testRepeatedViewLoadsKeepTheSameRegistration() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Scene accessories require iOS 27") }
        let controller = ExternalDisplayAccessoryController()
        defer { controller.unregisterExternalDisplay() }
        controller.loadViewIfNeeded()
        let registration = try XCTUnwrap(controller.registration)

        controller.loadViewIfNeeded()

        XCTAssertTrue(controller.registration === registration)
    }

    func testDismantlingMainInterfaceReleasesRegistration() throws {
        guard #available(iOS 27.0, *) else { throw XCTSkip("Scene accessories require iOS 27") }
        let controller = ExternalDisplayAccessoryController()
        controller.loadViewIfNeeded()
        XCTAssertNotNil(controller.registration)

        ExternalDisplayAccessoryView.dismantleUIViewController(controller, coordinator: ())

        XCTAssertNil(controller.registration)
        controller.unregisterExternalDisplay() // a second teardown is harmless
        XCTAssertNil(controller.registration)
    }
}
#endif
