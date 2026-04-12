import Foundation

// MARK: - Types

enum ParagraphKind: Equatable {
    case heading(level: Int)
    case body
    case codeBlock
    case list
    case blockquote
    case horizontalRule
    case table
    case frontmatter
    case htmlComment
}

struct MarkdownParagraph {
    let index: Int
    let text: String
    let lineRange: Range<Int>  // 1-based, half-open
    let kind: ParagraphKind
}

struct MarkdownDocument {
    let filePath: String
    let paragraphs: [MarkdownParagraph]
    let rawContent: String
    let modificationDate: Date?

    func paragraph(containingLine line: Int) -> MarkdownParagraph? {
        paragraphs.first { $0.lineRange.contains(line) }
    }

    func paragraphIndex(containingLine line: Int) -> Int? {
        paragraphs.firstIndex { $0.lineRange.contains(line) }
    }
}

// MARK: - Parser

struct MarkdownParagraphParser {

    static func parse(filePath: String) throws -> MarkdownDocument {
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        let modDate = try? FileManager.default.attributesOfItem(atPath: filePath)[.modificationDate] as? Date
        let paragraphs = parse(content: content)
        return MarkdownDocument(
            filePath: filePath,
            paragraphs: paragraphs,
            rawContent: content,
            modificationDate: modDate
        )
    }

    static func parse(content: String) -> [MarkdownParagraph] {
        let lines = content.components(separatedBy: "\n")
        var paragraphs: [MarkdownParagraph] = []
        var i = 0
        let lineCount = lines.count

        // Skip YAML front matter
        if lineCount > 0 && lines[0].trimmingCharacters(in: .whitespaces) == "---" {
            var fmEnd = -1
            for j in 1..<lineCount {
                if lines[j].trimmingCharacters(in: .whitespaces) == "---" {
                    fmEnd = j
                    break
                }
            }
            if fmEnd > 0 {
                let text = lines[0...fmEnd].joined(separator: "\n")
                paragraphs.append(MarkdownParagraph(
                    index: paragraphs.count,
                    text: text,
                    lineRange: 1..<(fmEnd + 2),  // 1-based
                    kind: .frontmatter
                ))
                i = fmEnd + 1
                // Skip blank lines after front matter
                while i < lineCount && lines[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    i += 1
                }
            }
        }

        while i < lineCount {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip blank lines
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Fenced code block
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = trimmed.hasPrefix("```") ? "```" : "~~~"
                let startLine = i
                i += 1
                while i < lineCount {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        i += 1
                        break
                    }
                    i += 1
                }
                let text = lines[startLine..<i].joined(separator: "\n")
                paragraphs.append(MarkdownParagraph(
                    index: paragraphs.count,
                    text: text,
                    lineRange: (startLine + 1)..<(i + 1),
                    kind: .codeBlock
                ))
                continue
            }

            // HTML comment (single-line or multi-line block)
            if trimmed.hasPrefix("<!--") {
                let startLine = i
                if trimmed.contains("-->") {
                    // Single-line comment
                    i += 1
                } else {
                    // Multi-line comment — scan until -->
                    i += 1
                    while i < lineCount {
                        if lines[i].contains("-->") {
                            i += 1
                            break
                        }
                        i += 1
                    }
                }
                let text = lines[startLine..<i].joined(separator: "\n")
                paragraphs.append(MarkdownParagraph(
                    index: paragraphs.count,
                    text: text,
                    lineRange: (startLine + 1)..<(i + 1),
                    kind: .htmlComment
                ))
                continue
            }

            // Horizontal rule
            if isHorizontalRule(trimmed) {
                paragraphs.append(MarkdownParagraph(
                    index: paragraphs.count,
                    text: trimmed,
                    lineRange: (i + 1)..<(i + 2),
                    kind: .horizontalRule
                ))
                i += 1
                continue
            }

            // Heading
            if let level = headingLevel(trimmed) {
                paragraphs.append(MarkdownParagraph(
                    index: paragraphs.count,
                    text: trimmed,
                    lineRange: (i + 1)..<(i + 2),
                    kind: .heading(level: level)
                ))
                i += 1
                continue
            }

            // Blockquote (contiguous lines starting with >)
            if trimmed.hasPrefix(">") {
                let startLine = i
                while i < lineCount {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || t.hasPrefix(">") {
                        if t.isEmpty { break }
                        i += 1
                    } else {
                        break
                    }
                }
                let text = lines[startLine..<i].joined(separator: "\n")
                paragraphs.append(MarkdownParagraph(
                    index: paragraphs.count,
                    text: text,
                    lineRange: (startLine + 1)..<(i + 1),
                    kind: .blockquote
                ))
                continue
            }

