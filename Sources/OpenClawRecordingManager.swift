import Foundation
import AVFoundation
import AppKit
import SharedModels
import CoreAudio
import WhisperKit
import FluidAudio

protocol OpenClawRecordingManagerDelegate: AnyObject {
    func openClawAudioLevelDidUpdate(db: Float)
    func openClawDidStartProcessing()
    func openClawDidReceiveResponse(text: String)
    func openClawDidFinish(question: String, answer: String)
    func openClawDidFail(error: String)
    func openClawRecordingWasCancelled()
    func openClawTTSDidStart()
    func openClawTTSDidFinish()
}

class OpenClawRecordingManager: OpenClawManagerDelegate {
    weak var delegate: OpenClawRecordingManagerDelegate?

    private let openClawManager: OpenClawManager
    private let streamingPlayer: GeminiStreamingPlayer?
    private let audioCollector: GeminiAudioCollector?

    // Audio properties
    private var audioEngine: AVAudioEngine!
    private var inputNode: AVAudioInputNode!
    // Tap callback appends on the audio thread while main clears/reads —
    // all access must go through bufferQueue (see AudioTranscriptionManager).
    private var audioBuffer: [Float] = []
    private let bufferQueue = DispatchQueue(label: "com.murmur.openclaw.audioBuffer")
    private var autoStopRequested = false  // confined to bufferQueue
    private var activeMaxBufferSamples = Int.max  // snapshot taken at recording start
    private let sampleRate: Double = 16000
    private var maxBufferSamples: Int {
        let seconds = UserDefaults.standard.integer(forKey: "ptt.maxRecordingSeconds")
        if seconds == 0 { return Int.max }  // Unlimited
        let effectiveSeconds = seconds > 0 ? seconds : 300  // Default 5 minutes
        return 16000 * effectiveSeconds
    }

    // State
    var isRecording = false
    var isProcessing = false
    private var isStartingRecording = false
    private var escapeGlobalMonitor: Any?
    private var escapeLocalMonitor: Any?

    /// Called once when the first audio buffer arrives after starting recording.
    /// Used to detect when Bluetooth mic profile switch is complete.
    var onMicReady: (() -> Void)?
    private var micReadyFired = false

    // AirPods/HFP recovery — see AudioTranscriptionManager for rationale.
    private var configChangeObserver: NSObjectProtocol?
    private var configChangeRetries = 0
    private let maxConfigChangeRetries = 3

    // Response tracking
    private var currentRunId: String?
    private var accumulatedResponse = ""
    private var lastTranscription = ""
    private var currentTTSTask: Task<Void, Never>?

    // Streaming TTS (all accessed on main thread only)
    private var ttsQueuedCount = 0  // number of complete sentences already queued
    private var ttsSentenceQueue: [String] = []
    private var ttsQueueTask: Task<Void, Never>?
    /// Incremented on every consumer start so a cancelled task's epilogue
    /// can't nil out the handle of a newer consumer that replaced it.
    private var ttsQueueGeneration = 0
    private var ttsFinishSignaled = false
    private var ttsSpeaking = false
    /// The AVAudioPlayer currently rendering a Kokoro WAV chunk, kept so
    /// `cancelStreamingTTS()` can stop it mid-buffer instead of waiting for
    /// the 100ms cancellation poll inside `playWavData` to elapse.
    private var activeWavPlayer: AVAudioPlayer?

    /// True while a TTS sentence (Kokoro or Gemini fallback) is actively
    /// playing audio. Lets the rest of the app distinguish "answer streaming
    /// in" (no audio yet) from "speaker is talking, interruptible".
    var isTTSPlaying: Bool { ttsSpeaking }

    /// True while the TTS pipeline is alive — actively rendering a sentence
    /// OR between sentences with more queued. Use this for "is OpenClaw
    /// currently delivering an answer?" decisions like interrupt eligibility,
    /// since a double-tap during a brief inter-sentence gap should still
    /// interrupt cleanly.
    var isAnswering: Bool { ttsQueueTask != nil }

    init(openClawManager: OpenClawManager, streamingPlayer: GeminiStreamingPlayer?, audioCollector: GeminiAudioCollector?) {
        self.openClawManager = openClawManager
        self.streamingPlayer = streamingPlayer
        self.audioCollector = audioCollector
        openClawManager.delegate = self
        setupAudioEngine()
    }

