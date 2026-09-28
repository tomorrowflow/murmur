import XCTest
@testable import SharedModels

final class SmartSentenceSplitterTests: XCTestCase {

    func testEmptyTextYieldsNoSentences() {
        XCTAssertTrue(SmartSentenceSplitter.splitIntoSentences("").isEmpty)
        XCTAssertTrue(SmartSentenceSplitter.splitIntoSentences("   \n  ").isEmpty)
    }

    func testShortTextStaysWhole() {
        let result = SmartSentenceSplitter.splitIntoSentences("Just a few words here.")
        XCTAssertEqual(result, ["Just a few words here."])
    }

    func testSplitsOnSentenceBoundaries() {
        let text = "The first sentence runs to here. The second sentence follows it closely. "
            + "A third sentence closes out the paragraph."
        let result = SmartSentenceSplitter.splitIntoSentences(text)
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result[0].hasPrefix("The first"))
        XCTAssertTrue(result[2].hasPrefix("A third"))
    }

    func testDoesNotSplitOnKnownAbbreviation() {
        let text = "We met with Dr. Sanders about the migration plan last week. "
            + "She agreed to review the schedule before the end of the month."
        let result = SmartSentenceSplitter.splitIntoSentences(text)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].contains("Dr. Sanders"))
    }

    /// Regression: a bare short all-caps word used to count as an
    /// abbreviation, gluing a finished sentence onto the next one.
    func testAllCapsWordEndsASentence() {
        let text = "The board announced that it had decided to replace the CEO. "
            + "The successor will be named at the annual meeting in April."
        let result = SmartSentenceSplitter.splitIntoSentences(text)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].hasSuffix("CEO."))
    }

    func testDottedAbbreviationStillMerges() {
        let text = "The deployment covers every region in the U.S. and rollout begins on Monday morning. "
            + "Reports will follow at the end of each week without fail."
        let result = SmartSentenceSplitter.splitIntoSentences(text)
        XCTAssertTrue(result[0].contains("U.S. and"))
    }

    func testHandlesCombiningMarksWithoutCrashing() {
        // A grapheme cluster spanning what looks like a boundary must not trap.
        let text = "One sentence that is long enough to split. Another sentence with e\u{0301} marks inside it here."
        XCTAssertFalse(SmartSentenceSplitter.splitIntoSentences(text).isEmpty)
    }
}
