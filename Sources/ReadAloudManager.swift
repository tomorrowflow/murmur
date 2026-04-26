import Foundation
import AppKit
import AVFoundation
import SharedModels

// MARK: - Protocol

protocol ReadAloudManagerDelegate: AnyObject {
    func readAloudDidChangeState(_ state: ReadAloudState)
    func readAloudDidUpdateSentences(_ sentences: [String])
    func readAloudDidActivateSentence(index: Int)
    func readAloudDidInsertQA(question: String, answer: String, afterSentenceIndex: Int)
    func readAloudDidUpdateStreamingAnswer(_ text: String)
    func readAloudDidUpdateTranslationStatus(_ status: String)
    func readAloudDidError(_ message: String)
}

// MARK: - State

enum ReadAloudState: Equatable {
    case idle
    case translating
    case reading
    case listening
    case processingQuestion
    case speakingAnswer
    case awaitingResume
    case complete
    case error(String)

    var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .translating: return "Translating"
        case .reading: return "Reading"
        case .listening: return "Listening"
        case .processingQuestion: return "Thinking"
        case .speakingAnswer: return "Answering"
        case .awaitingResume: return "Continue?"
        case .complete: return "Complete"
        case .error: return "Error"
        }
    }
}

enum ReadAloudResumeBehavior: String {
    case ask = "ask"
    case auto = "auto"
    case stop = "stop"
}

// MARK: - ReadAloudManager

class ReadAloudManager {
    weak var delegate: ReadAloudManagerDelegate?

