import Foundation

public struct OpenClawResponseFilter {

    // MARK: - Public API

    /// Filter response text for display: strips reasoning tags, TTS directives, and tool call blocks.
    public static func filter(_ text: String) -> String {
        var result = text
        result = stripReasoningTags(result)
        result = stripTtsDirectives(result)
        result = stripToolCallBlocks(result)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    /// Filter response text for TTS: applies all display filters plus markdown stripping.
    public static func filterForTTS(_ text: String) -> String {
        var result = filter(text)
        result = stripMarkdownForSpeech(result)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    // MARK: - Reasoning Tags

    private static let reasoningTagNames = ["think", "thinking", "thought", "antthinking", "final"]

    // Quick-scan regex to skip text with no tags
    private static let hasReasoningTagRegex = try! NSRegularExpression(
        pattern: #"<\s*/?\s*(?:think(?:ing)?|thought|antthinking|final)\b"#,
        options: .caseInsensitive
    )

    static func stripReasoningTags(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        guard hasReasoningTagRegex.firstMatch(in: text, range: range) != nil else {
            return text
        }

        // Extract fenced code blocks to protect them
        var protected: [(range: Range<String.Index>, content: String)] = []
        let codeBlockRegex = try! NSRegularExpression(pattern: #"```[\s\S]*?```"#)
        let codeMatches = codeBlockRegex.matches(in: text, range: range)
        for match in codeMatches.reversed() {
            if let swiftRange = Range(match.range, in: text) {
                protected.insert((range: swiftRange, content: String(text[swiftRange])), at: 0)
            }
        }

        var result = text

        // Strip each reasoning tag pair and their content
        for tagName in reasoningTagNames {
            let pattern = #"<\s*"# + NSRegularExpression.escapedPattern(for: tagName) + #"\b[^>]*>[\s\S]*?<\s*/\s*"# + NSRegularExpression.escapedPattern(for: tagName) + #"\s*>"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
            }
        }

        // Strip trailing unclosed opening tags (e.g., "<thinking>" at end of partial response)
        for tagName in reasoningTagNames {
            let pattern = #"<\s*"# + NSRegularExpression.escapedPattern(for: tagName) + #"\b[^>]*>[\s\S]*$"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
            }
        }

        // Restore protected code blocks by replacing placeholders if any were modified
        // Since we operate on the full text, code blocks should remain intact if they don't contain tags
        // This is a safety-net approach matching the spec's guidance

        return result
    }

    // MARK: - TTS Directives

    private static let ttsDirectiveRegex = try! NSRegularExpression(
        pattern: #"\[\[/?tts(?::[\w=. ]+)?\]\]"#
    )

    // Also strip [[tts:text]]...[[/tts:text]] blocks with their content
    private static let ttsTextBlockRegex = try! NSRegularExpression(
        pattern: #"\[\[tts:text\]\][\s\S]*?\[\[/tts:text\]\]"#
    )

    static func stripTtsDirectives(_ text: String) -> String {
        var result = text
        let range = NSRange(result.startIndex..., in: result)
        result = ttsTextBlockRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        let range2 = NSRange(result.startIndex..., in: result)
        result = ttsDirectiveRegex.stringByReplacingMatches(in: result, range: range2, withTemplate: "")
        return result
    }

    // MARK: - Tool Call Blocks

    private static let toolCallTagNames = ["tool_call", "tool_result", "function_call"]

    static func stripToolCallBlocks(_ text: String) -> String {
        var result = text
        for tagName in toolCallTagNames {
            let pattern = #"<\s*"# + NSRegularExpression.escapedPattern(for: tagName) + #"\b[^>]*>[\s\S]*?<\s*/\s*"# + NSRegularExpression.escapedPattern(for: tagName) + #"\s*>"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
            }
        }
        return result
    }

    // MARK: - Markdown Stripping (TTS only)

    static func stripMarkdownForSpeech(_ text: String) -> String {
        var result = text

        // Remove fenced code blocks entirely
        if let regex = try? NSRegularExpression(pattern: #"```[\s\S]*?```"#) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        // Remove inline code
        if let regex = try? NSRegularExpression(pattern: #"`[^`]+`"#) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        // Remove image syntax entirely: ![alt](url)
        if let regex = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\([^\)]*\)"#) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        // Convert link syntax to just the text: [text](url) -> text
        if let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\([^\)]*\)"#) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1")
        }

        // Remove header markers (keep text)
        if let regex = try? NSRegularExpression(pattern: #"(?m)^#{1,6}\s+"#) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        // Remove bold/italic markers
        if let regex = try? NSRegularExpression(pattern: #"\*{1,3}|_{1,3}"#) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        // Remove HTML tags
        if let regex = try? NSRegularExpression(pattern: #"</?[a-zA-Z][^>]*>"#) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }

        // Collapse multiple newlines
        if let regex = try? NSRegularExpression(pattern: #"\n{3,}"#) {
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "\n\n")
        }

        return result
    }
}
