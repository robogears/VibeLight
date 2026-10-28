import SwiftUI
import XCTest
@testable import VibeLight

/// Settings ▸ Themes ▸ Theme (Default, Night Edition, Grid 72, Grid 72 Dark,
/// Kabuki Cut), which replaced the Background picker: its persistence and
/// migration, Default's background, the settings row, and the themes'
/// colour pairs (WCAG 2 contrast, computed from the palettes themselves).
final class AppThemeTests: XCTestCase {

    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "vibelight.tests.theme.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // MARK: - The choice

    /// Raw values persist in UserDefaults, so they're frozen; the case order
    /// is the Settings cycle order, Default first.
    func testThemesAreFrozenAndInCycleOrder() {
        XCTAssertEqual(AppTheme.allCases.map(\.rawValue),
                       ["default", "nightEdition", "grid72", "grid72Dark", "kabukiCut"])
        XCTAssertEqual(AppTheme.allCases.map(\.title),
                       ["Default", "Night Edition", "Grid 72", "Grid 72 Dark", "Kabuki Cut"])
        XCTAssertEqual(AppTheme.storageKey, "vibelight.appTheme")
        XCTAssertEqual(AppTheme.allCases.filter(\.isGrid), [.grid72, .grid72Dark])
    }

    func testNothingSavedReadsAsDefault() {
        XCTAssertEqual(AppTheme.stored(in: defaults), .default)
        XCTAssertEqual(AppTheme.migrated(in: defaults), .default)
    }

    func testASavedThemeIsRead() {
        defaults.set("kabukiCut", forKey: AppTheme.storageKey)
        XCTAssertEqual(AppTheme.stored(in: defaults), .kabukiCut)
    }

    /// A value a later build wrote (or a damaged one) never crashes or sticks.
    func testAnUnknownValueReadsAsDefault() {
        defaults.set("amberPhosphor", forKey: AppTheme.storageKey)
        XCTAssertEqual(AppTheme.stored(in: defaults), .default)
    }

    /// Whatever the old Background picker saved, the app boots on Default
    /// (whose background is Parallax Deep), and the dead key goes.
    func testAnOldBackgroundChoiceMigratesToDefault() {
        for old in ["swingingBulb", "inkPool", "parallaxDeep", "livingGlass"] {
            defaults.set(old, forKey: AppTheme.legacyBackgroundKey)
            XCTAssertEqual(AppTheme.migrated(in: defaults), .default, old)
            XCTAssertNil(defaults.object(forKey: AppTheme.legacyBackgroundKey), old)
        }
        XCTAssertEqual(AppTheme.legacyBackgroundKey, "vibelight.backgroundTheme")
    }

    func testMigrationKeepsAChosenTheme() {
        defaults.set("gaslight", forKey: AppTheme.legacyBackgroundKey)
        defaults.set("grid72Dark", forKey: AppTheme.storageKey)
        XCTAssertEqual(AppTheme.migrated(in: defaults), .grid72Dark)
        XCTAssertNil(defaults.object(forKey: AppTheme.legacyBackgroundKey))
    }

