import Foundation
import SharedModels

// MARK: - TTS Segment Types

enum TTSSegment {
    case silence(durationMs: Int)
    case spokenCue(text: String)
    case content(text: String, speed: Float)
}

// MARK: - Renderer

struct MarkdownTTSRenderer {

    // MARK: - Timing Constants

    static let sentenceGapMs = 300
    static let bodyPreSilenceMs = 600
    static let bodyPostSilenceMs = 300
    static let listPreSilenceMs = 500
    static let listPostSilenceMs = 400
    static let listItemGapMs = 200
    static let blockquotePreSilenceMs = 500
    static let blockquotePostSilenceMs = 400
    static let codeBlockPreSilenceMs = 500
    static let codeBlockPostSilenceMs = 500
    static let horizontalRulePreSilenceMs = 300
    static let horizontalRulePostSilenceMs = 300

    // MARK: - Speed Constants

    static let headingSpeed: Float = 1.0
    static let bodySpeed: Float = 1.15
    static let listSpeed: Float = 1.1
    static let blockquoteSpeed: Float = 1.1
    static let codeBlockSpeed: Float = 1.0
    static let cueSpeed: Float = 0.9

    // MARK: - Render

    /// Converts a MarkdownParagraph into an ordered sequence of TTS segments.
    static func render(_ paragraph: MarkdownParagraph) -> [TTSSegment] {
        switch paragraph.kind {
        case .heading(let level):
            return renderHeading(paragraph, level: level)
        case .body:
            return renderBody(paragraph)
        case .codeBlock:
            return renderCodeBlock(paragraph)
        case .list:
            return renderList(paragraph)
        case .blockquote:
            return renderBlockquote(paragraph)
        case .table:
            return renderTable(paragraph)
        case .frontmatter, .htmlComment, .horizontalRule:
            return []  // Skip front matter, HTML comments, and horizontal rules
        }
    }

    // MARK: - Heading

    private static func renderHeading(_ paragraph: MarkdownParagraph, level: Int) -> [TTSSegment] {
        let preSilence: Int
        let cue: String
        let postSilence: Int
        let speed: Float

        switch level {
        case 1:
            preSilence = 1200
            cue = "Section"
            postSilence = 800
            speed = 1.0
        case 2:
            preSilence = 1000
            cue = "Subsection"
            postSilence = 600
            speed = 1.0
        default:
            preSilence = 800
            cue = "Heading"
            postSilence = 500
            speed = 1.05
        }

        let text = MarkdownParagraphParser.stripMarkdown(paragraph.text)
        guard !text.isEmpty else { return [] }

        // Prepend cue to content so Kokoro speaks it naturally as one phrase
        let combined = "\(cue): \(text)"
        return [
            .silence(durationMs: preSilence),
            .content(text: combined, speed: speed),
            .silence(durationMs: postSilence)
        ]
    }

    // MARK: - Body

    private static func renderBody(_ paragraph: MarkdownParagraph) -> [TTSSegment] {
        let text = MarkdownParagraphParser.stripMarkdown(paragraph.text)
        guard !text.isEmpty else { return [] }

        var segments: [TTSSegment] = [.silence(durationMs: bodyPreSilenceMs)]

        // Split into sentences for natural reading with inter-sentence gaps
        let sentences = SmartSentenceSplitter.splitIntoSentences(text)
        for (i, sentence) in sentences.enumerated() {
            segments.append(.content(text: sentence, speed: bodySpeed))
            if i < sentences.count - 1 {
                segments.append(.silence(durationMs: sentenceGapMs))
            }
        }

        segments.append(.silence(durationMs: bodyPostSilenceMs))
        return segments
    }

    // MARK: - Code Block

