import Foundation

struct ReplacementsConfig: Codable {
    var textReplacements: [String: String]

    static let empty = ReplacementsConfig(textReplacements: [:])
}

class TextReplacements {
    static let shared = TextReplacements()

    private var config: ReplacementsConfig = .empty

    /// Where `config.json` is looked for, in order. A `Murmur.app` launched
    /// from Finder has cwd "/", so the cwd-only lookup meant user text
    /// replacements silently stopped applying in every bundled build. Same
    /// candidate chain as the `.env` loader in main.swift.
    static var configCandidates: [URL] {
        let fm = FileManager.default
        var urls = [URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("config.json")]
        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent("config.json"))
        }
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            urls.append(appSupport.appendingPathComponent("Murmur/config.json"))
        }
        return urls
    }

    private var configFileURL: URL? {
        Self.configCandidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private init() {
        loadConfig()
    }

    private func loadConfig() {
        guard let configFileURL = configFileURL else {
            let looked = Self.configCandidates.map(\.path).joined(separator: ", ")
            NSLog("TextReplacements: no config.json found (looked in: \(looked))")
            return
        }

        do {
            let data = try Data(contentsOf: configFileURL)
            config = try JSONDecoder().decode(ReplacementsConfig.self, from: data)
            print("Loaded \(config.textReplacements.count) text replacements")
        } catch {
            print("Failed to load config: \(error)")
        }
    }

    /// Reloads config from disk (call this if you want hot-reload)
    func reloadConfig() {
        loadConfig()
    }

    /// Process text: apply replacements, strip enclosing quotes, and clean formatting
    func processText(_ text: String) -> String {
        var result = text
        for (find, replace) in config.textReplacements {
            result = result.replacingOccurrences(of: find, with: replace)
        }

        // Remove enclosing quotation marks if the entire string is wrapped in them
        result = stripEnclosingQuotes(result)

        // Clean up bullet point formatting (leading hyphens and continuation spaces)
        result = cleanBulletFormatting(result)

        return result
    }

    /// Removes leading hyphens and continuation line spaces from transcription output
    private func cleanBulletFormatting(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")

        for i in 0..<lines.count {
            var line = lines[i]

            // Remove leading "- " (hyphen followed by space) from lines
            if line.hasPrefix("- ") {
                line = String(line.dropFirst(2))
            }

            // Remove single leading space (continuation line formatting)
            if line.hasPrefix(" ") && !line.hasPrefix("  ") {
                line = String(line.dropFirst(1))
            }

            lines[i] = line
        }

        return lines.joined(separator: "\n")
    }

    /// Removes quotation marks if they enclose the entire string
    private func stripEnclosingQuotes(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        // Check for various quote pairs
        let quotePairs: [(String, String)] = [
            ("\"", "\""),           // straight double quotes
            ("'", "'"),             // straight single quotes
            ("\u{201C}", "\u{201D}"), // curly double quotes " "
            ("\u{2018}", "\u{2019}"), // curly single quotes ' '
        ]

        for (open, close) in quotePairs {
            if trimmed.hasPrefix(open) && trimmed.hasSuffix(close) && trimmed.count > open.count + close.count {
                let startIndex = trimmed.index(trimmed.startIndex, offsetBy: open.count)
                let endIndex = trimmed.index(trimmed.endIndex, offsetBy: -close.count)
                return String(trimmed[startIndex..<endIndex])
            }
        }

        return text
    }
}