    /// The theme is global, like Interface Size: it isn't a stream setting, so
    /// a preset can't carry it or switch it.
    func testTheThemeIsNotAStreamSetting() throws {
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(StreamSettings()), encoding: .utf8))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("theme"), json)
        XCTAssertFalse(json.localizedCaseInsensitiveContains("background\""), json)
    }

    /// The test host never boots AppState, so every Theme token reads Default.
    func testTheTestHostSeesDefault() {
        XCTAssertEqual(ThemeStore.shared.theme, .default)
        XCTAssertEqual(Theme.current, .default)
    }

    // MARK: - Default's background

    func testDefaultAlwaysDrawsParallaxDeep() {
        XCTAssertEqual(AppBackground.backdrop(for: .default), .parallaxDeep)
        XCTAssertEqual(AppBackground.backdrop(for: .nightEdition), .nightPaper)
        XCTAssertEqual(AppBackground.backdrop(for: .grid72), .gridPaper)
        XCTAssertEqual(AppBackground.backdrop(for: .grid72Dark), .gridInk)
        XCTAssertEqual(AppBackground.backdrop(for: .kabukiCut), .kabuki)
    }

    /// Night Edition's window light crosses the page in 40 s and comes back,
    /// eased at both ends.
    func testNightBandCrossesAndReturns() {
        XCTAssertEqual(NightPaperBackground.bandProgress(at: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(NightPaperBackground.bandProgress(at: 20), 0.5, accuracy: 1e-9)
        XCTAssertEqual(NightPaperBackground.bandProgress(at: 40), 1, accuracy: 1e-9)
        XCTAssertEqual(NightPaperBackground.bandProgress(at: 60), 0.5, accuracy: 1e-9)
        XCTAssertEqual(NightPaperBackground.bandProgress(at: 80), 0, accuracy: 1e-9)
        XCTAssertLessThan(NightPaperBackground.bandProgress(at: 4), 0.1, "eased out of the edge")
    }

    // MARK: - Settings ▸ Themes

    /// The Background row became the Theme row: same place, first on the
    /// Themes tab, and on no other tab (one view per emitted focus id).
    func testTheThemeRowReplacedTheBackgroundRow() {
        let rows = AppState.SettingsRow.allCases.map(\.rawValue)
        XCTAssertFalse(rows.contains("background"))
        XCTAssertTrue(rows.contains("theme"))
        XCTAssertEqual(AppState.SettingsRow.theme.title, "Theme")
        XCTAssertEqual(AppState.SettingsRow.theme.focusID, "setting:theme")
        XCTAssertFalse(AppState.SettingsRow.theme.isAction)
        XCTAssertFalse(AppState.SettingsRow.theme.isReadonly)
        XCTAssertEqual(AppState.SettingsTab.themes.rows, [.theme, .interfaceSize])
        XCTAssertEqual(AppState.SettingsTab.allCases.filter { $0.rows.contains(.theme) }, [.themes])
    }

    /// The row reads the theme's name and cycles it with ◀ ▶, the setup
    /// wizard's look step cycles the same choice, and the store follows it.
    /// (AppState isn't booted in tests, so these are checked by source.)
    func testTheRowAndTheWizardCycleTheTheme() throws {
        let app = try source("VibeLight/App/AppState.swift")
        XCTAssertTrue(app.contains("case .theme: appTheme.title"))
        XCTAssertTrue(app.contains("case .theme: appTheme = Self.cycle(appTheme, forward: forward)"))
        XCTAssertTrue(app.contains("case .move(.left):  appTheme = Self.cycle(appTheme, forward: false)"))
        XCTAssertTrue(app.contains("case .move(.right): appTheme = Self.cycle(appTheme, forward: true)"))
        XCTAssertTrue(app.contains("ThemeStore.shared.theme = appTheme"))
        XCTAssertTrue(app.contains("appTheme = AppTheme.migrated(in: .standard)"))
        XCTAssertTrue(app.contains("UserDefaults.standard.set(appTheme.rawValue, forKey: AppTheme.storageKey)"))
        XCTAssertFalse(app.contains("backgroundTheme"))
        // The picker cards and the wizard's background show the theme, not a background.
        let settings = try source("VibeLight/UI/SettingsView.swift")
        XCTAssertTrue(settings.contains("ForEach(AppTheme.allCases, id: \\.self) { theme in"))
        let wizard = try source("VibeLight/UI/OnboardingFlow.swift")
        XCTAssertTrue(wizard.contains("AppBackground(theme: state.appTheme)"))
        let root = try source("VibeLight/UI/RootView.swift")
        XCTAssertTrue(root.contains("AppBackground(theme: state.appTheme)"))
    }

    // MARK: - Shapes, focus and small helpers

    func testCornersByTheme() {
        XCTAssertEqual(AppTheme.default.corner(14), 14)
        XCTAssertEqual(AppTheme.nightEdition.corner(14), 2)
        XCTAssertEqual(AppTheme.nightEdition.corner(1), 1)
        for square in [AppTheme.grid72, .grid72Dark, .kabukiCut] {
            XCTAssertEqual(square.corner(14), 0, square.rawValue)
        }
    }

    /// Default keeps its 1.11 tile lift; Night Edition and Grid 72 never scale.
    func testFocusScaleByTheme() {
        XCTAssertEqual(AppTheme.default.focusScale(1.11), 1.11)
        XCTAssertEqual(AppTheme.kabukiCut.focusScale(1.08), 1.08)
        for still in [AppTheme.nightEdition, .grid72, .grid72Dark] {
            XCTAssertEqual(still.focusScale(1.11), 1, still.rawValue)
        }
    }

    func testNightEditionFolioReadsTheVersion() {
        XCTAssertEqual(HintBarView.folio(version: "0.2.3"), "Vol. 2 · No. 3 · Night Edition")
        XCTAssertEqual(HintBarView.folio(version: "1.10.0"), "Vol. 10 · No. 0 · Night Edition")
        XCTAssertNil(HintBarView.folio(version: "1.0"))
        XCTAssertNil(HintBarView.folio(version: "dev"))
    }

    func testGridCountsHaveTwoDigits() {
        XCTAssertEqual(twoDigits(3), "03")
        XCTAssertEqual(twoDigits(0), "00")
        XCTAssertEqual(twoDigits(12), "12")
        XCTAssertEqual(twoDigits(120), "120")
    }

    // MARK: - Fonts

    /// Every face the themes name is in the app bundle under that PostScript
    /// name and registers, and each family's OFL licence ships beside it.
    func testBundledFacesRegister() throws {
        XCTAssertEqual(ThemeFonts.register(), ThemeFace.allCases.count)
        for face in ThemeFace.allCases {
            XCTAssertTrue(ThemeFonts.isAvailable(face), face.rawValue)
        }
        for licence in ["Fraunces-OFL", "Archivo-OFL", "IBMPlexSansCondensed-OFL",
                        "DelaGothicOne-OFL", "ZenKakuGothicNew-OFL"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: licence, withExtension: "txt"), licence)
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.contains("SIL OPEN FONT LICENSE"), licence)
        }
    }

    // MARK: - Contrast

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

    private let themed: [(String, ThemePalette)] = [
        ("Night Edition", .nightEdition), ("Grid 72", .grid72),
        ("Grid 72 Dark", .grid72Dark), ("Kabuki Cut", .kabukiCut),
    ]

    /// Words on the page and on cards: body text at 4.5:1 or better, the
    /// main ink far past it.
    func testTextReadsOnTheGroundAndTheCards() {
        for (name, p) in themed {
            XCTAssertGreaterThanOrEqual(ratio(p.textPrimary, on: p.background), 7, name)
            XCTAssertGreaterThanOrEqual(ratio(p.textPrimary, on: p.surface), 7, name)
            XCTAssertGreaterThanOrEqual(ratio(p.textSecondary, on: p.background), 4.5, name)
            XCTAssertGreaterThanOrEqual(ratio(p.textSecondary, on: p.surface), 4.5, name)
        }
    }

    /// Coloured WORDS take the text cuts, which read at 4.5:1 on the ground
    /// and on a card; the raw accent only has to mark (3:1, non-text).
    func testColouredWordsUseTheirTextCuts() {
        for (name, p) in themed {
            for (role, ink) in [("accent", p.accentText), ("live", p.liveText),
                                ("edited", p.editedText), ("warning", p.warning)] {
                XCTAssertGreaterThanOrEqual(ratio(ink, on: p.background), 4.5, "\(name) \(role)")
            }
            XCTAssertGreaterThanOrEqual(ratio(p.accentText, on: p.surface), 4.5, name)
            XCTAssertGreaterThanOrEqual(ratio(p.accent, on: p.background), 3, "\(name) frames")
        }
    }

    /// Grid 72 Dark (the ink inversion) keeps Grid 72's red, which is under
    /// 4.5:1 on the dark paper — so it marks and fills, and red words use the
    /// lighter cut.
    func testTheInkInversionKeepsTheRedForMarks() {
        let dark = ThemePalette.grid72Dark
        XCTAssertTrue(same(dark.accent, ThemePalette.grid72.accent))
        XCTAssertLessThan(ratio(dark.accent, on: dark.background), 4.5)
        XCTAssertGreaterThanOrEqual(ratio(dark.accent, on: dark.background), 3)
        XCTAssertGreaterThanOrEqual(ratio(dark.accentText, on: dark.background), 4.5)
        // Paper and ink swap.
        XCTAssertTrue(same(dark.background, ThemePalette.grid72.textPrimary))
        XCTAssertTrue(same(dark.textPrimary, ThemePalette.grid72.background))
        XCTAssertFalse(dark.isLight)
        XCTAssertTrue(ThemePalette.grid72.isLight)
    }

    /// Ink on a solid accent fill (a loaded preset, a focused button) reads
    /// at 4.5:1, small text included. Night Edition's vermilion is cut a
    /// shade deeper than the spec's for this.
    func testInkOnTheAccentFill() {
        for (name, p) in themed {
            XCTAssertGreaterThanOrEqual(ratio(p.onAccent, on: p.accent), 4.5, name)
        }
    }

    /// The LIVE marks carry a word: Grid 72's white on its deeper green, the
    /// inversion's ink on the bright one, Kabuki's black on lime; and
    /// Kabuki's white captions and hero on crimson.
    func testLiveMarksAndSlabsRead() {
        XCTAssertGreaterThanOrEqual(ratio(.white, on: ThemePalette.grid72.liveText), 4.5)
        XCTAssertGreaterThanOrEqual(ratio(Color(hex: 0x111111), on: ThemePalette.grid72Dark.live), 4.5)
        XCTAssertGreaterThanOrEqual(ratio(.black, on: ThemePalette.kabukiCut.live), 4.5)
        XCTAssertGreaterThanOrEqual(ratio(.white, on: ThemePalette.kabukiCut.accent), 4.5)
    }

    /// Default is today's look, value for value.
    func testDefaultPaletteIsUnchanged() {
        let p = ThemePalette.default
        XCTAssertTrue(same(p.background, Color(red: 0.05, green: 0.06, blue: 0.09)))
        XCTAssertTrue(same(p.surface, Color(red: 0.10, green: 0.11, blue: 0.16)))
        XCTAssertTrue(same(p.accent, Color(red: 0.35, green: 0.62, blue: 1.0)))
        XCTAssertTrue(same(p.accentText, p.accent))
        XCTAssertTrue(same(p.onAccent, Color(red: 0.04, green: 0.08, blue: 0.16)))
        XCTAssertTrue(same(p.textPrimary, .white))
        XCTAssertTrue(same(p.textSecondary, .white.opacity(0.6)))
        XCTAssertTrue(same(p.ink, .white))
        XCTAssertTrue(same(p.tintInk, .white))
        XCTAssertTrue(same(p.live, .green))
        XCTAssertTrue(same(p.edited, .orange))
        XCTAssertTrue(same(p.warning, .orange))
        XCTAssertTrue(same(p.veil, .black))
        XCTAssertFalse(p.isLight)
        XCTAssertTrue(same(AppTheme.default.palette.accent, p.accent))
    }

    // MARK: - Helpers

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
