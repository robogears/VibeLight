import XCTest

/// The Mac runner cannot request an iPad TV scene. Pin the registration at the
/// main-interface boundary; iOS tests exercise the controller's real lifetime.
final class ExternalDisplayWiringTests: XCTestCase {
    func testTVDoesNotReplacePresetQualityBeforeStartingTheStream() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "VibeLight/App/iOS/InProcessStreamEngine.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of:
            "func launch(app: StreamApp, on host: StreamHost, settings: StreamSettings) async {"))
        let end = try XCTUnwrap(source.range(of: "// Remote-input AES material:",
                                             range: start.upperBound..<source.endIndex))
        let preparation = source[start.upperBound..<end.lowerBound]
        XCTAssertTrue(preparation.contains("let effective = Self.settingsForStream(settings)"))
        for field in ["width", "height", "fps", "bitrateKbps"] {
            XCTAssertFalse(preparation.contains("effective.\(field) ="),
                           "TV presentation must not replace the preset's \(field)")
        }
        XCTAssertFalse(preparation.contains("ExternalDisplay.shared.pixelSize"))
    }

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
