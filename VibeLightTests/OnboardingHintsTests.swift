import XCTest
@testable import VibeLight

/// Visual batch 3I. The setup wizard's hints show the connected controller's
/// own buttons, or plain tappable pills on touch, by reusing the main hint
/// bar's chip and its touch rule (UX-onboarding-hints-generic-glyphs).
final class OnboardingHintsTests: XCTestCase {

    // MARK: Touch presentation rule

    func testTouchWithNoControllerShowsPills() {
        XCTAssertTrue(HintBarView.touchPresentation(touchPlatform: true, controllerConnected: false,
                                                    inputMode: .directed))
        XCTAssertTrue(HintBarView.touchPresentation(touchPlatform: true, controllerConnected: false,
                                                    inputMode: .pointer))
    }

    func testTouchingWithAControllerAttachedShowsPills() {
        XCTAssertTrue(HintBarView.touchPresentation(touchPlatform: true, controllerConnected: true,
                                                    inputMode: .pointer))
    }

    func testAControllerThatIsDrivingKeepsItsGlyphs() {
        XCTAssertFalse(HintBarView.touchPresentation(touchPlatform: true, controllerConnected: true,
                                                     inputMode: .directed))
    }

    /// The Mac always has a keyboard, so it always shows glyphs.
    func testTheMacAlwaysShowsGlyphs() {
        for connected in [false, true] {
            for mode in [InputMode.directed, .pointer] {
                XCTAssertFalse(HintBarView.touchPresentation(touchPlatform: false,
                                                             controllerConnected: connected,
                                                             inputMode: mode))
            }
        }
    }

    // MARK: Wiring (checked by source only — the views can't run in a test)

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func body(of start: String, until end: String, in text: String) throws -> Substring {
        let s = try XCTUnwrap(text.range(of: start), "missing \(start)")
        let e = try XCTUnwrap(text.range(of: end, range: s.upperBound..<text.endIndex))
        return text[s.upperBound..<e.lowerBound]
    }

    /// The wizard's bar draws the main bar's chips — Back is the B/Esc button,
    /// Continue is A/Return — and decides touch with the same rule, never a
    /// hard-coded arrow symbol.
    func testWizardHintsReuseTheMainHintChip() throws {
        let flow = try source("VibeLight/UI/OnboardingFlow.swift")
        let hints = try body(of: "private struct OnboardingHints: View {", until: "\n}\n", in: flow)
        XCTAssertTrue(hints.contains("let touch = HintBarView.touchPresentation(state)"), String(hints))
        XCTAssertTrue(hints.contains("HintChip(event: .back, label: \"Back\", touch: touch)"))
        XCTAssertTrue(hints.contains(
            "HintChip(event: .select, label: step == .finish ? \"Jump in\" : \"Continue\", touch: touch)"))
        XCTAssertTrue(hints.contains("if !touch && (step == .theme || step == .quality) {"),
                      "the d-pad hint has nothing to tap on touch")
        XCTAssertFalse(hints.contains("Image(systemName:"), "no generic arrows in place of the real buttons")
        XCTAssertFalse(hints.contains("Button("), "taps must route through HintChip → state.route")
    }

    /// The main bar reads the same rule, so the two bars can't drift.
    func testMainHintBarUsesTheSharedTouchRule() throws {
        let bar = try source("VibeLight/UI/HintBarView.swift")
        XCTAssertTrue(bar.contains("private var touchButtons: Bool { Self.touchPresentation(state) }"))
        XCTAssertEqual(bar.components(separatedBy: "connectedControllers").count - 1, 1,
                       "the touch rule must live in one place")
    }
}
