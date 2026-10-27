#if os(iOS)
import XCTest
import AVFoundation
import UIKit
@testable import VibeLight

@MainActor
final class ExternalVideoLayoutTests: XCTestCase {
    private let ipadBounds = CGRect(x: 0, y: 0, width: 1194, height: 834)
    private let tvBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    func testOldIPadLayoutCannotResizeVideoAfterTVTakesIt() {
        let ipad = StreamView.DisplayLayerView(frame: ipadBounds)
        let tv = DisplayHostView(frame: tvBounds)
        let video = AVSampleBufferDisplayLayer()
        ipad.attach(video)
        tv.attach(video)

        ipad.layoutSubviews()

        XCTAssertTrue(video.superlayer === tv.layer)
        XCTAssertEqual(video.frame, tvBounds)
    }

    func testOldTVLayoutCannotResizeVideoAfterIPadTakesIt() {
        let ipad = StreamView.DisplayLayerView(frame: ipadBounds)
        let tv = DisplayHostView(frame: tvBounds)
        let video = AVSampleBufferDisplayLayer()
        tv.attach(video)
        ipad.attach(video)

        tv.layoutSubviews()

        XCTAssertTrue(video.superlayer === ipad.layer)
        XCTAssertEqual(video.frame, ipadBounds)
    }

    func testOldIPadDoesNotDetachTVVideoWhenGivenAnotherLayer() {
        let ipad = StreamView.DisplayLayerView(frame: ipadBounds)
        let tv = DisplayHostView(frame: tvBounds)
        let video = AVSampleBufferDisplayLayer()
        ipad.attach(video)
        tv.attach(video)

        ipad.attach(AVSampleBufferDisplayLayer())

        XCTAssertTrue(video.superlayer === tv.layer)
    }

    func testOldTVDoesNotDetachIPadVideoWhenGivenAnotherLayer() {
        let ipad = StreamView.DisplayLayerView(frame: ipadBounds)
        let tv = DisplayHostView(frame: tvBounds)
        let video = AVSampleBufferDisplayLayer()
        tv.attach(video)
        ipad.attach(video)

        tv.attach(AVSampleBufferDisplayLayer())

        XCTAssertTrue(video.superlayer === ipad.layer)
    }

    func testCurrentOwnerStillResizesVideoToItsBounds() {
        let tv = DisplayHostView(frame: tvBounds)
        let video = AVSampleBufferDisplayLayer()
        tv.attach(video)
        let resized = CGRect(x: 0, y: 0, width: 3840, height: 2160)
        tv.bounds = resized

        tv.layoutSubviews()

        XCTAssertEqual(video.frame, resized)
    }
}
#endif
