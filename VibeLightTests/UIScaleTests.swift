import XCTest
import AppKit
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
        XCTAssertEqual(AppState.SettingsTab.themes.rows, [.theme, .interfaceSize])
        let tabsWithRow = AppState.SettingsTab.allCases.filter { $0.rows.contains(.interfaceSize) }
        XCTAssertEqual(tabsWithRow, [.themes])
        XCTAssertEqual(AppState.SettingsRow.interfaceSize.title, "Interface Size")
        XCTAssertEqual(AppState.SettingsRow.interfaceSize.focusID, "setting:interfaceSize")
        XCTAssertEqual(InterfaceSize.allCases.map(\.rawValue), ["default", "large"])
        XCTAssertEqual(InterfaceSize.allCases.map(\.label), ["Default", "Large"])
        XCTAssertEqual(InterfaceSize.large.factor, 1.25)
        XCTAssertEqual(InterfaceSize.default.factor, 1.0)
    }

    /// Polish 1A: the 13 pt labels and 44 pt targets are for the scaled-down
    /// iPad canvas. A Mac draws the canvas at 1.0× and keeps its original
    /// sizes (10–12 pt labels, 34–38 pt arrows), never touch-sized targets.
    func testMacKeepsItsSizesAndIOSGetsTouchSizes() {
        for mac: CGFloat in [10, 11, 12] {
            XCTAssertEqual(Theme.labelSize(mac, on: .macOS), mac, "Mac \(mac) pt label")
            XCTAssertEqual(Theme.labelSize(mac, on: .iOS), 13, "iOS \(mac) pt label")
        }
        XCTAssertEqual(Theme.labelSize(15, on: .iOS), 15, "iOS never shrinks a bigger label")
        XCTAssertEqual(Theme.perPlatform(iOS: CGFloat(44), macOS: 34, on: .macOS), 34)
        XCTAssertEqual(Theme.perPlatform(iOS: CGFloat(44), macOS: 34, on: .iOS), 44)
        let macTrash: CGFloat? = Theme.perPlatform(iOS: 44, macOS: nil, on: .macOS)
        XCTAssertNil(macTrash, "the Mac trash glyph keeps its own size")
        // This test target is the macOS app, so the defaults take the Mac branch.
        XCTAssertEqual(Theme.labelSize(10), 10)
        XCTAssertEqual(Theme.perPlatform(iOS: CGFloat(44), macOS: 34), 34)
    }

    /// Polish 1A: a preset chip on an iPad's 1440-wide canvas has about 134 pt
    /// for its summary (about 107 pt on the active chip, beside the check mark),
    /// and about 86 / 59 pt at Large on a 13-inch iPad. "1080p · 144 fps ·
    /// 87 Mbps" is about 162 pt at 13 pt, so the chip needs shorter forms to
    /// fall back to instead of cutting the line off with "…".
    func testPresetSummaryHasShorterFormsForNarrowChips() {
        let owner = StreamPreset(id: "p", name: "Mine",
                                 settings: StreamSettings(width: 1920, height: 1080, fps: 144,
                                                          bitrateKbps: 87_500))
        XCTAssertEqual(owner.summary, "1080p · 144 fps · 87 Mbps")
        XCTAssertEqual(owner.shortSummary, "1080p · 144 fps")
        XCTAssertEqual(owner.resolutionLabel, "1080p")
        let fourK = StreamPreset(id: "q", name: "TV",
                                 settings: StreamSettings(width: 3840, height: 2160, fps: 60,
                                                          bitrateKbps: 150_000))
        XCTAssertEqual(fourK.summary, "4K · 60 fps · 150 Mbps")
        XCTAssertEqual(fourK.shortSummary, "4K · 60 fps")
        XCTAssertEqual(fourK.resolutionLabel, "4K")
        let odd = StreamPreset(id: "r", name: "Odd", settings: StreamSettings(width: 1600, height: 900))
        XCTAssertEqual(odd.resolutionLabel, "900p")

        // Measured in the system font the chips use: the short form fits the
        // active chip at Default on every iPad, the resolution fits at Large.
        let font = NSFont.systemFont(ofSize: Theme.labelSize(11, on: .iOS), weight: .medium)
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        let widest = StreamPreset(id: "w", name: "W",
                                  settings: StreamSettings(width: 2560, height: 1440, fps: 120,
                                                           bitrateKbps: 150_000))
        XCTAssertGreaterThan(width(widest.summary), 134, "the full summary really is too wide")
        XCTAssertLessThan(width(widest.shortSummary), 107)
        XCTAssertLessThan(width(widest.resolutionLabel), 59)
    }
}
