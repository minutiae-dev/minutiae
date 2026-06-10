import AVFoundation
import XCTest
@testable import EngineCore

final class ResamplerTests: XCTestCase {

    private func sineBuffer(format: AVAudioFormat, frames: Int, frequency: Double, phaseOffset: Double = 0) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        let sr = format.sampleRate
        for ch in 0..<Int(format.channelCount) {
            let ptr = buf.floatChannelData![ch]
            for i in 0..<frames {
                ptr[i] = Float(sin(2 * .pi * frequency * (Double(i) + phaseOffset) / sr) * 0.5)
            }
        }
        return buf
    }

    func test48kMonoTo16kSampleCount() throws {
        let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                     channels: 1, interleaved: false)!
        let resampler = try XCTUnwrap(Resampler(inputFormat: inFormat))

        // Feed 1 s of 440 Hz sine in ten 100 ms buffers.
        var total = 0
        for i in 0..<10 {
            let buf = sineBuffer(format: inFormat, frames: 4_800, frequency: 440,
                                 phaseOffset: Double(i) * 4_800)
            total += resampler.convert(buf).count
        }
        // 48 000 → 16 000: expect ~16 000 output samples (converter may hold
        // a small priming tail).
        XCTAssertEqual(Double(total), 16_000, accuracy: 800)
    }

    func test48kStereoTo16kMono() throws {
        let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                     channels: 2, interleaved: false)!
        let resampler = try XCTUnwrap(Resampler(inputFormat: inFormat))
        var total = 0
        for _ in 0..<5 {
            total += resampler.convert(sineBuffer(format: inFormat, frames: 4_800, frequency: 440)).count
        }
        XCTAssertEqual(Double(total), 8_000, accuracy: 500)
    }

    func test24kInputUpsampleRatio() throws {
        // AirPods-style 24 kHz mic input.
        let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                     channels: 1, interleaved: false)!
        let resampler = try XCTUnwrap(Resampler(inputFormat: inFormat))
        var total = 0
        for _ in 0..<4 {
            total += resampler.convert(sineBuffer(format: inFormat, frames: 2_400, frequency: 220)).count
        }
        // 9 600 in at 24 k → ~6 400 out at 16 k.
        XCTAssertEqual(Double(total), 6_400, accuracy: 400)
    }

    func testOutputIsAudible() throws {
        // The resampled sine must keep its energy (no silent/garbage output).
        let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                     channels: 1, interleaved: false)!
        let resampler = try XCTUnwrap(Resampler(inputFormat: inFormat))
        var all: [Float] = []
        for i in 0..<10 {
            all += resampler.convert(sineBuffer(format: inFormat, frames: 4_800, frequency: 440,
                                                phaseOffset: Double(i) * 4_800))
        }
        let db = WindowedTranscriber.rmsDbfs(all)
        XCTAssertGreaterThan(db, -12) // 0.5-amplitude sine ≈ −9 dBFS
        XCTAssertLessThan(db, -6)
    }
}
