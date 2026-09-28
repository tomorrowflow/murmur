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
    /// Serialises every highlight write to the document.
    ///
    /// Highlighting rewrites the whole file (marker characters appended to the
    /// paragraph's lines), and it used to run in a detached `Task` per
    /// paragraph. Rapid next/prev — or a navigation overlapping the
    /// completion `clearHighlight` — let two of them read the same content and
    /// both write it back, so the loser's markers vanished and anything the
    /// editor had saved in between was clobbered. Chaining onto the previous
    /// task keeps them strictly ordered.
    private var highlightChain: Task<Void, Never>?

    private var escapeGlobalMonitor: Any?
    private var escapeLocalMonitor: Any?

    // LLM
    private let llmClient = LLMClient()

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
            let adapter = editorAdapter
            enqueueHighlightWork { await adapter?.clearHighlight(file: doc.filePath) }
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

    /// Locate the paragraph an undo entry refers to.
    ///
    /// Stored indices shift whenever an earlier edit changes the paragraph
    /// count (an edit that splits one paragraph into two renumbers everything
    /// after it), so the index alone is not a safe anchor — undoing through it
    /// silently overwrote an unrelated paragraph. Match on the text the edit
    /// produced instead, and only accept an unambiguous match.
    private static func resolveParagraphIndex(for entry: DraftEditEntry, in doc: MarkdownDocument) -> Int? {
        func normalize(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let target = normalize(entry.replacement)
        if entry.paragraphIndex < doc.paragraphs.count,
           normalize(doc.paragraphs[entry.paragraphIndex].text) == target {
            return entry.paragraphIndex
        }
        let matches = doc.paragraphs.indices.filter { normalize(doc.paragraphs[$0].text) == target }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Undo a specific edit by index in the edit history.
    func undoEdit(historyIndex: Int) {
        guard historyIndex >= 0, historyIndex < editHistory.count, let doc = document else { return }
        let entry = editHistory[historyIndex]

        guard let resolvedIndex = Self.resolveParagraphIndex(for: entry, in: doc) else {
            let msg = "Can't undo — that paragraph has changed since the edit"
            NSLog("[DraftEdit] \(msg) (stored index \(entry.paragraphIndex))")
            state = .error(msg)
            delegate?.draftDidError(msg)
            return
        }
        let paragraph = doc.paragraphs[resolvedIndex]
        NSLog("[DraftEdit] Undoing edit at paragraph \(resolvedIndex) (stored \(entry.paragraphIndex))")

        state = .applyingEdit
        editTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                // Clear highlights first, then re-parse for clean line ranges.
                // Settle any queued highlight write first, or it lands after
                // the clear and puts markers back into the parsed ranges.
                await self.awaitHighlightsSettled()
                await self.editorAdapter?.clearHighlight(file: doc.filePath)
                let cleanDoc = try MarkdownParagraphParser.parse(filePath: doc.filePath)
                guard let cleanIndex = Self.resolveParagraphIndex(for: entry, in: cleanDoc) else {
                    await MainActor.run {
                        let msg = "Can't undo — that paragraph has changed since the edit"
                        self.state = .error(msg)
                        self.delegate?.draftDidError(msg)
                    }
                    return
                }
                let cleanParagraph = cleanDoc.paragraphs[cleanIndex]

                let _ = try FileEditController.replaceParagraph(
                    in: doc.filePath,
                    lineRange: cleanParagraph.lineRange,
                    with: entry.original,
                    expectedModDate: cleanDoc.modificationDate,
                    expectedOriginal: cleanParagraph.text
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
                            let adapter = await MainActor.run { self.editorAdapter }
                            let range = paragraph.lineRange
                            await MainActor.run {
                                // Single mate call: highlights paragraph and
                                // scrolls to it. Queued so two navigations
                                // can't rewrite the file concurrently.
                                self.enqueueHighlightWork {
                                    await adapter?.highlightLines(
                                        file: doc.filePath,
                                        from: range.lowerBound,
                                        to: range.upperBound
                                    )
                                }
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
        if let doc = await MainActor.run(body: { self.document }) {
            await awaitHighlightsSettled()
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
            for try await token in llmClient.streamChat(system: systemPrompt, user: userMessage) {
                guard !Task.isCancelled else { return }
                fullResponse += token
                let stripped = LLMClient.stripThinkBlocks(fullResponse)

                await MainActor.run {
                    self.streamingEditText = stripped
                    self.delegate?.draftDidUpdateStreamingEdit(stripped)
                }
            }

            guard !Task.isCancelled else { return }

            let finalText = LLMClient.stripThinkBlocks(fullResponse).trimmingCharacters(in: .whitespacesAndNewlines)
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
            //    would cause the mod-date check to fail. Queued highlight
            //    writes must land before the clear, not after it.
            await awaitHighlightsSettled()
            await editorAdapter?.clearHighlight(file: doc.filePath)

            // 2. Re-parse the now-clean file to get correct line ranges.
            //    The user may have edited the document in the editor while the
            //    LLM was streaming, so the re-parse can have fewer paragraphs
            //    than the index we started from.
            let cleanDoc = try MarkdownParagraphParser.parse(filePath: doc.filePath)
            guard paragraphIndex < cleanDoc.paragraphs.count else {
                await MainActor.run {
                    let msg = "Document changed while the edit was generating — paragraph \(paragraphIndex + 1) no longer exists"
                    self.state = .error(msg)
                    self.delegate?.draftDidError(msg)
                }
                return
            }
            let cleanParagraph = cleanDoc.paragraphs[paragraphIndex]

            // 3. Apply the edit to the clean file
            let _ = try FileEditController.replaceParagraph(
                in: doc.filePath,
                lineRange: cleanParagraph.lineRange,
                with: finalText,
                expectedModDate: cleanDoc.modificationDate,
                expectedOriginal: cleanParagraph.text
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
        // Cache is owned by the main thread (reset() clears it there);
        // this runs on the cooperative pool, so hop for access.
        if let cached = await MainActor.run(body: { cueAudioCache[text] }) {
            NSLog("[DraftEdit] Cue cache hit: \"\(text)\"")
            return cached
        }
        let speed = MarkdownTTSRenderer.cueSpeed
        NSLog("[DraftEdit] Synthesizing cue: \"\(text)\" at speed \(speed)")
        guard let audio = await synthesizeSentence(text, speed: speed) else {
            return nil
        }
        await MainActor.run { cueAudioCache[text] = audio }
        return audio
    }

    private func playWavData(_ data: Data) async throws {
        try Task.checkCancellation()

        // Pause Spotify/Music/Podcasts/etc. for the playback session per
        // user setting; resumed in reset(). Idempotent. Re-check
        // cancellation first so a task cancelled by stop() can't cancel the
        // resume that stop() just scheduled.
        try Task.checkCancellation()
        if AudioDuckMode.current.pausesMediaDuringPlayback {
            MediaRemoteController.shared.pause()
        }

        // Collect audio for export. audioSegments/currentPlayer are owned by
        // the main thread (stop/export mutate them there); this task runs on
        // the cooperative pool, so hop for every mutation.
        await MainActor.run { collectAudioSegment(data) }

        // Played straight from memory. Every sentence *and* every silence gap
        // used to round-trip through a unique temp file — write, decode,
        // delete, three syscalls per couple of seconds of speech.
        let player = try AVAudioPlayer(data: data)
        player.prepareToPlay()
        await MainActor.run { currentPlayer = player }

        // Bluetooth output (AirPods etc.) needs the playback profile to
        // commit before audio actually starts; otherwise the first
        // half-sentence is clipped. Prime once per session.
        if !hasPrimedBluetoothOutput && AudioDeviceManager.shared.isCurrentOutputDeviceBluetooth() {
            await primeBluetoothOutput()
            hasPrimedBluetoothOutput = true
        }

        // Ensure cleanup happens on all exit paths (defer can't await, so
        // the main-owned currentPlayer is cleared via an async hop; the
        // identity check avoids clobbering a newer player installed since).
        defer {
            player.stop()
            DispatchQueue.main.async { [weak self] in
                if self?.currentPlayer === player { self?.currentPlayer = nil }
            }
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

    /// See the note on ReadAloudManager.deinit — a leaked local Escape monitor
    /// silently eats Escape for the whole app.
    deinit {
        let global = escapeGlobalMonitor
        let local = escapeLocalMonitor
        let cleanup = {
            if let global = global { NSEvent.removeMonitor(global) }
            if let local = local { NSEvent.removeMonitor(local) }
        }
        if Thread.isMainThread { cleanup() } else { DispatchQueue.main.async(execute: cleanup) }
    }

    /// Enqueue a highlight write behind any already-pending one.
    @discardableResult
    private func enqueueHighlightWork(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = highlightChain
        let task = Task { [weak self] in
            _ = await previous?.value
            _ = self
            await work()
        }
        highlightChain = task
        return task
    }

    /// Wait for all queued highlight writes to land. Call before re-parsing the
    /// file for an edit, so line ranges are read from settled content.
    private func awaitHighlightsSettled() async {
        let chain = await MainActor.run { self.highlightChain }
        _ = await chain?.value
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


    /// Upper bound on retained export audio. Segments are 24 kHz 16-bit mono
    /// (~2.9 MB per minute of speech), so a long document would otherwise grow
    /// this without limit for an export the user may never request.
    private static let maxAudioSegmentBytes = 150 * 1024 * 1024
    private var audioSegmentBytes = 0
    private var didWarnAudioSegmentLimit = false

    /// Append to the export buffer unless the budget is spent.
    private func collectAudioSegment(_ data: Data) {
        guard audioSegmentBytes + data.count <= Self.maxAudioSegmentBytes else {
            if !didWarnAudioSegmentLimit {
                didWarnAudioSegmentLimit = true
                NSLog("Audio export buffer hit its %d MB limit — later audio won't be included in an export",
                      Self.maxAudioSegmentBytes / (1024 * 1024))
            }
            return
        }
        audioSegmentBytes += data.count
        audioSegments.append(data)
    }

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
        audioSegmentBytes = 0
        didWarnAudioSegmentLimit = false
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
