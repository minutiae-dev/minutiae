import XCTest
@testable import EngineCore

final class SessionClockTests: XCTestCase {

    func testKnownTimebaseOneToOne() {
        // 1 ns per tick (Intel-style timebase).
        let clock = SessionClock(anchorHostTime: 1_000, t0EpochMs: 0,
                                 timebaseNumer: 1, timebaseDenom: 1)
        XCTAssertEqual(clock.seconds(fromHostTime: 1_000), 0)
        XCTAssertEqual(clock.seconds(fromHostTime: 1_000 + 2_000_000_000), 2.0, accuracy: 1e-9)
        XCTAssertEqual(clock.seconds(fromHostTime: 1_000 + 500_000_000), 0.5, accuracy: 1e-9)
    }

    func testAppleSiliconTimebase() {
        // Apple Silicon: 125/3 ns per tick → 24 000 000 ticks per second.
        let clock = SessionClock(anchorHostTime: 10_000, t0EpochMs: 0,
                                 timebaseNumer: 125, timebaseDenom: 3)
        XCTAssertEqual(clock.seconds(fromHostTime: 10_000 + 24_000_000), 1.0, accuracy: 1e-9)
        XCTAssertEqual(clock.seconds(fromHostTime: 10_000 + 36_000_000), 1.5, accuracy: 1e-9)
    }

    func testHostTimeBeforeAnchorIsNegative() {
        let clock = SessionClock(anchorHostTime: 1_000_000_000, t0EpochMs: 0,
                                 timebaseNumer: 1, timebaseDenom: 1)
        XCTAssertEqual(clock.seconds(fromHostTime: 0), -1.0, accuracy: 1e-9)
    }

    func testRealClockMonotonicAndAnchored() {
        let clock = SessionClock()
        let t = clock.now()
        XCTAssertGreaterThanOrEqual(t, 0)
        XCTAssertLessThan(t, 5) // freshly created
        XCTAssertGreaterThanOrEqual(clock.now(), t)
        // t0EpochMs is "now-ish" wall clock.
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        XCTAssertLessThan(abs(nowMs - clock.t0EpochMs), 5_000)
    }
}
