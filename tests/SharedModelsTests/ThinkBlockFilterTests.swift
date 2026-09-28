import XCTest
@testable import SharedModels

/// The streaming filter is what keeps a reasoning model's `<think>` text out
/// of the read-aloud overlay and the text-to-speech queue.
final class ThinkBlockFilterTests: XCTestCase {

    /// Feed a whole response one character at a time, the worst case for a
    /// filter that has to recognise tags split across chunks.
    private func filterCharByChar(_ text: String) -> String {
        var filter = ThinkBlockFilter()
        var out = ""
        for character in text {
            out += filter.consume(String(character))
        }
        out += filter.flush()
        return out
    }

    func testPassesThroughTextWithNoThinkBlock() {
        XCTAssertEqual(filterCharByChar("Hello there."), "Hello there.")
    }

    func testRemovesCompleteThinkBlock() {
        let input = "Before <think>reasoning goes here</think>After"
        XCTAssertEqual(filterCharByChar(input), "Before After")
    }

    func testRemovesMultipleThinkBlocks() {
        let input = "A<think>one</think>B<think>two</think>C"
        XCTAssertEqual(filterCharByChar(input), "ABC")
    }

    /// The regression this type exists for: mid-stream there is no closing tag
    /// yet, and the old whole-string regex let the reasoning text through.
    func testWithholdsUnterminatedThinkBlock() {
        var filter = ThinkBlockFilter()
        var emitted = filter.consume("Answer: <think>I should consider")
        emitted += filter.consume(" several options before")
        XCTAssertEqual(emitted, "Answer: ")
        XCTAssertTrue(filter.isInsideThinkBlock)
    }

    /// An unterminated block is dropped rather than flushed as answer text.
    func testFlushDropsUnterminatedThinkContent() {
        var filter = ThinkBlockFilter()
        _ = filter.consume("<think>never closed")
        XCTAssertEqual(filter.flush(), "")
    }

    func testFlushReturnsHeldBackPartialTag() {
        var filter = ThinkBlockFilter()
        // "<thi" could still become "<think>", so it is withheld until the end.
        XCTAssertEqual(filter.consume("done <thi"), "done ")
        XCTAssertEqual(filter.flush(), "<thi")
    }

    func testTagSplitAcrossChunksIsStillRecognised() {
        var filter = ThinkBlockFilter()
        var out = filter.consume("Start <thi")
        out += filter.consume("nk>hidden</thi")
        out += filter.consume("nk>End")
        out += filter.flush()
        XCTAssertEqual(out, "Start End")
    }

    func testTextResemblingATagIsNotSwallowed() {
        XCTAssertEqual(filterCharByChar("Use <thing> here"), "Use <thing> here")
    }

    func testTrailingPartialFindsLongestOverlap() {
        XCTAssertEqual(ThinkBlockFilter.trailingPartial(of: "abc<th", for: "<think>"), "<th")
        XCTAssertEqual(ThinkBlockFilter.trailingPartial(of: "abc", for: "<think>"), "")
        // A full tag is not a *partial* match.
        XCTAssertEqual(ThinkBlockFilter.trailingPartial(of: "<think>", for: "<think>"), "")
    }
}
