import XCTest

/// The Mac runner cannot request an iPad TV scene. Pin the registration at the
/// main-interface boundary; iOS tests exercise the controller's real lifetime.
final class ExternalDisplayWiringTests: XCTestCase {
    func testMainInterfaceOffersExternalContentOnIOS27() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "VibeLight/App/iOS/VibeLightApp.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "var body: some Scene {"))
        let end = try XCTUnwrap(source.range(of: ".onChange(of: scenePhase)",
                                             range: start.upperBound..<source.endIndex))
        let mainInterface = source[start.upperBound..<end.lowerBound]
        XCTAssertTrue(mainInterface.contains("""
                        .background {
                            if #available(iOS 27.0, *) {
                                ExternalDisplayAccessoryView()
                                    .frame(width: 0, height: 0)
                                    .allowsHitTesting(false)
                            }
                        }
        """), "iPadOS 27 never delivers the TV scene unless the main interface registers an accessory")
    }
}
