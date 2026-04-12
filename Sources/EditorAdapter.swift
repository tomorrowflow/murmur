import Foundation
import AppKit

// MARK: - Editor Adapter Protocol

protocol EditorAdapter {
    var editorName: String { get }

    /// Navigate the editor to show the given line.
    func navigateToLine(_ line: Int, column: Int) async

    /// Highlight a range of lines in the editor with a persistent background color.
    func highlightLines(file: String, from startLine: Int, to endLine: Int) async

    /// Remove all highlights from the file.
    func clearHighlight(file: String) async

    /// Trigger the editor to reload the current file from disk.
    func reloadFile(path: String) async

    /// Check if the editor is running.
    func isRunning() -> Bool
}

extension EditorAdapter {
    func navigateToLine(_ line: Int) async {
        await navigateToLine(line, column: 1)
    }
}

// MARK: - TextMate Adapter

class TextMateAdapter: EditorAdapter {
    let editorName = "TextMate"

    private let bundleIdentifier = "com.macromates.TextMate"
    private static let matePath = "/Applications/TextMate.app/Contents/MacOS/mate"

    /// Zero-width space used as an invisible line marker for the Murmur grammar injection.
    /// The Murmur.tmbundle grammar matches lines ending with this character and applies
    /// the `markup.inserted.murmur` scope, which gets a green background from the Diff bundle.
    private static let marker = "\u{200B}"

    func navigateToLine(_ line: Int, column: Int = 1) async {
        let urlString = "txmt://open?line=\(line)&column=\(column)"
        guard let url = URL(string: urlString) else { return }
        await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }

    /// Highlight lines by appending an invisible zero-width space marker to each line.
    /// The Murmur.tmbundle injection grammar matches these and applies a background color.
    func highlightLines(file: String, from startLine: Int, to endLine: Int) async {
        do {
            var content = try String(contentsOfFile: file, encoding: .utf8)

            // First remove any existing markers
            content = content.replacingOccurrences(of: TextMateAdapter.marker, with: "")

            // Split into lines, add marker to target lines
            var lines = content.components(separatedBy: "\n")
            for i in (startLine - 1)..<min(endLine - 1, lines.count) {
                let line = lines[i]
                // Only mark non-empty lines
                if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    lines[i] = line + TextMateAdapter.marker
                }
            }

            let newContent = lines.joined(separator: "\n")
            try newContent.write(toFile: file, atomically: true, encoding: .utf8)

            // Scroll to the paragraph
            await navigateToLine(startLine)
        } catch {
            NSLog("[TextMateAdapter] highlightLines failed: \(error)")
        }
    }

    /// Remove all zero-width space markers from the file.
    func clearHighlight(file: String) async {
        do {
            let content = try String(contentsOfFile: file, encoding: .utf8)
            let cleaned = content.replacingOccurrences(of: TextMateAdapter.marker, with: "")
            if cleaned != content {
                try cleaned.write(toFile: file, atomically: true, encoding: .utf8)
            }
        } catch {
            NSLog("[TextMateAdapter] clearHighlight failed: \(error)")
        }
    }

    func reloadFile(path: String) async {
        guard let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        let urlString = "txmt://open?url=file://\(encodedPath)"
        guard let url = URL(string: urlString) else { return }
        await MainActor.run {
            NSWorkspace.shared.open(url)
        }
        // Small delay for TextMate to process the reload
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    func isRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleIdentifier
        }
    }

    /// Get the current cursor line number in TextMate via the Accessibility API.
    /// Reads the focused text element's selected text range and counts newlines to determine the line.
    static func getCursorLine() -> Int? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
              let element = focusedElement else {
            NSLog("[TextMateAdapter] Failed to get focused element")
            return nil
        }

        let axElement = element as! AXUIElement

        // Get the selected text range (gives us the cursor position as a character offset)
        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success else {
            NSLog("[TextMateAdapter] Failed to get selected text range")
            return nil
        }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else {
            NSLog("[TextMateAdapter] Failed to extract CFRange")
            return nil
        }

        let cursorOffset = range.location

        // Get the full text content to count newlines up to the cursor
        var textValue: AnyObject?
        guard AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &textValue) == .success,
              let fullText = textValue as? String else {
            NSLog("[TextMateAdapter] Failed to get text value")
            return nil
        }

        // Count newlines before cursor offset to determine line number (1-based)
        let prefixEnd = fullText.index(fullText.startIndex, offsetBy: min(cursorOffset, fullText.count))
        let prefix = fullText[fullText.startIndex..<prefixEnd]
        let lineNumber = prefix.filter { $0 == "\n" }.count + 1

        NSLog("[TextMateAdapter] Cursor at offset \(cursorOffset) → line \(lineNumber)")
        return lineNumber
    }

    /// Get the file path of a markdown file open in TextMate.
    static func frontDocumentPath() async -> String? {
        if let path = await findOpenMarkdownViaLsof() {
            return path
        }
        if let path = await findMarkdownFromWindowTitles() {
            return path
        }
        return nil
    }

    private static func findOpenMarkdownViaLsof() async -> String? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let apps = NSWorkspace.shared.runningApplications.filter {
                    $0.bundleIdentifier == "com.macromates.TextMate"
                }
                guard let pid = apps.first?.processIdentifier else {
                    continuation.resume(returning: nil)
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
                process.arguments = ["-p", "\(pid)", "-Fn"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let output = String(data: data, encoding: .utf8) else {
                    continuation.resume(returning: nil)
                    return
                }

                let mdFiles = output.components(separatedBy: "\n")
                    .filter { $0.hasPrefix("n/") }
                    .map { String($0.dropFirst()) }
                    .filter { $0.hasSuffix(".md") || $0.hasSuffix(".markdown") }
                    .filter { !$0.contains("/Library/Caches/") && !$0.contains("/.") }

                let sorted = mdFiles.sorted { a, b in
                    let dateA = (try? FileManager.default.attributesOfItem(atPath: a)[.modificationDate] as? Date) ?? .distantPast
                    let dateB = (try? FileManager.default.attributesOfItem(atPath: b)[.modificationDate] as? Date) ?? .distantPast
                    return dateA > dateB
                }

                continuation.resume(returning: sorted.first)
            }
        }
    }

    private static func findMarkdownFromWindowTitles() async -> String? {
        let script = """
        tell application "TextMate"
            set windowNames to name of every window
            set output to ""
            repeat with wName in windowNames
                set output to output & wName & linefeed
            end repeat
            return output
        end tell
        """

        guard let output = await runAppleScript(script) else { return nil }

        let lines = output.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasSuffix(".md") || trimmed.contains(".md ") ||
                  trimmed.hasSuffix(".markdown") || trimmed.contains(".markdown ") else {
                continue
            }

            let parts = trimmed.components(separatedBy: " — ")
            guard let filename = parts.first, !filename.isEmpty else { continue }

            let findProcess = Process()
            findProcess.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            findProcess.arguments = ["-name", filename]
            let pipe = Pipe()
            findProcess.standardOutput = pipe
            findProcess.standardError = FileHandle.nullDevice

            do {
                try findProcess.run()
                findProcess.waitUntilExit()
            } catch {
                continue
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let paths = String(data: data, encoding: .utf8) else { continue }

            let parentFolder = parts.count > 1 ? parts[1].components(separatedBy: " (").first?.trimmingCharacters(in: .whitespaces) : nil

            for path in paths.components(separatedBy: "\n") {
                let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !p.isEmpty, p.hasSuffix(filename) else { continue }
                if let parent = parentFolder {
                    if (p as NSString).deletingLastPathComponent.hasSuffix(parent) {
                        return p
                    }
                } else {
                    return p
                }
            }
        }

        return nil
    }

    private static func runAppleScript(_ source: String) async -> String? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let appleScript = NSAppleScript(source: source)
                var errorInfo: NSDictionary?
                let result = appleScript?.executeAndReturnError(&errorInfo)
                if let error = errorInfo {
                    NSLog("[TextMateAdapter] AppleScript error: \(error)")
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: result?.stringValue)
                }
            }
        }
    }
}

