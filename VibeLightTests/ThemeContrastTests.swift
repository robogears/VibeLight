import SwiftUI
import XCTest
@testable import VibeLight

/// Labels on the accent fill (UX-white-on-accent-contrast): the contrast
/// numbers are computed from the Theme constants themselves (WCAG 2 relative
/// luminance, sRGB), so a later colour tweak that breaks them fails here.
final class ThemeContrastTests: XCTestCase {

    // MARK: - WCAG arithmetic

    private func luminance(_ color: Color) -> Double {
        let c = color.resolve(in: EnvironmentValues())
        func lin(_ v: Float) -> Double {
            let v = Double(v)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.red) + 0.7152 * lin(c.green) + 0.0722 * lin(c.blue)
    }

    private func ratio(_ a: Color, on b: Color) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func same(_ a: Color, _ b: Color) -> Bool {
        a.resolve(in: EnvironmentValues()) == b.resolve(in: EnvironmentValues())
    }

    // MARK: - The token

    /// The reason for the fix, measured: white on the accent is ~2.7:1, under
    /// Apple's 3:1 minimum even for bold text.
    func testWhiteOnAccentIsBelowTheBoldMinimum() {
        XCTAssertEqual(ratio(.white, on: Theme.accent), 2.70, accuracy: 0.05)
        XCTAssertLessThan(ratio(.white, on: Theme.accent), 3.0)
    }

    /// Navy ink on the accent clears the 4.5:1 body-text minimum (~6.8:1),
    /// so even the 11–13 pt secondary lines on a lit chip are readable.
    func testOnAccentMeetsBodyTextContrastOnAccent() {
        XCTAssertGreaterThanOrEqual(ratio(Theme.onAccent, on: Theme.accent), 4.5)
        XCTAssertEqual(ratio(Theme.onAccent, on: Theme.accent), 6.77, accuracy: 0.05)
    }

    /// The blue itself is the approved design language — only the ink on it changed.
    func testAccentIsUnchanged() {
        XCTAssertTrue(same(Theme.accent, Color(red: 0.35, green: 0.62, blue: 1.0)))
    }

    // MARK: - Which fill gets navy ink

    /// Navy only on a full-strength accent fill; a tinted fill (or the red of
    /// a destructive button) keeps white, where navy would vanish.
    func testLabelInkIsNavyOnlyOnSolidAccent() {
        XCTAssertTrue(same(Theme.labelInk(onSolidAccent: true), Theme.onAccent))
        XCTAssertGreaterThanOrEqual(ratio(Theme.labelInk(onSolidAccent: true), on: Theme.accent), 4.5)
        XCTAssertTrue(same(Theme.labelInk(onSolidAccent: false), .white))
    }

    // MARK: - Increase Contrast

    func testHairlineLiftsFaintBordersUnderIncreaseContrast() {
        let increased = Theme.hairline(0.08, .increased).resolve(in: EnvironmentValues())
        XCTAssertEqual(Double(increased.opacity), 0.35, accuracy: 0.001)
        let standard = Theme.hairline(0.08, .standard).resolve(in: EnvironmentValues())
        XCTAssertEqual(Double(standard.opacity), 0.08, accuracy: 0.001)
        // Never dims a border that was already strong.
        let strong = Theme.hairline(0.5, .increased).resolve(in: EnvironmentValues())
        XCTAssertEqual(Double(strong.opacity), 0.5, accuracy: 0.001)
    }

    // MARK: - Source pins (checked by source only)

    /// A focused card button takes navy on the blue and keeps white on the red.
    func testOverlayButtonInkFollowsTheFill() throws {
        let body = try source(of: "struct OverlayButton: View {", in: "VibeLight/UI/OverlayViews.swift")
        XCTAssertTrue(body.contains(".foregroundStyle(isFocused ? Theme.labelInk(onSolidAccent: !destructive)"))
        XCTAssertFalse(body.contains(".foregroundStyle(isFocused ? .white"))
        XCTAssertTrue(body.contains("Theme.hairline(isFocused ? 0.35 : (hoverActive ? 0.22 : 0.08), contrast)"))
    }

    /// Only the ACTIVE preset chip is a solid fill; a merely focused chip is a
    /// 0.35 tint, so its ink must key off `isActive`, never `lit`.
    func testPresetChipInkKeysOffTheSolidFill() throws {
        let body = try source(of: "private struct PresetSlotChip: View {", in: "VibeLight/UI/HomeView.swift")
        XCTAssertTrue(body.contains("private var ink: Color { Theme.labelInk(onSolidAccent: isActive) }"))
        XCTAssertFalse(body.contains("lit ? .white"))
        XCTAssertTrue(body.contains("return Theme.hairline(isFilled ? 0.08 : 0.14, contrast)"))
    }

