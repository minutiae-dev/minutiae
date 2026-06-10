import XCTest
@testable import EngineCore

final class RingBufferTests: XCTestCase {

    func testPopWindowRequiresEnoughSamples() {
        let ring = RingBuffer(capacity: 10)
        ring.append([1, 2, 3])
        XCTAssertNil(ring.popWindow(count: 5, advance: 4))
        ring.append([4, 5])
        XCTAssertEqual(ring.popWindow(count: 5, advance: 4), [1, 2, 3, 4, 5])
    }

    func testOverlappingWindows() {
        // 5-sample window, 4-sample advance = 1-sample overlap (the 5 s / 4 s
        // hop semantics at miniature scale).
        let ring = RingBuffer(capacity: 32)
        ring.append([1, 2, 3, 4, 5, 6, 7, 8, 9])
        XCTAssertEqual(ring.popWindow(count: 5, advance: 4), [1, 2, 3, 4, 5])
        XCTAssertEqual(ring.popWindow(count: 5, advance: 4), [5, 6, 7, 8, 9])
        XCTAssertNil(ring.popWindow(count: 5, advance: 4))
        XCTAssertEqual(ring.availableSamples, 1) // the overlap sample remains
    }

    func testWraparound() {
        let ring = RingBuffer(capacity: 8)
        ring.append([1, 2, 3, 4, 5, 6])
        XCTAssertEqual(ring.popWindow(count: 5, advance: 4), [1, 2, 3, 4, 5])
        // head is now at index 4; this append wraps past the end of storage.
        ring.append([7, 8, 9, 10])
        XCTAssertEqual(ring.popWindow(count: 5, advance: 5), [5, 6, 7, 8, 9])
        XCTAssertEqual(ring.drainAll(), [10])
    }

    func testOverflowDropsOldestAndCounts() {
        let ring = RingBuffer(capacity: 4)
        ring.append([1, 2, 3, 4])
        XCTAssertEqual(ring.droppedSamples, 0)
        ring.append([5, 6]) // displaces 1, 2
        XCTAssertEqual(ring.droppedSamples, 2)
        XCTAssertEqual(ring.popWindow(count: 4, advance: 4), [3, 4, 5, 6])
    }

    func testGiantAppendKeepsMostRecent() {
        let ring = RingBuffer(capacity: 4)
        ring.append([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        XCTAssertEqual(ring.droppedSamples, 6)
        XCTAssertEqual(ring.popWindow(count: 4, advance: 4), [7, 8, 9, 10])
    }

    func testDrainAllEmptiesBuffer() {
        let ring = RingBuffer(capacity: 8)
        ring.append([1, 2, 3])
        XCTAssertEqual(ring.drainAll(), [1, 2, 3])
        XCTAssertEqual(ring.availableSamples, 0)
        XCTAssertEqual(ring.drainAll(), [])
    }

    func testFiveSecondWindowFourSecondHopAtAsrRate() {
        // Realistic scale: 16 kHz, 5 s window (80 000), 4 s hop (64 000).
        let sr = 16_000
        let ring = RingBuffer(capacity: 30 * sr)
        let window = 5 * sr
        let hop = 4 * sr
        // 13 s of ramp samples → expect windows at 0–5 s, 4–9 s, 8–13 s.
        let samples = (0..<(13 * sr)).map { Float($0) }
        ring.append(samples)
        var starts: [Float] = []
        while let w = ring.popWindow(count: window, advance: hop) {
            XCTAssertEqual(w.count, window)
            XCTAssertEqual(w.last!, w.first! + Float(window - 1))
            starts.append(w.first!)
        }
        XCTAssertEqual(starts, [0, Float(hop), Float(2 * hop)])
        XCTAssertEqual(ring.availableSamples, 13 * sr - 3 * hop)
    }
}
