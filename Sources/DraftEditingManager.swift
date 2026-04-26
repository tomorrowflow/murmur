import Foundation
import AVFoundation
import AppKit
import SharedModels

// MARK: - Protocol

protocol DraftEditingManagerDelegate: AnyObject {
    func draftDidChangeState(_ state: DraftEditingState)
    func draftDidLoadDocument(_ document: MarkdownDocument)
    func draftDidActivateParagraph(index: Int, paragraph: MarkdownParagraph)
    func draftDidActivateSegment(_ segment: TTSSegment, inParagraph index: Int)
    func draftDidCompleteEdit(paragraphIndex: Int, original: String, replacement: String)
    func draftDidUpdateStreamingEdit(_ text: String)
    func draftDidError(_ message: String)
}

// MARK: - State

enum DraftEditingState: Equatable {
    case idle
    case loading
    case reading
    case paused
    case listening
    case processingEdit
    case applyingEdit
    case complete
    case error(String)

    var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .loading: return "Loading"
        case .reading: return "Reading"
        case .paused: return "Paused"
        case .listening: return "Listening"
        case .processingEdit: return "Rewriting"
        case .applyingEdit: return "Applying"
        case .complete: return "Complete"
        case .error: return "Error"
        }
    }
}

// MARK: - Edit History Entry

struct DraftEditEntry {
    let paragraphIndex: Int
    let original: String
    let replacement: String
    let instruction: String
    let timestamp: Date
}

// MARK: - DraftEditingManager

class DraftEditingManager {
    weak var delegate: DraftEditingManagerDelegate?