// MARK: - Obsidian Adapter

class ObsidianAdapter: EditorAdapter {
    let editorName = "Obsidian"

    private let bundleIdentifier = "md.obsidian"
    private static let companionBase = "http://127.0.0.1:27125"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 2
        return URLSession(configuration: config)
    }()

    func navigateToLine(_ line: Int, column: Int = 1) async {
        let _ = await Self.postCompanion("/navigate", body: ["line": line])
    }

    func highlightLines(file: String, from startLine: Int, to endLine: Int) async {
        let _ = await Self.postCompanion("/highlight", body: [
            "startLine": startLine,
            "endLine": endLine
        ])
    }

    func clearHighlight(file: String) async {
        let _ = await Self.postCompanion("/clear-highlight", body: [:])
    }

    func reloadFile(path: String) async {
        // Obsidian auto-reloads files from disk — just wait briefly
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    func isRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "md.obsidian"
        }
    }

    /// Get cursor line and file path in one async call (avoids main-thread deadlock).
    static func getCursorAndFile() async -> (line: Int?, file: String?)? {
        guard let data = await getCompanion("/cursor") else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let line = json["line"] as? Int
        let file = json["file"] as? String
        return (line, file)
    }

    /// Get the current cursor line from the companion plugin.
    static func getCursorLine() -> Int? {
        guard let data = getCompanionSync("/cursor") else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let line = json["line"] as? Int else { return nil }
        return line
    }

    /// Get the absolute file path of the active document from the companion plugin.
    static func frontDocumentPath() async -> String? {
        guard let data = await getCompanion("/cursor") else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let file = json["file"] as? String, !file.isEmpty else { return nil }
        return file
    }

    /// Check if the companion plugin is reachable.
    static func isCompanionRunning() -> Bool {
        return getCompanionSync("/cursor") != nil
    }

    // MARK: - HTTP Helpers

    private static func postCompanion(_ path: String, body: [String: Any]) async -> Data? {
        guard let url = URL(string: "\(companionBase)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await session.data(for: request)
            return data
        } catch {
            NSLog("[ObsidianAdapter] POST \(path) failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func getCompanion(_ path: String) async -> Data? {
        guard let url = URL(string: "\(companionBase)\(path)") else { return nil }
        do {
            let (data, _) = try await session.data(for: URLRequest(url: url))
            return data
        } catch {
            NSLog("[ObsidianAdapter] GET \(path) failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Synchronous GET for use in getCursorLine() (called from main thread before async work).
    private static func getCompanionSync(_ path: String) -> Data? {
        guard let url = URL(string: "\(companionBase)\(path)") else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?

        let task = URLSession.shared.dataTask(with: URLRequest(url: url)) { data, _, _ in
            result = data
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 1.0)
        return result
    }
}
