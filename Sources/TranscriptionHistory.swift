import Foundation

/// Kind of history entry. Pre-existing entries without this field are treated
/// as plain transcripts for backward compatibility.
enum HistoryEntryKind: String, Codable {
    case transcript   // STT / OpenClaw / audio transcription
    case podcast      // podcast session with script markdown + audio WAV
    case recap        // Claude Code assistant final message via Stop hook
    case permission   // Claude Code tool permission auto-approval
}

struct TranscriptionEntry: Codable {
    let id: UUID
    let text: String
    let timestamp: Date
    let kind: HistoryEntryKind
    let title: String?
    /// Filename (not path) of the audio file within
    /// TranscriptionHistory.audioDirectory. nil for transcript entries.
    let audioFilename: String?
    /// For recap entries only: the LLM-rewritten version that was actually
    /// spoken. `text` always holds the raw assistant message.
    let spokenText: String?

    enum CodingKeys: String, CodingKey {
        case id, text, timestamp, kind, title, audioFilename, spokenText
    }

    init(text: String) {
        self.id = UUID()
        self.text = text
        self.timestamp = Date()
        self.kind = .transcript
        self.title = nil
        self.audioFilename = nil
        self.spokenText = nil
    }

    init(podcastTitle: String, markdown: String, audioFilename: String?) {
        self.id = UUID()
        self.text = markdown
        self.timestamp = Date()
        self.kind = .podcast
        self.title = podcastTitle
        self.audioFilename = audioFilename
        self.spokenText = nil
    }

    init(recap: String, spokenText: String? = nil) {
        self.id = UUID()
        self.text = recap
        self.timestamp = Date()
        self.kind = .recap
        self.title = nil
        self.audioFilename = nil
        self.spokenText = spokenText
    }

    /// Auto-approved Claude Code tool call. `title` holds the tool name
    /// (e.g., "Bash"), `text` holds a human-readable preview of the tool
    /// input (e.g., the command).
    init(permissionTool toolName: String, inputPreview: String) {
        self.id = UUID()
        self.text = inputPreview
        self.timestamp = Date()
        self.kind = .permission
        self.title = toolName
        self.audioFilename = nil
        self.spokenText = nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        kind = try c.decodeIfPresent(HistoryEntryKind.self, forKey: .kind) ?? .transcript
        title = try c.decodeIfPresent(String.self, forKey: .title)
        audioFilename = try c.decodeIfPresent(String.self, forKey: .audioFilename)
        spokenText = try c.decodeIfPresent(String.self, forKey: .spokenText)
    }
}

class TranscriptionHistory {
    static let shared = TranscriptionHistory()
    // No entry count cap — user keeps everything until they explicitly clear
    // or delete. Podcast audio files live on disk so large counts will grow
    // the docs dir proportionally.
    private var entries: [TranscriptionEntry] = []

    private var historyFileURL: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let appSupportDir = documentsPath.appendingPathComponent("Murmur", isDirectory: true)

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

        return appSupportDir.appendingPathComponent("transcription_history.json")
    }

    /// Directory where podcast audio WAVs are persisted, one per entry.
    var audioDirectory: URL {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = documentsPath
            .appendingPathComponent("Murmur", isDirectory: true)
            .appendingPathComponent("podcast_audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        loadHistory()
    }

    private func loadHistory() {
        guard FileManager.default.fileExists(atPath: historyFileURL.path) else {
            print("No history file found")
            return
        }

        do {
            let data = try Data(contentsOf: historyFileURL)
            entries = try JSONDecoder().decode([TranscriptionEntry].self, from: data)
            print("Loaded \(entries.count) history entries")
        } catch {
            print("Failed to load history: \(error)")
        }
    }

    private func saveHistory() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: historyFileURL)
        } catch {
            print("Failed to save history: \(error)")
        }
    }

    func addEntry(_ text: String) {
        let entry = TranscriptionEntry(text: text)
        insertEntry(entry)
        print("Added transcription to history: \(text)")
    }

    func addRecapEntry(_ text: String, spokenText: String? = nil) {
        let entry = TranscriptionEntry(recap: text, spokenText: spokenText)
        insertEntry(entry)
        print("Added Claude recap to history (\(text.count) chars, spoken=\(spokenText?.count ?? 0) chars)")
    }

    func addPermissionEntry(toolName: String, inputPreview: String) {
        let entry = TranscriptionEntry(permissionTool: toolName, inputPreview: inputPreview)
        insertEntry(entry)
        print("Added permission auto-approval to history: \(toolName) — \(inputPreview.prefix(80))")
    }

    /// Record a completed podcast. Persists audio WAV alongside the markdown
    /// script so the user can recover both after closing the overlay.
    /// If audio can't be written, the entry still gets saved without it.
    @discardableResult
    func addPodcastEntry(title: String, markdown: String, audioData: Data?) -> TranscriptionEntry {
        var audioFilename: String? = nil
        if let audioData = audioData, !audioData.isEmpty {
            let filename = "podcast_\(UUID().uuidString).wav"
            let url = audioDirectory.appendingPathComponent(filename)
            do {
                try audioData.write(to: url)
                audioFilename = filename
                print("Saved podcast audio: \(filename) (\(audioData.count) bytes)")
            } catch {
                print("Failed to save podcast audio: \(error)")
            }
        }

        let entry = TranscriptionEntry(
            podcastTitle: title,
            markdown: markdown,
            audioFilename: audioFilename
        )
        insertEntry(entry)
        print("Added podcast to history: \(title)")
        return entry
    }

    private func insertEntry(_ entry: TranscriptionEntry) {
        entries.insert(entry, at: 0)
        saveHistory()
    }

    func getEntries() -> [TranscriptionEntry] {
        return entries
    }

    func audioURL(for entry: TranscriptionEntry) -> URL? {
        guard let filename = entry.audioFilename else { return nil }
        let url = audioDirectory.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func clearHistory() {
        for entry in entries {
            removeAudioFile(for: entry)
        }
        entries.removeAll()
        saveHistory()
    }

    func deleteEntry(at index: Int) {
        guard index >= 0 && index < entries.count else { return }
        let removed = entries.remove(at: index)
        removeAudioFile(for: removed)
        saveHistory()
    }

    private func removeAudioFile(for entry: TranscriptionEntry) {
        guard let filename = entry.audioFilename else { return }
        let url = audioDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }
}
