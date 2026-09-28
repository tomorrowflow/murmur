import XCTest
@testable import SharedModels

/// Segmentation is the pure, decision-making half of the call-transcription
/// pipeline: it decides what audio is speech and where long stretches get cut.
final class TranscriptionPipelineSegmentationTests: XCTestCase {

    private func makePipeline(
        sampleRate: Double = 16000,
        maxSegmentSeconds: Double = 30
    ) -> TranscriptionPipeline {
        TranscriptionPipeline(
            transcribe: { _ in "" },
            sampleRate: sampleRate,
            maxSegmentSeconds: maxSegmentSeconds
        )
    }

    /// Alternating tone and silence, in whole seconds.
    private func samples(sampleRate: Double, pattern: [(loud: Bool, seconds: Double)]) -> [Float] {
        var out: [Float] = []
        for part in pattern {
            let count = Int(sampleRate * part.seconds)
            if part.loud {
                for i in 0..<count { out.append(sinf(Float(i) * 0.1) * 0.5) }
            } else {
                out.append(contentsOf: [Float](repeating: 0, count: count))
            }
        }
        return out
    }

    func testEmptyInputProducesNoRegions() {
        XCTAssertTrue(makePipeline().segmentRegions(samples: []).isEmpty)
    }

    func testInputShorterThanOneFrameIsOneRegion() {
        let pipeline = makePipeline()
        let regions = pipeline.segmentRegions(samples: [Float](repeating: 0.2, count: 10))
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions[0].start, 0)
        XCTAssertEqual(regions[0].end, 10)
    }

    func testSpeechSeparatedByLongSilenceSplitsInTwo() {
        let rate: Double = 16000
        let pipeline = makePipeline(sampleRate: rate)
        let audio = samples(sampleRate: rate, pattern: [
            (loud: true, seconds: 2),
            (loud: false, seconds: 3),
            (loud: true, seconds: 2),
        ])
        let regions = pipeline.segmentRegions(samples: audio)
        XCTAssertEqual(regions.count, 2)
        XCTAssertLessThan(regions[0].end, regions[1].start)
    }

    func testEveryRegionIsNonEmptyAndOrdered() {
        let rate: Double = 16000
        let pipeline = makePipeline(sampleRate: rate)
        let audio = samples(sampleRate: rate, pattern: [
            (loud: true, seconds: 1),
            (loud: false, seconds: 2),
            (loud: true, seconds: 1),
            (loud: false, seconds: 2),
            (loud: true, seconds: 1),
        ])
        let regions = pipeline.segmentRegions(samples: audio)
        XCTAssertFalse(regions.isEmpty)
        var previousEnd = -1
        for region in regions {
            XCTAssertLessThan(region.start, region.end, "region must contain at least one sample")
            XCTAssertGreaterThanOrEqual(region.start, previousEnd)
            XCTAssertLessThanOrEqual(region.end, audio.count)
            previousEnd = region.end
        }
    }

    func testLongSpeechIsCappedAtTheSegmentLimit() {
        let rate: Double = 16000
        let maxSeconds: Double = 5
        let pipeline = makePipeline(sampleRate: rate, maxSegmentSeconds: maxSeconds)
        let audio = samples(sampleRate: rate, pattern: [(loud: true, seconds: 20)])
        let regions = pipeline.segmentRegions(samples: audio)
        XCTAssertGreaterThan(regions.count, 1)
        let limit = Int(maxSeconds * rate)
        for region in regions {
            XCTAssertLessThanOrEqual(region.end - region.start, limit + 1)
        }
    }

    /// Regression: the 2-second lookback used to reach behind `start` when the
    /// cap was short, so the chosen cut didn't advance and the loop appended
    /// empty regions until it ran out of memory.
    func testShortSegmentCapTerminatesInsteadOfLooping() {
        let rate: Double = 16000
        let pipeline = makePipeline(sampleRate: rate, maxSegmentSeconds: 1)
        let audio = samples(sampleRate: rate, pattern: [(loud: true, seconds: 8)])
        let regions = pipeline.segmentRegions(samples: audio)
        XCTAssertFalse(regions.isEmpty)
        XCTAssertLessThan(regions.count, 100, "cap loop produced far more regions than the audio can hold")
        for region in regions {
            XCTAssertLessThan(region.start, region.end)
        }
    }
}
