#if os(iOS)
import XCTest
import AVFoundation
@testable import VibeLight

/// Menu sounds must not stop the person's music, and must obey the Silent
/// switch (LIF-menu-sfx-audio-category-leak): the launcher's audio session is
/// `.ambient` from startup and again after every stream. Only the category is
/// read and set — nothing is activated or played.
@MainActor
final class LauncherAudioSessionTests: XCTestCase {

    private var savedCategory: AVAudioSession.Category = .ambient

    override func setUp() {
        super.setUp()
        savedCategory = AVAudioSession.sharedInstance().category
    }

    override func tearDown() {
        try? AVAudioSession.sharedInstance().setCategory(savedCategory)
        super.tearDown()
    }

    /// Creating the menu-sound player selects `.ambient` even when something
    /// left the session in a non-mixing category (iOS's own default is
    /// `.soloAmbient`, which stops other apps' music).
    func testMenuSoundsSelectTheMixingAmbientCategory() throws {
        try AVAudioSession.sharedInstance().setCategory(.soloAmbient)
        _ = MenuSFX()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .ambient)
    }

    /// The stream's `.playback` (ignores Silent, stops other audio) is handed
    /// back as `.ambient` when the stream releases the session.
    func testLauncherCategoryReplacesTheStreamsPlaybackCategory() throws {
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        MenuSFX.useLauncherAudioSession()
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .ambient)
        XCTAssertEqual(AVAudioSession.sharedInstance().mode, .default,
                       "the stream's movie-playback mode doesn't belong to menu sounds")
    }
}
#endif
