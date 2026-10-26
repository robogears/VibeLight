import XCTest
@testable import VibeLight

/// The launcher's canvas scale (UX-ios-scale-shrinks-text-targets): iPad and
/// iPhone fit the Mac's 1440×860 canvas instead of 1920×1080 × 1.25, and the
/// Interface Size setting enlarges it without shrinking the virtual canvas
/// below the 1000×860 floor Home's fixed stack needs. Sizes are landscape
/// points from Apple's published screen sizes.
final class UIScaleTests: XCTestCase {

    private func scale(_ w: CGFloat, _ h: CGFloat, _ size: InterfaceSize,
                       _ platform: RootView.Platform) -> CGFloat {
        RootView.uiScale(for: CGSize(width: w, height: h), interfaceSize: size, platform: platform)
    }

    func testDefaultAndLargeScalesPerDevice() {
        let table: [(name: String, w: CGFloat, h: CGFloat, p: RootView.Platform,
                     def: CGFloat, large: CGFloat)] = [
            ("iPad 13-inch",   1376, 1032, .iOS,   0.956, 1.195),
            ("iPad Pro 11",    1210,  834, .iOS,   0.840, 0.969),
            ("iPad Air 11",    1180,  820, .iOS,   0.819, 0.952),
            ("iPad mini",      1133,  744, .iOS,   0.787, 0.865),
            ("iPhone 15",       852,  393, .iOS,   0.457, 0.457),
            ("Mac 1920×1080",  1920, 1080, .macOS, 1.000, 1.250),
            ("Mac 1440×900",   1440,  900, .macOS, 1.000, 1.047),
        ]
        for row in table {
            XCTAssertEqual(scale(row.w, row.h, .default, row.p), row.def, accuracy: 0.005,
                           "\(row.name) Default")
            XCTAssertEqual(scale(row.w, row.h, .large, row.p), row.large, accuracy: 0.005,
                           "\(row.name) Large")
        }
    }

    func testLargeNeverShrinksTheCanvasBelowTheLayoutFloor() {
        let sizes: [(CGFloat, CGFloat, RootView.Platform)] = [
            (1376, 1032, .iOS), (1210, 834, .iOS), (1180, 820, .iOS), (1133, 744, .iOS),
            (852, 393, .iOS), (667, 375, .iOS),
            (1920, 1080, .macOS), (1440, 900, .macOS), (2560, 1440, .macOS), (1200, 700, .macOS),
        ]
        for (w, h, p) in sizes {
            let def = scale(w, h, .default, p)
            let large = scale(w, h, .large, p)
            XCTAssertGreaterThanOrEqual(large, def - 0.0001, "\(w)×\(h) Large is never smaller")
            // Only when Default already had room: a screen whose Default canvas
            // is under the floor (iPhone, a tiny Mac window) must stay as is.
            if w / def >= RootView.canvasFloor.width, h / def >= RootView.canvasFloor.height {
                XCTAssertGreaterThanOrEqual(w / large, RootView.canvasFloor.width - 0.01, "\(w)×\(h) width")
                XCTAssertGreaterThanOrEqual(h / large, RootView.canvasFloor.height - 0.01, "\(w)×\(h) height")
            } else {
                XCTAssertEqual(large, def, accuracy: 0.0001, "\(w)×\(h) at the floor already")
            }
        }
    }

    func testDefaultOnIOSFitsTheMacDesignCanvas() {
        for (w, h) in [(CGFloat(1376), CGFloat(1032)), (1210, 834), (1133, 744), (852, 393)] {
            let fit = min(w / RootView.designMin.width, h / RootView.designMin.height)
            XCTAssertEqual(scale(w, h, .default, .iOS), fit, accuracy: 0.0001, "\(w)×\(h)")
        }
        XCTAssertEqual(RootView.designMin, CGSize(width: 1440, height: 860))
    }

    /// The setting is one row on Settings ▸ Themes, on every platform, and its
    /// focus ID is emitted by exactly one tab (the focus invariant: one view
    /// per emitted ID). Raw values persist in UserDefaults, so they're frozen.
    func testInterfaceSizeIsOneRowOnTheThemesTab() {
        XCTAssertEqual(AppState.SettingsTab.themes.rows, [.background, .interfaceSize])
        let tabsWithRow = AppState.SettingsTab.allCases.filter { $0.rows.contains(.interfaceSize) }
        XCTAssertEqual(tabsWithRow, [.themes])
        XCTAssertEqual(AppState.SettingsRow.interfaceSize.title, "Interface Size")
        XCTAssertEqual(AppState.SettingsRow.interfaceSize.focusID, "setting:interfaceSize")
        XCTAssertEqual(InterfaceSize.allCases.map(\.rawValue), ["default", "large"])
        XCTAssertEqual(InterfaceSize.allCases.map(\.label), ["Default", "Large"])
        XCTAssertEqual(InterfaceSize.large.factor, 1.25)
        XCTAssertEqual(InterfaceSize.default.factor, 1.0)
    }
}