    private(set) var state: ReadAloudState = .idle {
        didSet {
            if state != oldValue {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.readAloudDidChangeState(self.state)
                }
            }
        }
    }

    var isActive: Bool {
        switch state {
        case .idle, .complete, .error: return false
        case .translating, .reading, .listening, .processingQuestion, .speakingAnswer, .awaitingResume:
            return true
        }
    }

    // Content
    private(set) var fullText: String = ""
    private(set) var sentences: [String] = []
    private(set) var currentSentenceIndex: Int = 0

    // Q&A tracking
    struct QAPair {
        let question: String
        let answer: String
        let afterSentenceIndex: Int
    }
    private(set) var qaPairs: [QAPair] = []
    private var streamingAnswer: String = ""

    // Playback
    private var readingTask: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?
    private var answerTTSTask: Task<Void, Never>?
    private(set) var isPaused: Bool = false
    private var currentPlayer: AVAudioPlayer?

    // Track current interrupt for partial Q&A saving
    private var currentInterruptQuestion: String = ""
    private var currentInterruptIndex: Int = 0

    // Audio collection for export
    private(set) var audioSegments: [Data] = []

    // Bluetooth output is primed once per session by playing a brief silent
    // buffer; subsequent chunks ride the warm path. Reset on stop.
    private var hasPrimedBluetoothOutput = false

    // Escape key monitors
    private var escapeGlobalMonitor: Any?
    private var escapeLocalMonitor: Any?

    // Ollama
    private let ollamaClient = OllamaClient()

    // Settings
    private var resumeBehavior: ReadAloudResumeBehavior {
        let raw = UserDefaults.standard.string(forKey: "readAloud.resumeBehavior") ?? "ask"
        return ReadAloudResumeBehavior(rawValue: raw) ?? .ask
    }

    // MARK: - Public API

    func startReading(text: String, skipTranslation: Bool = false) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .error("No text to read")
            delegate?.readAloudDidError("No text to read")
            return
        }

        reset()
        fullText = text
        state = skipTranslation ? .reading : .translating
        installEscapeMonitor()

        readingTask = Task { [weak self] in
            guard let self = self else { return }

            let readText: String
            if skipTranslation {
                readText = text
            } else {
            await MainActor.run {
                self.delegate?.readAloudDidUpdateTranslationStatus("Detecting language...")
            }
            let isNonEnglish = await self.detectNonEnglish(text)
            guard !Task.isCancelled else { return }

            if isNonEnglish {
                NSLog("ReadAloud: text appears non-English, translating...")
                await MainActor.run {
                    self.delegate?.readAloudDidUpdateTranslationStatus("Translating to English...")
                }
                // State is already .translating — overlay is showing the spinner
                if let translated = await self.translateToEnglish(text) {
                    readText = translated
                    await MainActor.run { self.fullText = translated }
                    NSLog("ReadAloud: translation complete (\(translated.count) chars)")
                } else {
                    readText = text
                    NSLog("ReadAloud: translation failed, reading original text")
                }
            } else {
                readText = text
            }
            }

            guard !Task.isCancelled else { return }

            let splitSentences = SmartSentenceSplitter.splitIntoSentences(readText)
            await MainActor.run {
                self.sentences = splitSentences
                self.delegate?.readAloudDidUpdateSentences(splitSentences)
                self.state = .reading
            }

            NSLog("ReadAloud: starting session with \(splitSentences.count) sentences")
            await self.readSentences(fromIndex: 0)
        }
    }

    func stop() {
        NSLog("ReadAloud: stopping session")
        removeEscapeMonitor()
        readingTask?.cancel()
        answerTask?.cancel()
        readingTask = nil
        answerTask = nil
        reset()
    }

    /// Play a brief silent buffer so the Bluetooth output device commits to a
    /// playback profile before the real TTS starts. Without this, the first
    /// half-sentence on AirPods is clipped while the A2DP→playback profile
    /// switch happens.
    private func primeBluetoothOutput() async {
        let sampleRate: Double = 44100
        let durationSeconds: Double = 0.8
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }
        buffer.frameLength = frameCount
        // buffer is zero-filled by default (silence).
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            NSLog("ReadAloud: BT prime engine failed: \(error.localizedDescription)")
            return
        }
        await withCheckedContinuation { continuation in
            player.scheduleBuffer(buffer, at: nil, options: []) {
                continuation.resume()
            }
            player.play()
        }
        engine.stop()
        NSLog("ReadAloud: BT output primed")
    }

    // MARK: - Escape Key

    private func installEscapeMonitor() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            if event.keyCode == 53 {
                NSLog("ReadAloud: Escape key pressed — stopping session")
                DispatchQueue.main.async { self?.stop() }
            }
        }
        escapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            return event.keyCode == 53 ? nil : event
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

    func togglePause() {
        if isPaused {
            NSLog("ReadAloud: resuming from pause")
            isPaused = false
            // Player will be resumed by the playWavData poll loop
        } else {
            guard state == .reading || state == .speakingAnswer else { return }
            NSLog("ReadAloud: pausing")
            isPaused = true
            // Player will be paused by the playWavData poll loop
        }
    }

    /// Resume reading from current position (used after answer or pause).
    func resumeFromAwait() {
        guard state == .awaitingResume else { return }
        NSLog("ReadAloud: user chose to continue reading")
        resumeReading()
    }

    /// Combined WAV audio data from all segments for export.
    func combinedAudioData() -> Data? {
        guard !audioSegments.isEmpty else { return nil }
        // Simple concatenation: take header from first segment, append raw PCM from rest
        guard audioSegments[0].count > 44 else { return nil }

        var pcmData = Data()
        for segment in audioSegments {
            guard segment.count > 44 else { continue }
            pcmData.append(segment[44...])
        }

        // Build a new WAV header for the combined data
        var header = audioSegments[0][0..<44]
        let totalSize = UInt32(pcmData.count + 36)
        let dataSize = UInt32(pcmData.count)
        // Update RIFF chunk size (bytes 4-7)
        header.replaceSubrange(4..<8, with: withUnsafeBytes(of: totalSize.littleEndian) { Data($0) })
        // Update data chunk size (bytes 40-43)
        header.replaceSubrange(40..<44, with: withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })

        return header + pcmData
    }

    /// Called when user starts recording an interrupt question.
    func beginInterrupt() {
        guard isActive else { return }
        NSLog("ReadAloud: interrupt started at sentence \(currentSentenceIndex)")
        isPaused = false
        currentPlayer?.stop()
        currentPlayer = nil
        readingTask?.cancel()
        answerTask?.cancel()
        answerTTSTask?.cancel()
        readingTask = nil
        answerTask = nil
        answerTTSTask = nil
        state = .listening
    }

    /// Called after user's question has been transcribed.
    func sendQuestion(question: String) {
        guard state == .listening || state == .awaitingResume else { return }
        NSLog("ReadAloud: question: \"\(question)\"")

        let interruptIndex = currentSentenceIndex
        currentInterruptQuestion = question
        currentInterruptIndex = interruptIndex
        streamingAnswer = ""
        state = .processingQuestion
        delegate?.readAloudDidUpdateStreamingAnswer("")

        answerTask = Task { [weak self] in
            guard let self = self else { return }
            await self.processQuestion(question: question, interruptIndex: interruptIndex)
        }
    }

    /// Skip the current answer and resume reading.
    func skipAnswerAndResume() {
        guard state == .speakingAnswer || state == .processingQuestion else { return }
        NSLog("ReadAloud: skipping answer, resuming reading")

        // Save partial Q&A so it persists in the display
        let partialAnswer = streamingAnswer.isEmpty ? "(skipped)" : streamingAnswer
        let qa = QAPair(question: currentInterruptQuestion, answer: partialAnswer, afterSentenceIndex: currentInterruptIndex)
        qaPairs.append(qa)
        delegate?.readAloudDidInsertQA(question: currentInterruptQuestion, answer: partialAnswer, afterSentenceIndex: currentInterruptIndex)

        // Stop current audio and cancel both answer streaming and its TTS playback
        isPaused = false
        currentPlayer?.stop()
        currentPlayer = nil
        answerTTSTask?.cancel()
        answerTTSTask = nil
        answerTask?.cancel()
        answerTask = nil

        currentInterruptQuestion = ""
        streamingAnswer = ""

        resumeReading()
    }

    /// Cancel an in-progress interrupt (e.g., silence, recording cancelled).
    func cancelInterrupt() {
        guard state == .listening else { return }
        NSLog("ReadAloud: interrupt cancelled, resuming reading")
        resumeReading()
    }

    /// Handle resume after an answer has been spoken.
    func handleResumeInput(text: String) {
        guard state == .awaitingResume else { return }

        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let affirmatives = ["yes", "yeah", "yep", "sure", "ok", "okay", "continue", "go on", "go ahead", "keep going", "resume", "please continue"]

        if affirmatives.contains(where: { lower.contains($0) }) {
            NSLog("ReadAloud: user confirmed resume")
            resumeReading()
        } else {
            // Treat as a follow-up question
            NSLog("ReadAloud: treating resume input as follow-up question")
            sendQuestion(question: text)
        }
    }

    // MARK: - Sentence-by-Sentence Reading

    private func readSentences(fromIndex startIndex: Int) async {
        var pendingAudio: Data? = nil

        for i in startIndex..<sentences.count {
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.currentSentenceIndex = i
                self.delegate?.readAloudDidActivateSentence(index: i)
            }

            // Get audio: either pre-synthesized or synthesize now
            let currentAudio: Data?
            if let presynth = pendingAudio {
                currentAudio = presynth
                pendingAudio = nil
            } else {
                currentAudio = await synthesizeSentence(sentences[i])
            }

            guard !Task.isCancelled else { return }

            guard let audioData = currentAudio else {
                NSLog("ReadAloud: synthesis failed for sentence \(i), skipping")
                continue
            }

            // Pre-synthesize next sentence while playing current
            if i + 1 < sentences.count {
                async let nextAudio = synthesizeSentence(sentences[i + 1])
                do { try await playWavData(audioData) } catch { return }
                pendingAudio = try? await nextAudio
            } else {
                do { try await playWavData(audioData) } catch { return }
            }
        }

        guard !Task.isCancelled else { return }
        await MainActor.run {
            self.state = .complete
        }
    }

    private func resumeReading() {
        state = .reading
        let resumeIndex = currentSentenceIndex
        NSLog("ReadAloud: resuming from sentence \(resumeIndex)")

        readingTask = Task { [weak self] in
            await self?.readSentences(fromIndex: resumeIndex)
        }
    }

    // MARK: - Question Processing

    private func processQuestion(question: String, interruptIndex: Int) async {
        do {
            // Optional web search
            var searchContext = ""
            if UserDefaults.standard.bool(forKey: "readAloud.webSearchEnabled") {
                let results = await ollamaClient.webSearch(query: question)
                if !results.isEmpty {
                    searchContext = "\n\n" + OllamaClient.formatSearchResults(results)
                    NSLog("ReadAloud: web search returned \(results.count) results")
                }
            }

            // Build context — use a focused window for very long texts
            let currentSentence = interruptIndex < sentences.count ? sentences[interruptIndex] : ""

            // For the text context: include all sentences read so far + a few upcoming ones
            let contextStart = max(0, interruptIndex - 20)
            let contextEnd = min(sentences.count, interruptIndex + 5)
            let readSoFar = sentences[0..<min(interruptIndex + 1, sentences.count)].joined(separator: " ")
            let nearbyText: String
            if sentences.count > 30 {
                // Long text: include a focused window + summary
                let windowText = sentences[contextStart..<contextEnd].joined(separator: " ")
                nearbyText = """
                [Full text excerpt around current reading position]
                \(windowText)
                """
            } else {
                nearbyText = fullText
            }

            // Include previous Q&A for conversation continuity
            var qaContext = ""
            if !qaPairs.isEmpty {
                let recentQAs = qaPairs.suffix(3)
                qaContext = "\n\nPrevious questions and answers during this reading session:\n"
                for qa in recentQAs {
                    qaContext += "Q: \(qa.question)\nA: \(qa.answer)\n\n"
                }
            }

            let systemPrompt = """
            You are a reading assistant. The user is listening to a text being read aloud \
            and has paused to ask you a question. The text content is provided below — use it \
            as your primary context to answer the question. Answer concisely and conversationally — \
            your answer will be spoken aloud. Keep answers under 3 sentences unless more detail is \
            needed. Always answer in English, even if the source text is in another language.
            """

            let userMessage = """
            I'm reading the following text:

            \(nearbyText)

            I've listened up to this point: "\(currentSentence)"

            Text read so far (\(interruptIndex + 1) of \(sentences.count) sentences):
            \(readSoFar)
            \(qaContext)\(searchContext)

            My question: \(question)
            """

            NSLog("ReadAloud: sending question to LLM with \(userMessage.count) chars context")

            // Stream LLM response
            var fullAnswer = ""
            var ttsQueuedCount = 0
            var ttsSentenceQueue: [String] = []
            var ttsFinishSignaled = false

            var hasStartedSpeaking = false

            // Start TTS consumer task
            let ttsTask = Task { [weak self] in
                guard let self = self else { return }
                var pendingAudio: Data? = nil

                while !Task.isCancelled {
                    let result: (sentence: String?, done: Bool) = await MainActor.run {
                        if !ttsSentenceQueue.isEmpty {
                            return (ttsSentenceQueue.removeFirst(), false)
                        }
                        if ttsFinishSignaled {
                            return (nil, true)
                        }
                        return (nil, false)
                    }

                    if result.done { break }

                    guard let sentence = result.sentence else {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        continue
                    }

                    let currentAudio: Data?
                    if let presynth = pendingAudio {
                        pendingAudio = nil
                        currentAudio = presynth
                    } else {
                        currentAudio = await self.synthesizeSentence(sentence)
                    }

                    guard let audioData = currentAudio else { continue }

                    // Transition to speakingAnswer only when first audio is about to play
                    if !hasStartedSpeaking {
                        hasStartedSpeaking = true
                        await MainActor.run { self.state = .speakingAnswer }
                    }

                    // Pre-synthesize next while playing
                    let nextSentence: String? = await MainActor.run {
                        if !ttsSentenceQueue.isEmpty {
                            return ttsSentenceQueue.removeFirst()
                        }
                        return nil
                    }

                    if let next = nextSentence {
                        async let nextAudio = self.synthesizeSentence(next)
                        do { try await self.playWavData(audioData) } catch { return }
                        pendingAudio = try? await nextAudio
                    } else {
                        do { try await self.playWavData(audioData) } catch { return }
                    }
                }
            }
            await MainActor.run { self.answerTTSTask = ttsTask }

            for try await token in ollamaClient.streamChat(system: systemPrompt, user: userMessage) {
                guard !Task.isCancelled else { break }

                fullAnswer += token
                let stripped = OllamaClient.stripThinkBlocks(fullAnswer)

                await MainActor.run {
                    self.streamingAnswer = stripped
                    self.delegate?.readAloudDidUpdateStreamingAnswer(stripped)
                }

                // Feed complete sentences to TTS queue
                let allSentences = SmartSentenceSplitter.splitIntoSentences(stripped)
                let completeSentences = Array(allSentences.dropLast())
                if completeSentences.count > ttsQueuedCount {
                    let newSentences = Array(completeSentences[ttsQueuedCount...])
                    await MainActor.run {
                        ttsSentenceQueue.append(contentsOf: newSentences)
                    }
                    ttsQueuedCount = completeSentences.count
                }
            }

            // Queue remaining text
            let finalStripped = OllamaClient.stripThinkBlocks(fullAnswer)
            let finalSentences = SmartSentenceSplitter.splitIntoSentences(finalStripped)
            if finalSentences.count > ttsQueuedCount {
                let remaining = Array(finalSentences[ttsQueuedCount...])
                await MainActor.run {
                    ttsSentenceQueue.append(contentsOf: remaining)
                }
            }
            await MainActor.run { ttsFinishSignaled = true }

            // Wait for TTS to finish
            await ttsTask.value
            await MainActor.run { self.answerTTSTask = nil }

            guard !Task.isCancelled else { return }

            // Record Q&A
            let finalAnswer = finalStripped
            await MainActor.run {
                let qa = QAPair(question: question, answer: finalAnswer, afterSentenceIndex: interruptIndex)
                self.qaPairs.append(qa)
                self.delegate?.readAloudDidInsertQA(question: question, answer: finalAnswer, afterSentenceIndex: interruptIndex)
                self.currentInterruptQuestion = ""
                self.streamingAnswer = ""
            }

            // Handle resume behavior
            await handlePostAnswer()

        } catch is CancellationError {
            return
        } catch {
            NSLog("ReadAloud: question processing failed: \(error)")
            await MainActor.run {
                self.state = .error(error.localizedDescription)
                self.delegate?.readAloudDidError(error.localizedDescription)
            }
        }
    }

    private func handlePostAnswer() async {
        guard !Task.isCancelled else { return }

        switch resumeBehavior {
        case .ask:
            // Speak "Would you like me to continue?" then wait
            if let audio = await synthesizeSentence("Would you like me to continue?") {
                do { try await playWavData(audio) } catch { return }
            }
            await MainActor.run { self.state = .awaitingResume }

        case .auto:
            // Wait 2 seconds then auto-resume
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self.resumeReading() }

        case .stop:
            await MainActor.run { self.state = .complete }
        }
    }

    // MARK: - Audio Synthesis & Playback

    private func synthesizeSentence(_ text: String) async -> Data? {
        let ttsManager = await MainActor.run { ModelStateManager.shared.loadedTtsManager }
        guard let ttsManager = ttsManager else {
            NSLog("ReadAloud: Kokoro not loaded")
            return nil
        }
        do {
            let audioData = try await ttsManager.synthesize(text: text, voiceSpeed: 1.15)
            try Task.checkCancellation()
            return audioData
        } catch is CancellationError {
            return nil
        } catch {
            NSLog("ReadAloud: synthesis failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func playWavData(_ data: Data) async throws {
        try Task.checkCancellation()

        // Collect audio for export
        audioSegments.append(data)

        // Per user setting: pause Spotify/Music/Podcasts/etc. for the whole
        // playback session. resumeIfWePaused() in the session-end path
        // restores them. Idempotent — repeated chunks won't re-pause.
        if AudioDuckMode.current.pausesMediaDuringPlayback {
            MediaRemoteController.shared.pause()
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("readAloud_tts_\(UUID().uuidString).wav")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let player = try AVAudioPlayer(contentsOf: tempURL)
        player.prepareToPlay()
        currentPlayer = player

        // Bluetooth output (AirPods etc.) takes 1-2s to switch from A2DP to
        // a profile that handles low-latency playback. Without a pre-warm,
        // the first half-sentence gets clipped while the profile switches.
        // A short silent priming buffer forces the switch before the real
        // audio plays. Only on the first chunk of a session (subsequent
        // chunks ride the already-warm path).
        if !hasPrimedBluetoothOutput && AudioDeviceManager.shared.isCurrentOutputDeviceBluetooth() {
            await primeBluetoothOutput()
            hasPrimedBluetoothOutput = true
        }

        // If already paused, don't start playing yet
        if !isPaused {
            player.play()
        }

        // Poll loop: handles pause/resume from the same thread that owns the player
        var wasPlaying = !isPaused
        while true {
            try Task.checkCancellation()

            if isPaused {
                // Pause the player if it's currently playing
                if wasPlaying {
                    player.pause()
                    wasPlaying = false
                }
            } else {
                // Resume the player if it was paused
                if !wasPlaying {
                    player.play()
                    wasPlaying = true
                }
                // If not paused and not playing, playback finished
                if !player.isPlaying {
                    break
                }
            }

            try await Task.sleep(nanoseconds: 100_000_000)
        }

        currentPlayer = nil
    }

    // MARK: - Translation

    /// Detect if text is non-English using Ollama.
    private func detectNonEnglish(_ text: String) async -> Bool {
        let sample = String(text.prefix(300))
        do {
            let result = try await ollamaClient.chat(
                system: "You are a language detector. Reply with ONLY the two-letter ISO 639-1 language code of the text. Nothing else.",
                user: sample
            )
            let code = result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(2)
            NSLog("ReadAloud: detected language code: \(code)")
            return code != "en"
        } catch {
            NSLog("ReadAloud: language detection failed: \(error.localizedDescription)")
            // Fallback: quick character heuristic for non-Latin scripts
            let letters = sample.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            guard !letters.isEmpty else { return false }
            let nonAsciiLetters = letters.filter { $0.value > 127 }
            return Double(nonAsciiLetters.count) / Double(letters.count) > 0.3
        }
    }

    /// Translate text to English using Ollama.
    private func translateToEnglish(_ text: String) async -> String? {
        do {
            let result = try await ollamaClient.chat(
                system: "You are a translator. Translate the following text to English. Output ONLY the translated text, nothing else. Preserve paragraph structure.",
                user: text
            )
            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            NSLog("ReadAloud: translation failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Reset

    private func reset() {
        removeEscapeMonitor()
        currentPlayer?.stop()
        currentPlayer = nil
        readingTask?.cancel()
        answerTask?.cancel()
        answerTTSTask?.cancel()
        readingTask = nil
        answerTask = nil
        answerTTSTask = nil
        // If we paused the user's media to talk, resume it now. Idempotent —
        // safe even if reset() runs before any playback (no-op).
        MediaRemoteController.shared.resumeIfWePaused()
        hasPrimedBluetoothOutput = false
        fullText = ""
        sentences = []
        currentSentenceIndex = 0
        qaPairs = []
        streamingAnswer = ""
        currentInterruptQuestion = ""
        currentInterruptIndex = 0
        isPaused = false
        audioSegments = []
        state = .idle
    }
}