    /// The Settings ▸ Presets slot follows the same rule: the active slot is the
    /// solid accent (navy number and dot), a focused one is a 0.4 tint (white).
    func testSettingsPresetSlotInkKeysOffTheSolidFill() throws {
        let body = try source(of: "private struct SettingsPresetSlot: View {", in: "VibeLight/UI/SettingsView.swift")
        XCTAssertTrue(body.contains("private var ink: Color { Theme.labelInk(onSolidAccent: isActive) }"))
        XCTAssertTrue(body.contains(".foregroundStyle(lit || isFilled ? ink : Theme.textSecondary)"))
        XCTAssertTrue(body.contains(".fill(isFilled ? (lit ? ink : Theme.accent) : .clear)"))
        XCTAssertFalse(body.contains("lit || isFilled ? .white"))
        XCTAssertFalse(body.contains("lit ? Color.white"))
    }

    /// Every other full-strength accent fill carries navy ink.
    func testSolidAccentFillsUseNavyInk() throws {
        let row = try source(of: "private struct HostRow: View {", in: "VibeLight/UI/HostMenuCard.swift")
        XCTAssertFalse(row.contains("isFocused ? .white"))
        XCTAssertTrue(row.contains(".foregroundStyle(isFocused ? Theme.onAccent : Theme.textPrimary)"))
        let tab = try source(of: "private struct TabChip: View {", in: "VibeLight/UI/SettingsView.swift")
        XCTAssertTrue(tab.contains(".foregroundStyle(selected ? Theme.onAccent"))
        // The corner "Add Computer" pill became the empty shelf's card button
        // (UX-empty-home-no-invitation); its focused fill takes navy ink too.
        let add = try source(of: "private struct EmptyShelfPanel: View {", in: "VibeLight/UI/HomeView.swift")
        XCTAssertTrue(add.contains("OverlayButton(id: \"header:addhost\", title: \"Add Computer\", symbol: \"plus.circle.fill\")"))
        let card = try source(of: "struct OverlayButton: View {", in: "VibeLight/UI/OverlayViews.swift")
        XCTAssertTrue(card.contains("Theme.labelInk(onSolidAccent: !destructive)"))
        let wizard = try source(of: "private struct OnboardingButton: View {", in: "VibeLight/UI/OnboardingFlow.swift")
        XCTAssertTrue(wizard.contains(".foregroundStyle(prominent ? Theme.onAccent : Theme.textPrimary)"))
    }

    // MARK: - The last destructive button is always red (UX-destructive-styling-inconsistent)

    /// The buttons that actually delete turn red when focused, like Restart PC
    /// and the preset menu's "Clear" that leads to them.
    func testFinalDestructiveButtonsAreMarkedDestructive() throws {
        let clear = try source(of: "private struct ConfirmClearPresetCard: View {",
                               in: "VibeLight/UI/OverlayViews.swift")
        XCTAssertTrue(clear.contains("OverlayButton(id: \"clearpreset:yes\", title: \"Clear Preset\", symbol: \"trash.fill\", destructive: true)"))
        let forget = try source(of: "private struct ConfirmRemoveHostCard: View {",
                                in: "VibeLight/UI/OverlayViews.swift")
        XCTAssertTrue(forget.contains("OverlayButton(id: \"removehost:yes\", title: \"Forget Computer\", symbol: \"trash.fill\",\n"
                                      + "                              destructive: true)"))
    }

    // MARK: - No hover zoom (UX-hover-zoom-settings-tabs)

    /// Hover only brightens: a Settings tab never scales, and a card button
    /// scales for focus alone (a hover on the Mac focuses it, so it still grows).
    func testHoverBrightensButNeverScales() throws {
        let tab = try source(of: "private struct TabChip: View {", in: "VibeLight/UI/SettingsView.swift")
        XCTAssertFalse(tab.contains(".scaleEffect"))
        XCTAssertTrue(tab.contains("Color.white.opacity(hovering && state.inputMode == .pointer ? 0.14 : 0.06)"))
        let button = try source(of: "struct OverlayButton: View {", in: "VibeLight/UI/OverlayViews.swift")
        XCTAssertTrue(button.contains(".scaleEffect(isFocused ? 1.04 : 1.0)"))
        XCTAssertEqual(button.components(separatedBy: ".scaleEffect").count, 2)   // exactly one
    }

    /// The body of one view struct, from its declaration to the closing brace
    /// at column 0 — so a pin can't pass on text elsewhere in the file.
    private func source(of declaration: String, in path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: declaration))
        let end = try XCTUnwrap(text.range(of: "\n}\n", range: start.upperBound..<text.endIndex))
        return String(text[start.lowerBound..<end.upperBound])
    }
}
