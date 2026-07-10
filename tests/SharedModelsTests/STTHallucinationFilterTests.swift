import XCTest
@testable import SharedModels

final class STTHallucinationFilterTests: XCTestCase {

    func testKnownHallucinationsOnShortAudioAreDropped() {
        XCTAssertTrue(STTHallucinationFilter.isLikelyHallucination("you", audioDurationSeconds: 0.7))
        XCTAssertTrue(STTHallucinationFilter.isLikelyHallucination("Thanks for watching!", audioDurationSeconds: 1.0))
        XCTAssertTrue(STTHallucinationFilter.isLikelyHallucination(" Okay. ", audioDurationSeconds: 0.9))
        XCTAssertTrue(STTHallucinationFilter.isLikelyHallucination("", audioDurationSeconds: 0.7))
    }

    func testLongAudioIsNeverFiltered() {
        XCTAssertFalse(STTHallucinationFilter.isLikelyHallucination("you", audioDurationSeconds: 3.0))
        XCTAssertFalse(STTHallucinationFilter.isLikelyHallucination("okay", audioDurationSeconds: 1.5))
    }

    func testRealShortUtterancesPass() {
        XCTAssertFalse(STTHallucinationFilter.isLikelyHallucination("stop the build", audioDurationSeconds: 1.0))
        XCTAssertFalse(STTHallucinationFilter.isLikelyHallucination("yes please", audioDurationSeconds: 1.0))
    }

    func testNormalizationStripsPunctuationAndCase() {
        XCTAssertTrue(STTHallucinationFilter.isLikelyHallucination("Thank you.", audioDurationSeconds: 1.0))
        XCTAssertTrue(STTHallucinationFilter.isLikelyHallucination("BYE!", audioDurationSeconds: 1.0))
    }
}
