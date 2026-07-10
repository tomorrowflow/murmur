import XCTest
import AVFoundation
@testable import SharedModels

final class StreamingResamplerTests: XCTestCase {

    private func makeBuffer(sampleRate: Double, frames: Int, channels: AVAudioChannelCount = 1) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        // 440 Hz sine so the converter has real signal to chew on
        let data = buffer.floatChannelData![0]
        for i in 0..<frames {
            data[i] = sinf(2 * .pi * 440 * Float(i) / Float(sampleRate))
        }
        return buffer
    }

    func testPassthroughAt16k() {
        let resampler = StreamingResampler(targetSampleRate: 16000)!
        let buffer = makeBuffer(sampleRate: 16000, frames: 1024)
        let samples = resampler.resample(buffer)
        XCTAssertEqual(samples.count, 1024)
    }

    func test44100DownsamplesToCorrectRatio() {
        // The old Int-truncated decimation produced 22.05 kHz audio here.
        let resampler = StreamingResampler(targetSampleRate: 16000)!
        var total = 0
        let chunks = 20
        let framesPerChunk = 4410  // 0.1s
        for _ in 0..<chunks {
            total += resampler.resample(makeBuffer(sampleRate: 44100, frames: framesPerChunk)).count
        }
        // 2 seconds of 44.1k audio → ~2 seconds at 16k. Allow converter
        // priming latency of a couple hundred frames.
        let expected = Int(Double(chunks * framesPerChunk) * 16000.0 / 44100.0)
        XCTAssertGreaterThan(total, expected - 1000)
        XCTAssertLessThanOrEqual(total, expected + 100)
    }

    func test8kInputDoesNotTrapAndUpsamples() {
        // The old code computed stride(by: Int(8000/16000)) == stride(by: 0)
        // and crashed with "Stride size must not be zero".
        let resampler = StreamingResampler(targetSampleRate: 16000)!
        var total = 0
        for _ in 0..<10 {
            total += resampler.resample(makeBuffer(sampleRate: 8000, frames: 800)).count
        }
        let expected = 10 * 800 * 2
        XCTAssertGreaterThan(total, expected - 1000)
        XCTAssertLessThanOrEqual(total, expected + 100)
    }

    func testMidStreamFormatChangeIsHandled() {
        // Bluetooth codec switches change the tap format mid-recording.
        let resampler = StreamingResampler(targetSampleRate: 16000)!
        XCTAssertFalse(resampler.resample(makeBuffer(sampleRate: 48000, frames: 4800)).isEmpty)
        XCTAssertFalse(resampler.resample(makeBuffer(sampleRate: 8000, frames: 800)).isEmpty)
        XCTAssertEqual(resampler.resample(makeBuffer(sampleRate: 16000, frames: 160)).count, 160)
    }

    func testStereoInputIsMixedToMono() {
        let resampler = StreamingResampler(targetSampleRate: 16000)!
        let samples = resampler.resample(makeBuffer(sampleRate: 16000, frames: 1024, channels: 2))
        // Stereo at target rate still goes through the converter for the
        // channel mixdown.
        XCTAssertGreaterThan(samples.count, 0)
    }
}