    private static func renderCodeBlock(_ paragraph: MarkdownParagraph) -> [TTSSegment] {
        let lines = paragraph.text.components(separatedBy: "\n")

        // Extract content lines (skip fence lines)
        var contentLines: [String] = []
        var insideFence = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence = !insideFence
                continue
            }
            if insideFence {
                contentLines.append(line)
            }
        }

        var segments: [TTSSegment] = [
            .silence(durationMs: codeBlockPreSilenceMs)
        ]

        if let firstLine = contentLines.first, !firstLine.trimmingCharacters(in: .whitespaces).isEmpty {
            let combined = "Code block: \(firstLine.trimmingCharacters(in: .whitespaces))"
            segments.append(.content(text: combined, speed: codeBlockSpeed))
        } else {
            segments.append(.content(text: "Code block.", speed: codeBlockSpeed))
        }

        let remaining = contentLines.dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if remaining > 0 {
            let noun = remaining == 1 ? "line" : "lines"
            segments.append(.content(text: "and \(remaining) more \(noun).", speed: codeBlockSpeed))
        }

        segments.append(.silence(durationMs: codeBlockPostSilenceMs))
        return segments
    }

    // MARK: - List

    private static func renderList(_ paragraph: MarkdownParagraph) -> [TTSSegment] {
        let items = extractListItems(paragraph.text)
        guard !items.isEmpty else { return [] }

        var segments: [TTSSegment] = [
            .silence(durationMs: listPreSilenceMs)
        ]

        for (i, item) in items.enumerated() {
            let stripped = MarkdownParagraphParser.stripMarkdown(item)
            guard !stripped.isEmpty else { continue }
            if i == 0 {
                // Prepend "List:" to first item
                segments.append(.content(text: "List: \(stripped)", speed: listSpeed))
            } else {
                segments.append(.silence(durationMs: listItemGapMs))
                segments.append(.content(text: "Next: \(stripped)", speed: listSpeed))
            }
        }

        segments.append(.silence(durationMs: listPostSilenceMs))
        return segments
    }

    private static func extractListItems(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var items: [String] = []
        var currentItem = ""

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Check if this is a new list item
            let isNewItem = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") ||
                            trimmed.hasPrefix("+ ") ||
                            trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil

            if isNewItem {
                if !currentItem.isEmpty {
                    items.append(currentItem)
                }
                currentItem = trimmed
            } else {
                // Continuation line
                currentItem += " " + trimmed
            }
        }

        if !currentItem.isEmpty {
            items.append(currentItem)
        }

        return items
    }

    // MARK: - Blockquote

    private static func renderBlockquote(_ paragraph: MarkdownParagraph) -> [TTSSegment] {
        let text = MarkdownParagraphParser.stripMarkdown(paragraph.text)
        guard !text.isEmpty else { return [] }

        var segments: [TTSSegment] = [
            .silence(durationMs: blockquotePreSilenceMs)
        ]

        // Prepend "Quote:" to first sentence
        let sentences = SmartSentenceSplitter.splitIntoSentences(text)
        for (i, sentence) in sentences.enumerated() {
            let content = i == 0 ? "Quote: \(sentence)" : sentence
            segments.append(.content(text: content, speed: blockquoteSpeed))
            if i < sentences.count - 1 {
                segments.append(.silence(durationMs: sentenceGapMs))
            }
        }

        segments.append(.silence(durationMs: blockquotePostSilenceMs))
        return segments
    }

    // MARK: - Table

    private static func renderTable(_ paragraph: MarkdownParagraph) -> [TTSSegment] {
        let lines = paragraph.text.components(separatedBy: "\n")

        // Filter out separator rows (|---|---|) and empty lines
        let contentRows = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return false }
            // Separator row: only contains |, -, :, and spaces
            let stripped = trimmed.replacingOccurrences(of: "[|\\-:\\s]", with: "", options: .regularExpression)
            return !stripped.isEmpty
        }

        guard !contentRows.isEmpty else { return [] }

        var segments: [TTSSegment] = [
            .silence(durationMs: 500)
        ]

        for (i, row) in contentRows.enumerated() {
            // Strip the row: split by |, trim each cell, join with periods
            let cells = row.components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let rowText = cells.joined(separator: ". ")
            guard !rowText.isEmpty else { continue }

            // Prepend "Table:" cue to first row (header)
            let content: String
            if i == 0 {
                content = "Table: \(rowText)"
            } else {
                content = rowText
            }

            segments.append(.content(text: content, speed: bodySpeed))
            if i < contentRows.count - 1 {
                segments.append(.silence(durationMs: sentenceGapMs))
            }
        }

        segments.append(.silence(durationMs: 400))
        return segments
    }

    // MARK: - Horizontal Rule

    private static func renderHorizontalRule() -> [TTSSegment] {
        return [
            .silence(durationMs: horizontalRulePreSilenceMs),
            .content(text: "Section break.", speed: bodySpeed),
            .silence(durationMs: horizontalRulePostSilenceMs)
        ]
    }

    // MARK: - Silence Generation

    /// Generate silence PCM data at 24kHz 16-bit mono.
    static func generateSilence(durationMs: Int, sampleRate: Int = 24000) -> Data {
        let sampleCount = Int(Double(durationMs) / 1000.0 * Double(sampleRate))
        let byteCount = sampleCount * 2  // 16-bit = 2 bytes per sample
        return Data(count: byteCount)
    }

    /// Generate silence as WAV data at 24kHz 16-bit mono.
    static func generateSilenceWav(durationMs: Int, sampleRate: Int = 24000) -> Data {
        let pcmData = generateSilence(durationMs: durationMs, sampleRate: sampleRate)
        return wrapInWav(pcmData: pcmData, sampleRate: sampleRate)
    }

    private static func wrapInWav(pcmData: Data, sampleRate: Int) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcmData.count)
        let fileSize = 36 + dataSize

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        header.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // PCM
        header.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        header.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        header.append(contentsOf: "data".utf8)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        header.append(pcmData)

        return header
    }
}
