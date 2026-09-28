import Foundation

/// Incremental filter that removes `<think>…</think>` reasoning blocks from a
/// streamed LLM response.
///
/// The whole-string regex can only strip a block once its closing tag has
/// arrived, which is useless mid-stream: while a reasoning model is still
/// inside its `<think>` block there is no `</think>` yet, so the pattern
/// matches nothing and the raw reasoning text reaches the consumer — in
/// Murmur's case the read-aloud overlay and, through the sentence splitter,
/// the text-to-speech queue.
///
/// This type tracks the open/closed state across chunks instead. It also
/// withholds any trailing text that could still turn out to be the start of a
/// tag (`"<thi"`), so a tag split across two chunks is never emitted.
public struct ThinkBlockFilter {
    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    private var pending = ""
    private var inThink = false

    public init() {}

    /// True while the stream is inside an unterminated think block.
    public var isInsideThinkBlock: Bool { inThink }

    /// Feed the next streamed chunk. Returns the text that is safe to emit now.
    public mutating func consume(_ chunk: String) -> String {
        pending += chunk
        var out = ""

        while true {
            if inThink {
                if let range = pending.range(of: Self.closeTag) {
                    pending = String(pending[range.upperBound...])
                    inThink = false
                    continue
                }
                // Discard reasoning text, but hold back anything that could be
                // the beginning of the closing tag.
                pending = Self.trailingPartial(of: pending, for: Self.closeTag)
                break
            }

            if let range = pending.range(of: Self.openTag) {
                out += pending[..<range.lowerBound]
                pending = String(pending[range.upperBound...])
                inThink = true
                continue
            }

            let held = Self.trailingPartial(of: pending, for: Self.openTag)
            let emitEnd = pending.index(pending.endIndex, offsetBy: -held.count)
            out += pending[..<emitEnd]
            pending = held
            break
        }

        return out
    }

    /// Text still buffered when the stream ends. An unterminated think block is
    /// dropped — a model that never closed its reasoning produced no answer.
    public mutating func flush() -> String {
        let rest = inThink ? "" : pending
        pending = ""
        inThink = false
        return rest
    }

    /// Longest suffix of `s` that is also a proper prefix of `tag`.
    static func trailingPartial(of s: String, for tag: String) -> String {
        var length = min(s.count, tag.count - 1)
        while length > 0 {
            let suffix = String(s.suffix(length))
            if tag.hasPrefix(suffix) { return suffix }
            length -= 1
        }
        return ""
    }
}