    // MARK: - Audio Setup

    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        inputNode = audioEngine.inputNode
        configureInputDevice()
    }


    private func configureInputDevice() {
        if let deviceName = AudioDeviceManager.shared.applyInputDeviceOverrideIfNeeded() {
            print("OpenClaw: set input to: \(deviceName)")
        }
    }

    // MARK: - Recording Control

    /// Discard any audio captured so far (used after Bluetooth mic warmup).
    func clearAudioBuffer() {
        bufferQueue.sync { audioBuffer.removeAll() }
    }

    func toggleRecording() {
        if isStartingRecording { return }

        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func cancelRecording() {
        if isRecording {
            isRecording = false
            removeConfigChangeObserver()
            inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            audioEngine.reset()
            AudioDeviceManager.shared.restoreDefaultInputDeviceIfOverridden()
            clearAudioBuffer()
            removeEscapeMonitor()
            cancelStreamingTTS()
            print("OpenClaw: recording cancelled")
            delegate?.openClawRecordingWasCancelled()
        } else if isProcessing, let runId = currentRunId {
            // Cancel in-flight request
            openClawManager.abortChat(runId: runId)
            cancelStreamingTTS()
            isProcessing = false
            currentRunId = nil
            accumulatedResponse = ""
            delegate?.openClawRecordingWasCancelled()
        }
    }

    private func startRecording() {
        isStartingRecording = true
        bufferQueue.sync {
            audioBuffer.removeAll()
            autoStopRequested = false
        }
        activeMaxBufferSamples = maxBufferSamples
        micReadyFired = false
        accumulatedResponse = ""
        currentRunId = nil
        configChangeRetries = 0

        // Fresh audio engine
        audioEngine = AVAudioEngine()
        inputNode = audioEngine.inputNode
        configureInputDevice()

        // Escape key monitors (global for other apps, local for our app)
        let escapeHandler: (NSEvent) -> Void = { [weak self] event in
            if event.keyCode == 53 {
                if self?.isRecording == true || self?.isProcessing == true {
                    print("OpenClaw: cancelled by Escape key")
                    DispatchQueue.main.async {
                        self?.cancelRecording()
                    }
                }
            }
        }
        escapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: escapeHandler)
        escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                escapeHandler(event)
                return nil
            }
            return event
        }

        installInputTap()
        registerConfigChangeObserver()

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            isStartingRecording = false
            print("OpenClaw: recording started")
        } catch {
            print("OpenClaw: failed to start audio engine: \(error)")
            isStartingRecording = false
            removeConfigChangeObserver()
            inputNode.removeTap(onBus: 0)
            AudioDeviceManager.shared.restoreDefaultInputDeviceIfOverridden()
            removeEscapeMonitor()
            delegate?.openClawDidFail(error: "Could not start the microphone: \(error.localizedDescription)")
        }
    }

    private func installInputTap() {
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        let resampler = StreamingResampler(targetSampleRate: sampleRate)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            let channelData = buffer.floatChannelData?[0]
            let frameLength = Int(buffer.frameLength)

            if let channelData = channelData {
                // Fire mic-ready callback on first buffer (Bluetooth profile switch complete)
                if !self.micReadyFired {
                    self.micReadyFired = true
                    if let callback = self.onMicReady {
                        DispatchQueue.main.async {
                            callback()
                        }
                        self.onMicReady = nil
                    }
                }

                let samples = resampler?.resample(buffer)
                    ?? Array(UnsafeBufferPointer(start: channelData, count: frameLength))

                self.bufferQueue.async {
                    self.audioBuffer.append(contentsOf: samples)

                    if self.audioBuffer.count > self.activeMaxBufferSamples && !self.autoStopRequested {
                        self.autoStopRequested = true
                        print("OpenClaw: buffer limit reached. Auto-stopping.")
                        DispatchQueue.main.async {
                            guard self.isRecording else { return }
                            self.stopRecording()
                        }
                    }
                }

                let rms = sqrt(channelData.withMemoryRebound(to: Float.self, capacity: frameLength) { ptr in
                    var sum: Float = 0
                    for i in 0..<frameLength {
                        sum += ptr[i] * ptr[i]
                    }
                    return sum / Float(frameLength)
                })

                let db = 20 * log10(max(rms, 0.00001))

                DispatchQueue.main.async {
                    self.delegate?.openClawAudioLevelDidUpdate(db: db)
                }
            }
        }
    }

    private func registerConfigChangeObserver() {
        removeConfigChangeObserver()
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func removeConfigChangeObserver() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    private func handleConfigurationChange() {
        guard isRecording else { return }
        guard configChangeRetries < maxConfigChangeRetries else {
            print("OpenClaw: ⚠️ engine restart budget exhausted after Bluetooth codec switch")
            removeConfigChangeObserver()
            inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            audioEngine.reset()
            AudioDeviceManager.shared.restoreDefaultInputDeviceIfOverridden()
            isRecording = false
            clearAudioBuffer()
            removeEscapeMonitor()
            delegate?.openClawDidFail(error: "Mic failed to start (Bluetooth audio device unstable). Try again or pick a different input device.")
            return
        }
        configChangeRetries += 1
        print("OpenClaw: 🔁 engine config changed. Restart attempt \(configChangeRetries)/\(maxConfigChangeRetries)")

        inputNode.removeTap(onBus: 0)
        inputNode = audioEngine.inputNode
        installInputTap()

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            print("OpenClaw: ⚠️ failed to restart engine after config change: \(error)")
            removeConfigChangeObserver()
            isRecording = false
            removeEscapeMonitor()
            delegate?.openClawDidFail(error: "Failed to restart audio engine: \(error.localizedDescription)")
        }
    }

    private func stopRecording() {
        isRecording = false
        removeConfigChangeObserver()
        inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.reset()
        AudioDeviceManager.shared.restoreDefaultInputDeviceIfOverridden()
        removeEscapeMonitor()

        // Snapshot under the queue: late tap callbacks may still be appending.
        let samples = bufferQueue.sync { audioBuffer }

        print("OpenClaw: recording stopped (\(samples.count) samples)")

        // Validate audio
        guard !samples.isEmpty else {
            delegate?.openClawRecordingWasCancelled()
            return
        }

        let durationSeconds = Double(samples.count) / sampleRate
        // Sub-0.6s clips reliably hallucinate to nonsense after zero-padding,
        // and shipping that to Claude triggers spurious chat sessions.
        if durationSeconds < 0.60 {
            print("OpenClaw: recording too short (\(String(format: "%.2f", durationSeconds))s)")
            delegate?.openClawRecordingWasCancelled()
            return
        }

        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        let db = 20 * log10(max(rms, 0.00001))
        if db < -55.0 {
            print("OpenClaw: audio too quiet (dB: \(db))")
            delegate?.openClawRecordingWasCancelled()
            return
        }

        // Transcribe
        isProcessing = true
        delegate?.openClawDidStartProcessing()

        Task {
            await transcribeAndSend(samples: samples)
        }
    }

    @MainActor
    private func transcribeAndSend(samples: [Float]) async {
        // Pad short audio
        var paddedBuffer = samples
        let minSamplesForPadding = Int(1.5 * sampleRate)
        if samples.count < minSamplesForPadding {
            paddedBuffer.append(contentsOf: [Float](repeating: 0.0, count: Int(sampleRate)))
        }

        // Transcribe using current engine
        var transcription: String?

        switch ModelStateManager.shared.selectedEngine {
        case .whisperKit:
            transcription = await transcribeWithWhisperKit(paddedBuffer)
        case .parakeet:
            transcription = await transcribeWithParakeet(paddedBuffer)
        }

        guard let text = transcription else {
            // The transcriber already reported a specific error via the delegate.
            isProcessing = false
            return
        }
        guard !text.isEmpty else {
            isProcessing = false
            delegate?.openClawDidFail(error: "Transcription produced no text")
            return
        }

        let durationSeconds = Double(samples.count) / sampleRate
        if STTHallucinationFilter.isLikelyHallucination(text, audioDurationSeconds: durationSeconds) {
            print("OpenClaw: dropping likely hallucination on short audio (\(String(format: "%.2f", durationSeconds))s): \"\(text)\"")
            isProcessing = false
            delegate?.openClawRecordingWasCancelled()
            return
        }

        lastTranscription = text
        print("OpenClaw: transcription: \"\(text)\"")

        // Ensure WebSocket is connected — waits for the actual handshake
        // instead of a fixed sleep, so slow networks don't drop the question.
        if !openClawManager.isAuthenticated {
            let authenticated = await openClawManager.connectAndWaitForAuth(timeout: 10)
            if !authenticated {
                isProcessing = false
                delegate?.openClawDidFail(error: "Not connected to OpenClaw gateway")
                return
            }
        }

        // Send to OpenClaw
        let runId = openClawManager.sendChat(text: text)
        currentRunId = runId
    }

    @MainActor
    private func transcribeWithWhisperKit(_ samples: [Float]) async -> String? {
        if ModelStateManager.shared.loadedWhisperKit == nil {
            if let selectedModel = ModelStateManager.shared.selectedModel {
                _ = await ModelStateManager.shared.loadModel(selectedModel)
            }
        }

        guard let whisperKit = ModelStateManager.shared.loadedWhisperKit else {
            delegate?.openClawDidFail(error: "No WhisperKit model loaded")
            return nil
        }

        do {
            let result = try await whisperKit.transcribe(
                audioArray: samples,
                decodeOptions: DecodingOptions(
                    verbose: false,
                    task: .transcribe,
                    language: "en",
                    temperature: 0.0,
                    temperatureFallbackCount: 3,
                    sampleLength: 224,
                    topK: 5,
                    usePrefillPrompt: true,
                    usePrefillCache: true,
                    skipSpecialTokens: true,
                    withoutTimestamps: true,
                    clipTimestamps: [],
                    suppressBlank: true,
                    supressTokens: nil
                )
            )
            var text = result.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty {
                text = TextReplacements.shared.processText(text)
            }
            return text
        } catch {
            print("OpenClaw: WhisperKit error: \(error)")
            delegate?.openClawDidFail(error: "Transcription failed: \(error.localizedDescription)")
            return nil
        }
    }

    @MainActor
    private func transcribeWithParakeet(_ samples: [Float]) async -> String? {
        if ModelStateManager.shared.loadedParakeetTranscriber == nil ||
           ModelStateManager.shared.parakeetLoadingState != .loaded {
            await ModelStateManager.shared.loadParakeetModel()
        }

        guard let transcriber = ModelStateManager.shared.loadedParakeetTranscriber,
              transcriber.isReady else {
            delegate?.openClawDidFail(error: "No Parakeet model loaded")
            return nil
        }

        do {
            var text = try await transcriber.transcribe(audioSamples: samples)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                text = TextReplacements.shared.processText(text)
            }
            return text
        } catch {
            print("OpenClaw: Parakeet error: \(error)")
            delegate?.openClawDidFail(error: "Transcription failed: \(error.localizedDescription)")
            return nil
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

    // MARK: - Streaming TTS Playback

    private func startStreamingTTS() {
        let autoTTS = ProcessInfo.processInfo.environment["OPENCLAW_AUTO_TTS"] ?? "true"
        guard autoTTS.lowercased() != "false" else { return }

        ttsQueuedCount = 0
        ttsSentenceQueue = []
        ttsFinishSignaled = false
        ttsSpeaking = false
        ttsQueueTask?.cancel()
        ttsQueueGeneration += 1
        let generation = ttsQueueGeneration

        // Start the queue consumer with look-ahead synthesis
        ttsQueueTask = Task { [weak self] in
            var hasStartedSpeaking = false
            var pendingAudio: Data? = nil  // pre-synthesized audio for the NEXT sentence

            while !Task.isCancelled {
                guard let self = self else { return }

                // Get current audio: either from pre-synthesis or synthesize now
                let currentAudio: Data?
                let currentText: String

                if let presynth = pendingAudio {
                    // We already have pre-synthesized audio — just need to dequeue
                    // (the sentence was already removed from queue during pre-synth)
                    pendingAudio = nil

                    // Wait for it to be our turn (check done flag)
                    let done = await MainActor.run {
                        self.ttsSpeaking = true
                        return false
                    }
                    if done { break }

                    currentAudio = presynth
                    currentText = "" // already logged during pre-synth
                } else {
                    // Dequeue next sentence or check if we're done
                    let result: (sentence: String?, done: Bool) = await MainActor.run {
                        if !self.ttsSentenceQueue.isEmpty {
                            let s = self.ttsSentenceQueue.removeFirst()
                            self.ttsSpeaking = true
                            return (s, false)
                        }
                        if self.ttsFinishSignaled {
                            return (nil, true)
                        }
                        return (nil, false)
                    }

                    if result.done { break }

                    guard let sentence = result.sentence else {
                        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms poll
                        continue
                    }

                    currentText = sentence
                    currentAudio = await self.synthesizeSentence(sentence)
                }

                if !hasStartedSpeaking {
                    hasStartedSpeaking = true
                    await MainActor.run { self.delegate?.openClawTTSDidStart() }
                }

                guard let audioData = currentAudio else {
                    // Kokoro failed, fall back to Gemini
                    if !currentText.isEmpty {
                        await self.speakWithGemini(currentText)
                    }
                    await MainActor.run { self.ttsSpeaking = false }
                    continue
                }

                // Peek at the next sentence and pre-synthesize it while playing current
                let nextSentence: String? = await MainActor.run {
                    if !self.ttsSentenceQueue.isEmpty {
                        return self.ttsSentenceQueue.removeFirst()
                    }
                    return nil
                }

                if let next = nextSentence {
                    // Pre-synthesize next in parallel with playback of current
                    async let nextAudio = self.synthesizeSentence(next)
                    do { try await self.playWavData(audioData) } catch {}
                    pendingAudio = try? await nextAudio
                    // If pre-synth failed, put the sentence back
                    if pendingAudio == nil {
                        await MainActor.run {
                            self.ttsSentenceQueue.insert(next, at: 0)
                        }
                    }
                } else {
                    // No next sentence available yet, just play current
                    do { try await self.playWavData(audioData) } catch {}
                }

                await MainActor.run { self.ttsSpeaking = false }
            }

            // Consumer finished — signal TTS complete ONLY if it ended on
            // its own (queue drained after the final delta). If the loop
            // exited because we were cancelled (e.g. the user double-tapped
            // to interrupt mid-speech), do not fire the delegate. Firing it
            // on cancel previously caused armOpenClawAutoMicAfterTTS to
            // schedule a follow-up mic that collided with the manual
            // interrupt recording — the auto-mic work item would fire ~0.4s
            // after the user's recording started and stop it prematurely,
            // then a fresh recording would start in the same overlay when
            // the user released the key.
            let wasCancelled = Task.isCancelled
            await MainActor.run { [weak self] in
                guard let self, self.ttsQueueGeneration == generation else { return }
                self.ttsQueueTask = nil
                if !wasCancelled {
                    self.delegate?.openClawTTSDidFinish()
                }
            }
        }
    }

    private func feedDeltaToTTS(_ filteredText: String) {
        // Dispatch to main thread to synchronize with queue consumer
        DispatchQueue.main.async { [self] in
            let autoTTS = ProcessInfo.processInfo.environment["OPENCLAW_AUTO_TTS"] ?? "true"
            guard autoTTS.lowercased() != "false" else { return }

            let ttsFiltered = OpenClawResponseFilter.filterForTTS(filteredText)

            // Split the full text into sentences
            let sentences = SmartSentenceSplitter.splitIntoSentences(ttsFiltered)

            // All but the last sentence are "complete" — the last may still be partial
            let completeSentences = Array(sentences.dropLast())

            // Queue any new complete sentences beyond what we've already queued
            if completeSentences.count > self.ttsQueuedCount {
                let newSentences = Array(completeSentences[self.ttsQueuedCount...])
                self.ttsSentenceQueue.append(contentsOf: newSentences)
                self.ttsQueuedCount = completeSentences.count
                print("OpenClaw: queued \(newSentences.count) sentence(s) for TTS: \(newSentences.map { String($0.prefix(40)) })")
            }
        }
    }

    private func finishStreamingTTS(_ filteredText: String) {
        // Dispatch to main thread to synchronize
        DispatchQueue.main.async { [self] in
            let autoTTS = ProcessInfo.processInfo.environment["OPENCLAW_AUTO_TTS"] ?? "true"
            guard autoTTS.lowercased() != "false" else { return }

            let ttsFiltered = OpenClawResponseFilter.filterForTTS(filteredText)

            // Queue any remaining text (last partial sentence that wasn't queued during streaming)
            let sentences = SmartSentenceSplitter.splitIntoSentences(ttsFiltered)
            if sentences.count > self.ttsQueuedCount {
                let remaining = Array(sentences[self.ttsQueuedCount...])
                self.ttsSentenceQueue.append(contentsOf: remaining)
                print("OpenClaw: queued \(remaining.count) final sentence(s) for TTS: \(remaining.map { String($0.prefix(40)) })")
            }

            // Signal the consumer to exit after draining the queue
            self.ttsFinishSignaled = true
        }
    }

    /// Stop any active TTS playback and drain the synthesis queue. Safe to
    /// call from any thread; Kokoro buffer playback is stopped immediately,
    /// the Gemini fallback engine is told to stop, and the queue consumer
    /// task is cancelled. Must be called on the main thread for thread-safety
    /// of the queue arrays.
    func cancelStreamingTTS() {
        ttsQueueTask?.cancel()
        ttsQueueTask = nil
        currentTTSTask?.cancel()
        currentTTSTask = nil
        ttsSentenceQueue.removeAll()
        ttsQueuedCount = 0
        ttsFinishSignaled = false
        ttsSpeaking = false

        if let player = activeWavPlayer {
            player.stop()
            activeWavPlayer = nil
        }
        // Also stop the Gemini fallback path if it's currently rendering.
        streamingPlayer?.stopAudioEngine()
    }

    /// Synthesize text to WAV data using Kokoro. Returns nil if Kokoro unavailable or fails.
    private func synthesizeSentence(_ text: String) async -> Data? {
        let ttsManager = await MainActor.run { ModelStateManager.shared.loadedTtsManager }
        guard let ttsManager = ttsManager else {
            print("OpenClaw: Kokoro not loaded for: \"\(text.prefix(40))...\"")
            return nil
        }
        do {
            print("OpenClaw: synthesizing: \"\(text.prefix(50))...\"")
            let audioData = try await ttsManager.synthesize(text: text, voiceSpeed: 1.15)
            try Task.checkCancellation()
            return audioData
        } catch is CancellationError {
            return nil
        } catch {
            print("OpenClaw: Kokoro synthesis failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fall back to Gemini streaming TTS
    private func speakWithGemini(_ text: String) async {
        guard let streamingPlayer = self.streamingPlayer, let audioCollector = self.audioCollector else {
            print("OpenClaw: TTS not available (no Gemini API key)")
            return
        }
        do {
            if #available(macOS 14.0, *) {
                try await streamingPlayer.playText(text, audioCollector: audioCollector)
            }
        } catch is CancellationError {
            print("OpenClaw: TTS cancelled")
        } catch {
            print("OpenClaw: TTS error: \(error.localizedDescription)")
        }
    }

    private func playWavData(_ data: Data) async throws {
        try Task.checkCancellation()

        // Write to temporary file and play with AVAudioPlayer
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("kokoro_tts_\(UUID().uuidString).wav")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let player = try AVAudioPlayer(contentsOf: tempURL)
        player.prepareToPlay()
        // Register so an external cancel (interrupt) can stop us mid-buffer.
        await MainActor.run { self.activeWavPlayer = player }
        player.play()

        defer {
            Task { @MainActor in
                if self.activeWavPlayer === player { self.activeWavPlayer = nil }
            }
        }

        while player.isPlaying {
            if Task.isCancelled {
                player.stop()
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms — tighter loop so cancel feels snappier
        }
    }

    // MARK: - OpenClawManagerDelegate

    func openClawDidConnect() {
        print("OpenClaw: connected and authenticated")
    }

    func openClawDidDisconnect(error: Error?) {
        if let error = error {
            print("OpenClaw: disconnected: \(error.localizedDescription)")
        }
    }

    func openClawDidReceiveDelta(runId: String, text: String, seq: Int) {
        guard runId == currentRunId else { return }
        accumulatedResponse = text
        let filtered = OpenClawResponseFilter.filter(text)
        delegate?.openClawDidReceiveResponse(text: filtered)

        // Start TTS queue on first delta
        if ttsQueueTask == nil {
            startStreamingTTS()
        }
        feedDeltaToTTS(filtered)
    }

    func openClawDidReceiveFinal(runId: String, text: String, seq: Int) {
        guard runId == currentRunId else { return }
        accumulatedResponse = text
        isProcessing = false

        let filtered = OpenClawResponseFilter.filter(text)
        print("OpenClaw: final response (\(filtered.count) chars)")

        // Save to history as Q&A
        let historyEntry = "Q: \(lastTranscription)\nA: \(filtered)"
        TranscriptionHistory.shared.addEntry(historyEntry)

        delegate?.openClawDidFinish(question: lastTranscription, answer: filtered)

        // Queue any remaining text for TTS
        finishStreamingTTS(filtered)

        currentRunId = nil
    }

    func openClawDidReceiveError(runId: String, message: String) {
        guard runId == currentRunId else { return }
        isProcessing = false
        currentRunId = nil
        cancelStreamingTTS()
        print("OpenClaw: error: \(message)")
        delegate?.openClawDidFail(error: message)
    }

    func openClawDidReceiveAborted(runId: String, partialText: String?) {
        guard runId == currentRunId else { return }
        isProcessing = false
        currentRunId = nil
        cancelStreamingTTS()
        print("OpenClaw: aborted")
        delegate?.openClawRecordingWasCancelled()
    }
}
