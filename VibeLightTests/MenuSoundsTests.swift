import XCTest
@testable import VibeLight

/// Settings ▸ Audio ▸ Menu Sounds (UX-menu-sounds-no-toggle): one On/Off row,
/// last on the Audio tab, on by default, stored on its own key (not inside
/// `StreamSettings`, so presets can't undo it), and an Off switch that stops
/// every effect before anything is scheduled.
@MainActor
final class MenuSoundsTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MenuSoundsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// One row, last on the Audio tab, emitted by no other tab (the focus
    /// invariant: one view per emitted ID). The raw value is the stored
    /// focus ID, so it's frozen.
    func testMenuSoundsIsTheLastRowOnTheAudioTabOnly() {
        XCTAssertEqual(AppState.SettingsTab.audio.rows,
                       [.audio, .muteHostSpeakers, .muteOnFocusLoss, .menuSounds])
        let tabsWithRow = AppState.SettingsTab.allCases.filter { $0.rows.contains(.menuSounds) }
        XCTAssertEqual(tabsWithRow, [.audio])
        XCTAssertEqual(AppState.SettingsRow.menuSounds.title, "Menu Sounds")
        XCTAssertEqual(AppState.SettingsRow.menuSounds.focusID, "setting:menuSounds")
        XCTAssertFalse(AppState.SettingsRow.menuSounds.isAction)
        XCTAssertFalse(AppState.SettingsRow.menuSounds.isReadonly)
    }

    /// Nothing saved (every existing install) reads as On; a saved Off stays
    /// Off; a value that isn't a Bool falls back to On rather than silencing.
    func testStoredPreferenceDefaultsToOn() {
        XCTAssertTrue(AppState.storedMenuSounds(in: defaults))
        defaults.set(false, forKey: AppState.menuSoundsKey)
        XCTAssertFalse(AppState.storedMenuSounds(in: defaults))
        defaults.set(true, forKey: AppState.menuSoundsKey)
        XCTAssertTrue(AppState.storedMenuSounds(in: defaults))
        defaults.set("garbage", forKey: AppState.menuSoundsKey)
        XCTAssertTrue(AppState.storedMenuSounds(in: defaults))
        XCTAssertEqual(AppState.menuSoundsKey, "vibelight.menuSounds")
    }

    /// Off means no effect gets past the top of `play` — ticks, chimes, the
    /// restart cue, the launch swell and the quack recording alike. (Only the
    /// Off path is exercised: the On path would make real sound during tests.)
    func testPlayDoesNothingWhenMenuSoundsAreOff() {
        let sfx = MenuSFX()
        XCTAssertTrue(sfx.isEnabled, "menu sounds are on by default")
        sfx.isEnabled = false
        for effect: MenuSFX.Effect in [.move, .select, .back, .restart, .launch, .quack] {
            sfx.play(effect)
        }
        XCTAssertEqual(sfx.playsPastGate, 0)
    }
}
