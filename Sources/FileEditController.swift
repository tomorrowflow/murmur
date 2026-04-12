import Foundation

struct FileEditController {

    enum EditError: Error, LocalizedError {
        case fileNotFound(String)
        case fileModifiedExternally
        case paragraphOutOfRange
        case writeError(String)

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let path): return "File not found: \(path)"
            case .fileModifiedExternally: return "File was modified externally since last read"
            case .paragraphOutOfRange: return "Paragraph line range is out of bounds"
            case .writeError(let msg): return "Write error: \(msg)"
            }
        }
    }

    /// Replace a paragraph's lines in the file and return the updated content.
    /// - Parameters:
    ///   - filePath: Path to the file
    ///   - lineRange: 1-based half-open range of lines to replace
    ///   - newText: Replacement text (may contain newlines)
    ///   - expectedModDate: If provided, verify file hasn't changed since this date
    /// - Returns: The new full file content after replacement
    static func replaceParagraph(
        in filePath: String,
        lineRange: Range<Int>,
        with newText: String,
        expectedModDate: Date? = nil
    ) throws -> String {
        guard FileManager.default.fileExists(atPath: filePath) else {
            throw EditError.fileNotFound(filePath)
        }

        // Check for external modifications
        if let expectedDate = expectedModDate {
            let attrs = try FileManager.default.attributesOfItem(atPath: filePath)
            if let currentDate = attrs[.modificationDate] as? Date {
                if currentDate.timeIntervalSince(expectedDate) > 0.5 {
                    throw EditError.fileModifiedExternally
                }
            }
        }

        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        var lines = content.components(separatedBy: "\n")

        // Convert 1-based half-open range to 0-based
        let start = lineRange.lowerBound - 1
        let end = lineRange.upperBound - 1

        guard start >= 0 && end <= lines.count else {
            throw EditError.paragraphOutOfRange
        }

        // Split new text into lines
        let newLines = newText.components(separatedBy: "\n")

        // Replace the range
        lines.replaceSubrange(start..<end, with: newLines)

        let newContent = lines.joined(separator: "\n")

        // Atomic write
        try atomicWrite(content: newContent, to: filePath)

        return newContent
    }

    /// Atomically write content to a file.
    static func atomicWrite(content: String, to filePath: String) throws {
        let url = URL(fileURLWithPath: filePath)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw EditError.writeError(error.localizedDescription)
        }
    }

    /// Check if a file has been modified since the given date.
    static func hasBeenModified(filePath: String, since date: Date) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
              let modDate = attrs[.modificationDate] as? Date else {
            return true  // Assume modified if we can't check
        }
        return modDate.timeIntervalSince(date) > 0.5
    }
}