    private(set) var state: DraftEditingState = .idle {
        didSet {
            if state != oldValue {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.draftDidChangeState(self.state)
                }
            }
        }
    }

    var isActive: Bool {
        switch state {
        case .idle, .complete, .error: return false
        default: return true
        }
    }

    // Document
    private(set) var document: MarkdownDocument?
    private(set) var currentParagraphIndex: Int = 0
    let sessionId = UUID()

    // Playback
    private var readingTask: Task<Void, Never>?
    private var editTask: Task<Void, Never>?
    private(set) var isPaused: Bool = false
    private var currentPlayer: AVAudioPlayer?
    private var hasPrimedBluetoothOutput = false

    // Edit history
    private(set) var editHistory: [DraftEditEntry] = []
    private var streamingEditText: String = ""

    // TTS cue cache: avoid re-synthesizing the same short cues
    private var cueAudioCache: [String: Data] = [:]

    // Audio collection for export
    private(set) var audioSegments: [Data] = []

    // Editor
    private var editorAdapter: EditorAdapter?

    // Escape key monitors
    private var escapeGlobalMonitor: Any?
    private var escapeLocalMonitor: Any?

    // Ollama
    private let ollamaClient = OllamaClient()

    // MARK: - Public API

    func startSession(filePath: String, adapter: EditorAdapter, startLine: Int? = nil) {
        guard !isActive else {
            NSLog("[DraftEdit] Session already active")
            return
        }

        reset()
        editorAdapter = adapter
        state = .loading

        readingTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let doc = try MarkdownParagraphParser.parse(filePath: filePath)
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    self.document = doc
                    self.delegate?.draftDidLoadDocument(doc)
                }

                let readableParagraphs = doc.paragraphs.filter { $0.kind != .frontmatter }
                guard !readableParagraphs.isEmpty else {
                    await MainActor.run {
                        self.state = .error("No readable paragraphs found")
                        self.delegate?.draftDidError("No readable paragraphs found")
                    }
                    return
                }

                // Resolve start position from cursor line
                var startIndex = 0
                if let line = startLine, let idx = doc.paragraphIndex(containingLine: line) {
                    startIndex = idx
                    NSLog("[DraftEdit] Starting from cursor line \(line) → paragraph \(idx)")
                }

                NSLog("[DraftEdit] Session started: \(doc.paragraphs.count) paragraphs in \(filePath)")
                await MainActor.run {
                    self.state = .reading
                    self.installEscapeMonitor()
                }
                await self.readParagraphs(fromIndex: startIndex)
            } catch {
                await MainActor.run {
                    self.state = .error(error.localizedDescription)
                    self.delegate?.draftDidError(error.localizedDescription)
                }
            }
        }
    }

    func stop() {
        NSLog("[DraftEdit] Stopping session")
        removeEscapeMonitor()
        // Cancel tasks — playWavData's defer handles player cleanup safely
        readingTask?.cancel()
        editTask?.cancel()
        readingTask = nil
        editTask = nil
        // Clean up highlight markers from the file
        if let doc = document {
            Task { await editorAdapter?.clearHighlight(file: doc.filePath) }
        }
        reset()
    }

    func togglePause() {
        if isPaused {
            NSLog("[DraftEdit] Resuming")
            isPaused = false
        } else {
            guard state == .reading else { return }
            NSLog("[DraftEdit] Pausing")
            isPaused = true
        }
    }

    func nextParagraph() {
        guard let doc = document else { return }
        let next = currentParagraphIndex + 1
        guard next < doc.paragraphs.count else { return }
        navigateTo(paragraph: next)
    }

    func prevParagraph() {
        let prev = currentParagraphIndex - 1
        guard prev >= 0 else { return }
        navigateTo(paragraph: prev)
    }

    func navigateTo(paragraph index: Int) {
        guard let doc = document, index >= 0, index < doc.paragraphs.count else { return }
        NSLog("[DraftEdit] Navigating to paragraph \(index)")

        // Cancel current playback — playWavData's defer handles player cleanup
        readingTask?.cancel()
        readingTask = nil
        isPaused = false

        currentParagraphIndex = index
        state = .reading

        readingTask = Task { [weak self] in
            await self?.readParagraphs(fromIndex: index)
        }
    }

    func jumpToCursorLine(_ line: Int) {
        guard let doc = document, let index = doc.paragraphIndex(containingLine: line) else { return }
        navigateTo(paragraph: index)
    }

    // MARK: - Edit Interrupt

    func beginEditInterrupt() {
        guard isActive else { return }
        NSLog("[DraftEdit] Edit interrupt started at paragraph \(currentParagraphIndex)")
        isPaused = false
        // Cancel reading task — playWavData's defer handles player cleanup
        readingTask?.cancel()
        readingTask = nil
        state = .listening
    }

    func cancelEditInterrupt() {
        guard state == .listening else { return }
        NSLog("[DraftEdit] Edit interrupt cancelled, resuming")
        resumeReading()
    }

    func applyEdit(instruction: String) {
        guard state == .listening, let doc = document else { return }
        let paragraphIndex = currentParagraphIndex
        guard paragraphIndex < doc.paragraphs.count else { return }

        let paragraph = doc.paragraphs[paragraphIndex]
        NSLog("[DraftEdit] Applying edit to paragraph \(paragraphIndex): \"\(instruction)\"")

        streamingEditText = ""
        state = .processingEdit

        editTask = Task { [weak self] in
            guard let self = self else { return }
            await self.processEdit(
                paragraph: paragraph,
                instruction: instruction,
                paragraphIndex: paragraphIndex
            )
        }
    }

    /// Undo a specific edit by index in the edit history.
    func undoEdit(historyIndex: Int) {
        guard historyIndex < editHistory.count, let doc = document else { return }
        let entry = editHistory[historyIndex]

        // Find the paragraph — it may have shifted due to later edits
        let paragraph = doc.paragraphs[entry.paragraphIndex]
        NSLog("[DraftEdit] Undoing edit at paragraph \(entry.paragraphIndex)")

        state = .applyingEdit
        editTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                // Clear highlights first, then re-parse for clean line ranges
                await self.editorAdapter?.clearHighlight(file: doc.filePath)
                let cleanDoc = try MarkdownParagraphParser.parse(filePath: doc.filePath)
                let cleanParagraph = cleanDoc.paragraphs[entry.paragraphIndex]

                let _ = try FileEditController.replaceParagraph(
                    in: doc.filePath,
                    lineRange: cleanParagraph.lineRange,
                    with: entry.original,
                    expectedModDate: cleanDoc.modificationDate
                )

                // Re-parse after edit
                let newDoc = try MarkdownParagraphParser.parse(filePath: doc.filePath)
                await MainActor.run {
                    self.document = newDoc
                    self.delegate?.draftDidLoadDocument(newDoc)
                    self.editHistory.remove(at: historyIndex)
                }

                // Reload editor
                await self.editorAdapter?.reloadFile(path: doc.filePath)
                await self.editorAdapter?.navigateToLine(paragraph.lineRange.lowerBound)

                await MainActor.run { self.resumeReading() }
            } catch {
                await MainActor.run {
                    self.state = .error(error.localizedDescription)
                    self.delegate?.draftDidError(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Paragraph Reading

    private func readParagraphs(fromIndex startIndex: Int) async {
        guard let doc = document else { return }

        for i in startIndex..<doc.paragraphs.count {
            guard !Task.isCancelled else { return }

            let paragraph = doc.paragraphs[i]

            // Skip front matter, HTML comments, and horizontal rules
            if paragraph.kind == .frontmatter || paragraph.kind == .htmlComment || paragraph.kind == .horizontalRule { continue }

            // Render paragraph into TTS segments
            let segments = MarkdownTTSRenderer.render(paragraph)
            var hasActivatedParagraph = false

            for segment in segments {
                guard !Task.isCancelled else { return }

                // Only update current paragraph index when we reach actual content
                // This prevents the index from advancing during pre-silence gaps
                switch segment {
                case .spokenCue, .content:
                    if !hasActivatedParagraph {
                        hasActivatedParagraph = true
                        await MainActor.run {
                            self.currentParagraphIndex = i
                            self.delegate?.draftDidActivateParagraph(index: i, paragraph: paragraph)
                        }
                        if let doc = document {
                            Task {
                                // Single mate call: highlights paragraph and scrolls to it
                                await editorAdapter?.highlightLines(
                                    file: doc.filePath,
                                    from: paragraph.lineRange.lowerBound,
                                    to: paragraph.lineRange.upperBound
                                )
                            }
                        }
                    }
                default:
                    break
                }

                await MainActor.run {
                    self.delegate?.draftDidActivateSegment(segment, inParagraph: i)
                }

                switch segment {
                case .silence(let durationMs):
                    // Wait for silence duration, respecting pause
                    let silenceData = MarkdownTTSRenderer.generateSilenceWav(durationMs: durationMs)
                    do { try await playWavData(silenceData) } catch { return }

                case .spokenCue(let text):
                    guard let audio = await synthesizeCue(text) else { continue }
                    do { try await playWavData(audio) } catch { return }

                case .content(let text, let speed):
                    // Split into sentences for natural reading
                    let sentences = SmartSentenceSplitter.splitIntoSentences(text)
                    var pendingAudio: Data? = nil

                    for (j, sentence) in sentences.enumerated() {
                        guard !Task.isCancelled else { return }

                        let currentAudio: Data?
                        if let presynth = pendingAudio {
                            currentAudio = presynth
                            pendingAudio = nil
                        } else {
                            currentAudio = await synthesizeSentence(sentence, speed: speed)
                        }

                        guard let audioData = currentAudio else { continue }

                        // Pre-synthesize next sentence
                        if j + 1 < sentences.count {
                            async let nextAudio = synthesizeSentence(sentences[j + 1], speed: speed)
                            do { try await playWavData(audioData) } catch { return }
                            pendingAudio = try? await nextAudio
                        } else {
                            do { try await playWavData(audioData) } catch { return }
                        }

                        // Inter-sentence silence
                        if j < sentences.count - 1 {
                            let gap = MarkdownTTSRenderer.generateSilenceWav(
                                durationMs: MarkdownTTSRenderer.sentenceGapMs
                            )
                            do { try await playWavData(gap) } catch { return }
                        }
                    }
                }
            }
        }

        guard !Task.isCancelled else { return }
        // Clear highlights when reading completes
        if let doc = document {
            await editorAdapter?.clearHighlight(file: doc.filePath)
        }
        await MainActor.run {
            self.state = .complete
        }
    }

    private func resumeReading() {
        // Cancel any existing reading task — the poll loop in playWavData
        // will detect cancellation and clean up the player safely
        readingTask?.cancel()
        readingTask = nil

        state = .reading
        let resumeIndex = currentParagraphIndex
        NSLog("[DraftEdit] Resuming from paragraph \(resumeIndex)")

        readingTask = Task { [weak self] in
            await self?.readParagraphs(fromIndex: resumeIndex)
        }
    }

    // MARK: - Edit Processing

    private func processEdit(paragraph: MarkdownParagraph, instruction: String, paragraphIndex: Int) async {
        do {
            let systemPrompt = """
            You are a writing assistant helping edit a markdown document. The user will give you \
            a paragraph and an editing instruction. Output ONLY the rewritten paragraph. \
            Preserve markdown formatting (headings, lists, bold, etc.). Do not add explanations, \
            commentary, or anything besides the rewritten text.
            """

            let userMessage = """
            ## Paragraph:
            \(paragraph.text)

            ## Instruction:
            \(instruction)
            """

            NSLog("[DraftEdit] Sending edit request to LLM (\(userMessage.count) chars)")

            var fullResponse = ""
            for try await token in ollamaClient.streamChat(system: systemPrompt, user: userMessage) {
                guard !Task.isCancelled else { return }
                fullResponse += token
                let stripped = OllamaClient.stripThinkBlocks(fullResponse)

                await MainActor.run {
                    self.streamingEditText = stripped
                    self.delegate?.draftDidUpdateStreamingEdit(stripped)
                }
            }

            guard !Task.isCancelled else { return }

            let finalText = OllamaClient.stripThinkBlocks(fullResponse).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !finalText.isEmpty else {
                await MainActor.run {
                    self.state = .error("LLM returned empty response")
                    self.delegate?.draftDidError("LLM returned empty response")
                }
                return
            }

            // Apply edit to file
            await MainActor.run { self.state = .applyingEdit }

            guard let doc = self.document else { return }

            // 1. Clear highlight markers first — they modify the file, which
            //    would cause the mod-date check to fail
            await editorAdapter?.clearHighlight(file: doc.filePath)

            // 2. Re-parse the now-clean file to get correct line ranges
            let cleanDoc = try MarkdownParagraphParser.parse(filePath: doc.filePath)
            let cleanParagraph = cleanDoc.paragraphs[paragraphIndex]

            // 3. Apply the edit to the clean file
            let _ = try FileEditController.replaceParagraph(
                in: doc.filePath,
                lineRange: cleanParagraph.lineRange,
                with: finalText,
                expectedModDate: cleanDoc.modificationDate
            )

            // Re-parse document after edit
            let newDoc = try MarkdownParagraphParser.parse(filePath: doc.filePath)

            await MainActor.run {
                self.document = newDoc

                let entry = DraftEditEntry(
                    paragraphIndex: paragraphIndex,
                    original: paragraph.text,
                    replacement: finalText,
                    instruction: instruction,
                    timestamp: Date()
                )
                self.editHistory.append(entry)

                self.delegate?.draftDidCompleteEdit(
                    paragraphIndex: paragraphIndex,
                    original: paragraph.text,
                    replacement: finalText
                )
                self.delegate?.draftDidLoadDocument(newDoc)
                self.streamingEditText = ""
            }

            // Reload editor and navigate
            await editorAdapter?.reloadFile(path: doc.filePath)
            await editorAdapter?.navigateToLine(paragraph.lineRange.lowerBound)

            NSLog("[DraftEdit] Edit applied successfully")

            // Resume reading from the edited paragraph
            await MainActor.run { self.resumeReading() }

        } catch is CancellationError {
            return
        } catch {
            NSLog("[DraftEdit] Edit failed: \(error)")
            await MainActor.run {
                self.state = .error(error.localizedDescription)
                self.delegate?.draftDidError(error.localizedDescription)
            }
        }
    }

    // MARK: - Audio Export

    /// Combined WAV audio data from all segments for export.
    func combinedAudioData() -> Data? {
        guard !audioSegments.isEmpty else { return nil }
        guard audioSegments[0].count > 44 else { return nil }

        var pcmData = Data()
        for segment in audioSegments {
            guard segment.count > 44 else { continue }
            pcmData.append(segment[44...])
        }

        var header = audioSegments[0][0..<44]
        let totalSize = UInt32(pcmData.count + 36)
        let dataSize = UInt32(pcmData.count)
        header.replaceSubrange(4..<8, with: withUnsafeBytes(of: totalSize.littleEndian) { Data($0) })
        header.replaceSubrange(40..<44, with: withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })

        return header + pcmData
    }

    // MARK: - Audio Synthesis & Playback

    private func synthesizeSentence(_ text: String, speed: Float) async -> Data? {
        let ttsManager = await MainActor.run { ModelStateManager.shared.loadedTtsManager }
        guard let ttsManager = ttsManager else {
            NSLog("[DraftEdit] Kokoro not loaded")
            return nil
        }
        do {
            let audioData = try await ttsManager.synthesize(text: text, voiceSpeed: speed)
            try Task.checkCancellation()
            return audioData
        } catch is CancellationError {
            return nil
        } catch {
            NSLog("[DraftEdit] Synthesis failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func synthesizeCue(_ text: String) async -> Data? {
        // Check cache first
        if let cached = cueAudioCache[text] {
            NSLog("[DraftEdit] Cue cache hit: \"\(text)\"")
            return cached
        }
        let speed = MarkdownTTSRenderer.cueSpeed
        NSLog("[DraftEdit] Synthesizing cue: \"\(text)\" at speed \(speed)")
        guard let audio = await synthesizeSentence(text, speed: speed) else {
            return nil
        }
        cueAudioCache[text] = audio
        return audio
    }

    private func playWavData(_ data: Data) async throws {
        try Task.checkCancellation()

        // Pause Spotify/Music/Podcasts/etc. for the playback session per
        // user setting; resumed in reset(). Idempotent.
        if AudioDuckMode.current.pausesMediaDuringPlayback {
            MediaRemoteController.shared.pause()
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("draftEdit_tts_\(UUID().uuidString).wav")
        try data.write(to: tempURL)

        // Collect audio for export
        audioSegments.append(data)

        let player = try AVAudioPlayer(contentsOf: tempURL)
        player.prepareToPlay()
        currentPlayer = player

        // Bluetooth output (AirPods etc.) needs the playback profile to
        // commit before audio actually starts; otherwise the first
        // half-sentence is clipped. Prime once per session.
        if !hasPrimedBluetoothOutput && AudioDeviceManager.shared.isCurrentOutputDeviceBluetooth() {
            await primeBluetoothOutput()
            hasPrimedBluetoothOutput = true
        }

        // Ensure cleanup happens on all exit paths
        defer {
            player.stop()
            currentPlayer = nil
            try? FileManager.default.removeItem(at: tempURL)
        }

        if !isPaused {
            player.play()
        }

        // Poll loop: handles pause/resume
        var wasPlaying = !isPaused
        while true {
            if Task.isCancelled {
                // Graceful stop — don't throw, just return after defer cleanup
                throw CancellationError()
            }

            if isPaused {
                if wasPlaying {
                    player.pause()
                    wasPlaying = false
                }
            } else {
                if !wasPlaying {
                    player.play()
                    wasPlaying = true
                }
                if !player.isPlaying {
                    break
                }
            }

            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - Escape Key

    private func installEscapeMonitor() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            if event.keyCode == 53 {  // Escape key
                NSLog("[DraftEdit] Escape key pressed — stopping session")
                DispatchQueue.main.async {
                    self?.stop()
                }
            }
        }

        escapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            return event.keyCode == 53 ? nil : event  // consume Escape, pass others through
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            escapeGlobalMonitor = nil
        }
        if let monitor = escapeLocalMonitor {
            NSEvent.removeMonitor(monitor)
            escapeLocalMonitor = nil
        }
    }

    // MARK: - Reset

    private func reset() {
        state = .idle
        document = nil
        currentParagraphIndex = 0
        isPaused = false
        currentPlayer = nil
        editHistory = []
        streamingEditText = ""
        cueAudioCache = [:]
        audioSegments = []
        MediaRemoteController.shared.resumeIfWePaused()
        hasPrimedBluetoothOutput = false
    }

    /// Brief silent buffer to commit the BT output profile before real TTS.
    private func primeBluetoothOutput() async {
        let sampleRate: Double = 44100
        let durationSeconds: Double = 0.8
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }
        buffer.frameLength = frameCount
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { return }
        await withCheckedContinuation { continuation in
            player.scheduleBuffer(buffer, at: nil, options: []) {
                continuation.resume()
            }
            player.play()
        }
        engine.stop()
    }
}