            // List (contiguous lines starting with - , * , + , or N. )
            if isListItem(trimmed) {
                let startLine = i
                while i < lineCount {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { break }
                    // Continue if it's a list item or indented continuation
                    if isListItem(t) || lines[i].hasPrefix("  ") || lines[i].hasPrefix("\t") {
                        i += 1
                    } else {
                        break
                    }
                }
                let text = lines[startLine..<i].joined(separator: "\n")
                paragraphs.append(MarkdownParagraph(
                    index: paragraphs.count,
                    text: text,
                    lineRange: (startLine + 1)..<(i + 1),
                    kind: .list
                ))
                continue
            }

            // Table (lines containing | pipe characters, with a separator row)
            if isTableRow(trimmed) {
                let startLine = i
                while i < lineCount {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { break }
                    if !isTableRow(t) { break }
                    i += 1
                }
                let text = lines[startLine..<i].joined(separator: "\n")
                paragraphs.append(MarkdownParagraph(
                    index: paragraphs.count,
                    text: text,
                    lineRange: (startLine + 1)..<(i + 1),
                    kind: .table
                ))
                continue
            }

            // Body paragraph (contiguous non-blank lines that don't match other types)
            let startLine = i
            while i < lineCount {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                // Stop if we hit a structural element
                if t.hasPrefix("#") && headingLevel(t) != nil { break }
                if t.hasPrefix("```") || t.hasPrefix("~~~") { break }
                if t.hasPrefix(">") { break }
                if isListItem(t) && i > startLine { break }
                if isHorizontalRule(t) { break }
                i += 1
            }
            let text = lines[startLine..<i].joined(separator: "\n")
            paragraphs.append(MarkdownParagraph(
                index: paragraphs.count,
                text: text,
                lineRange: (startLine + 1)..<(i + 1),
                kind: .body
            ))
        }

        return paragraphs
    }

    // MARK: - Helpers

    private static func headingLevel(_ line: String) -> Int? {
        var level = 0
        for ch in line {
            if ch == "#" {
                level += 1
            } else if ch == " " && level > 0 {
                return level <= 6 ? level : nil
            } else {
                return nil
            }
        }
        return nil
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        if stripped.count < 3 { return false }
        let chars = Set(stripped)
        return chars.count == 1 && (chars.contains("-") || chars.contains("*") || chars.contains("_"))
    }

    private static func isTableRow(_ line: String) -> Bool {
        // A table row contains at least one | and is not a horizontal rule
        return line.contains("|") && !isHorizontalRule(line)
    }

    private static func isListItem(_ line: String) -> Bool {
        // Unordered: - , * , +
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return true
        }
        // Ordered: 1. , 2. , etc.
        let pattern = #"^\d+\.\s"#
        return line.range(of: pattern, options: .regularExpression) != nil
    }
}

// MARK: - Markdown Text Stripping

extension MarkdownParagraphParser {

    /// Strip markdown formatting from text for TTS consumption.
    static func stripMarkdown(_ text: String) -> String {
        var result = text

        // Remove HTML comments (single-line and multi-line)
        result = result.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)

        // Remove HTML tags (e.g., <br>, <div>, <img src="...">, </p>, etc.)
        result = result.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)

        // Remove table separator rows (|---|---|)
        result = result.replacingOccurrences(of: #"(?m)^\|?[\s\-:]+(\|[\s\-:]+)+\|?\s*$"#, with: "", options: .regularExpression)

        // Convert table cell separators to periods for natural sentence breaks
        // First strip leading/trailing | on each line
        result = result.replacingOccurrences(of: #"(?m)^\|\s*"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?m)\s*\|$"#, with: ".", options: .regularExpression)
        // Replace remaining | separators with periods
        result = result.replacingOccurrences(of: #"\s*\|\s*"#, with: ". ", options: .regularExpression)

        // Remove heading prefixes
        result = result.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)

        // Remove blockquote prefixes (per line)
        result = result.replacingOccurrences(of: #"(?m)^>\s?"#, with: "", options: .regularExpression)

        // Remove list item prefixes (per line)
        result = result.replacingOccurrences(of: #"(?m)^[\s]*[-*+]\s+"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?m)^[\s]*\d+\.\s+"#, with: "", options: .regularExpression)

        // Remove bold/italic markers
        result = result.replacingOccurrences(of: #"\*\*\*(.+?)\*\*\*"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\*(.+?)\*"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"___(.+?)___"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"__(.+?)__"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"_(.+?)_"#, with: "$1", options: .regularExpression)

        // Remove inline code backticks
        result = result.replacingOccurrences(of: #"`(.+?)`"#, with: "$1", options: .regularExpression)

        // Remove links but keep text: [text](url) → text
        result = result.replacingOccurrences(of: #"\[(.+?)\]\(.+?\)"#, with: "$1", options: .regularExpression)

        // Remove images: ![alt](url) → alt
        result = result.replacingOccurrences(of: #"!\[(.+?)\]\(.+?\)"#, with: "$1", options: .regularExpression)

        // Remove strikethrough
        result = result.replacingOccurrences(of: #"~~(.+?)~~"#, with: "$1", options: .regularExpression)

        // Clean up extra whitespace
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        return result
    }
}
