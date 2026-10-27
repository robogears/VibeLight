#if os(iOS)
import XCTest
import UIKit
@testable import VibeLight

final class ExternalDisplayPixelSizeTests: XCTestCase {
    func testCurrentOutputPixelsWinOverNativePanelSize() {
        // A 4K panel can currently be driven at 1080p. Neither the panel's
        // maximum nor the launcher's supersampling scale is the output mode.
        XCTAssertEqual(ExternalDisplay.streamPixelSize(
            currentMode: CGSize(width: 1920, height: 1080),
            nativeBounds: CGSize(width: 3840, height: 2160),
            sceneBounds: CGSize(width: 1920, height: 1080)),
            CGSize(width: 1920, height: 1080))
    }

    func testScenePointSizeDoesNotDownscaleThePixelMode() {
        XCTAssertEqual(ExternalDisplay.streamPixelSize(
            currentMode: CGSize(width: 3840, height: 2160),
            nativeBounds: CGSize(width: 3840, height: 2160),
            sceneBounds: CGSize(width: 1920, height: 1080)),
            CGSize(width: 3840, height: 2160))
    }

    func testRotatedOutputMatchesTheSceneOrientation() {
        XCTAssertEqual(ExternalDisplay.streamPixelSize(
            currentMode: CGSize(width: 1080, height: 1920),
            nativeBounds: CGSize(width: 1080, height: 1920),
            sceneBounds: CGSize(width: 1920, height: 1080)),
            CGSize(width: 1920, height: 1080))
    }

    func testAbsentOrTransientModeUsesValidNativePixels() {
        for mode in [nil, CGSize.zero, CGSize(width: CGFloat.nan, height: 1080)] {
            XCTAssertEqual(ExternalDisplay.streamPixelSize(
                currentMode: mode, nativeBounds: CGSize(width: 1920, height: 1080),
                sceneBounds: CGSize(width: 1920, height: 1080)),
                CGSize(width: 1920, height: 1080))
        }
    }

    func testInvalidPixelSizesDoNotBecomeZeroDimensionLaunches() {
        XCTAssertNil(ExternalDisplay.streamPixelSize(
            currentMode: .zero, nativeBounds: .zero,
            sceneBounds: CGSize(width: 1920, height: 1080)))
        XCTAssertNil(ExternalDisplay.streamPixelSize(
            currentMode: CGSize(width: CGFloat.infinity, height: 1080), nativeBounds: .zero,
            sceneBounds: .zero))
    }

    func testH264DimensionsAreRoundedDownToEvenPixels() {
        XCTAssertEqual(ExternalDisplay.streamPixelSize(
            currentMode: CGSize(width: 1921, height: 1081), nativeBounds: .zero,
            sceneBounds: CGSize(width: 1920, height: 1080)),
            CGSize(width: 1920, height: 1080))
    }
}
#endif
