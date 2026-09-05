import XCTest
@testable import EngineCore

final class GainTimelineTests: XCTestCase {

    func testEmptyTimelineIsUnity() {
        let t = GainTimeline()
        XCTAssertEqual(t.gain(atSessionTime: 0), 1.0)
        XCTAssertEqual(t.gain(atSessionTime: 12.5), 1.0)
        XCTAssertNil(t.readyThrough)
    }

    /// Unity before the first frame: audio captured before the analyzer had
    /// any reference must pass through untouched.
    func testBeforeFirstFrameIsUnity() {
        let t = GainTimeline()
        t.append(gain: 0.2, frameTime: 1.0)
        XCTAssertEqual(t.gain(atSessionTime: 0.5), 1.0)
        XCTAssertEqual(t.gain(atSessionTime: 0.999), 1.0)
    }

    func testAtAndPastLastFrameHoldsLast() {
        let t = GainTimeline()
        t.append(gain: 0.5, frameTime: 1.0)
        t.append(gain: 0.25, frameTime: 2.0)
        XCTAssertEqual(t.gain(atSessionTime: 2.0), 0.25)
        XCTAssertEqual(t.gain(atSessionTime: 99.0), 0.25)
    }

    func testLinearInterpolation() {
        let t = GainTimeline()
        t.append(gain: 1.0, frameTime: 0.0)
        t.append(gain: 0.0, frameTime: 1.0)
        XCTAssertEqual(t.gain(atSessionTime: 0.0), 1.0, accuracy: 1e-6)
        XCTAssertEqual(t.gain(atSessionTime: 0.25), 0.75, accuracy: 1e-6)
        XCTAssertEqual(t.gain(atSessionTime: 0.5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(t.gain(atSessionTime: 0.75), 0.25, accuracy: 1e-6)
    }

    func testInterpolationAcrossManyFrames() {
        let t = GainTimeline()
        let hop = 0.016
        for i in 0..<100 {
            t.append(gain: Float(i) / 100.0, frameTime: Double(i) * hop)
        }
        // Exactly on frame 50.
        XCTAssertEqual(t.gain(atSessionTime: 50 * hop), 0.50, accuracy: 1e-5)
        // Halfway between frames 10 and 11.
        XCTAssertEqual(t.gain(atSessionTime: 10.5 * hop), 0.105, accuracy: 1e-5)
    }

    func testReadyThroughTracksLastFrame() {
        let t = GainTimeline()
        t.append(gain: 1.0, frameTime: 0.5)
        XCTAssertEqual(t.readyThrough ?? -1, 0.5, accuracy: 1e-9)
        t.append(gain: 1.0, frameTime: 1.5)
        XCTAssertEqual(t.readyThrough ?? -1, 1.5, accuracy: 1e-9)
    }

    func testOutOfOrderFrameIsDropped() {
        let t = GainTimeline()
        t.append(gain: 0.5, frameTime: 1.0)
        t.append(gain: 0.1, frameTime: 0.5)   // out of order — ignored
        XCTAssertEqual(t.frameCount, 1)
        XCTAssertEqual(t.readyThrough ?? -1, 1.0, accuracy: 1e-9)
    }

    /// Overwrites oldest once full, and interpolation still works on the
    /// wrapped ring.
    func testRingWraparound() {
        let cap = 8
        let t = GainTimeline(capacityFrames: cap)
        for i in 0..<20 {
            t.append(gain: Float(i), frameTime: Double(i))
        }
        XCTAssertEqual(t.frameCount, cap)
        XCTAssertEqual(t.readyThrough ?? -1, 19.0, accuracy: 1e-9)
        // Oldest surviving frame is 12 (19 - 8 + 1).
        XCTAssertEqual(t.gain(atSessionTime: 12.0), 12.0, accuracy: 1e-5)
        XCTAssertEqual(t.gain(atSessionTime: 15.5), 15.5, accuracy: 1e-5)
        XCTAssertEqual(t.gain(atSessionTime: 19.0), 19.0, accuracy: 1e-5)
        // Before the surviving window → unity, not a stale gain.
        XCTAssertEqual(t.gain(atSessionTime: 3.0), 1.0, accuracy: 1e-6)
    }

    func testSingleFrame() {
        let t = GainTimeline()
        t.append(gain: 0.3, frameTime: 5.0)
        XCTAssertEqual(t.gain(atSessionTime: 4.0), 1.0)   // before
        XCTAssertEqual(t.gain(atSessionTime: 5.0), 0.3)   // at
        XCTAssertEqual(t.gain(atSessionTime: 6.0), 0.3)   // after
    }

    func testConcurrentAppendAndRead() {
        let t = GainTimeline()
        let done = expectation(description: "concurrent access")
        done.expectedFulfillmentCount = 2
        DispatchQueue.global().async {
            for i in 0..<5000 { t.append(gain: 0.5, frameTime: Double(i) * 0.016) }
            done.fulfill()
        }
        DispatchQueue.global().async {
            for _ in 0..<5000 { _ = t.gain(atSessionTime: 1.0) }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }
}
