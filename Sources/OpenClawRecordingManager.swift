import Foundation
import AVFoundation
import AppKit
import SharedModels
import CoreAudio
import WhisperKit
import FluidAudioTTS

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
    private var audioBuffer: [Float] = []
    private let sampleRate: Double = 16000
    private let maxBufferSamples = 16000 * 300  // 5 minutes max

    // State
    var isRecording = false
    var isProcessing = false
    private var isStartingRecording = false
    private var escapeGlobalMonitor: Any?
    private var escapeLocalMonitor: Any?

    // Response tracking
    private var currentRunId: String?
    private var accumulatedResponse = ""
    private var lastTranscription = ""
    private var currentTTSTask: Task<Void, Never>?

    // Streaming TTS (all accessed on main thread only)
    private var ttsQueuedCount = 0  // number of complete sentences already queued
    private var ttsSentenceQueue: [String] = []
    private var ttsQueueTask: Task<Void, Never>?
    private var ttsFinishSignaled = false
    private var ttsSpeaking = false

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
        let deviceManager = AudioDeviceManager.shared

        if !deviceManager.useSystemDefaultInput,
           let selectedUID = deviceManager.selectedInputDeviceUID,
           let deviceID = deviceManager.getAudioDeviceID(for: selectedUID) {

            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var deviceIDValue = deviceID
            let status = AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                0,
                nil,
                UInt32(MemoryLayout<AudioDeviceID>.size),
                &deviceIDValue
            )

            if status == noErr {
                let deviceName = deviceManager.availableInputDevices.first { $0.uid == selectedUID }?.name ?? selectedUID
                print("OpenClaw: set input to: \(deviceName)")
            }
        }
    }

    // MARK: - Recording Control

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
            audioEngine.stop()
            inputNode.removeTap(onBus: 0)
            audioBuffer.removeAll()
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
        audioBuffer.removeAll()
        accumulatedResponse = ""
        currentRunId = nil

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

        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            let channelData = buffer.floatChannelData?[0]
            let frameLength = Int(buffer.frameLength)
            let inputSampleRate = buffer.format.sampleRate

            if let channelData = channelData {
                let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))

                if inputSampleRate != self.sampleRate {
                    let ratio = Int(inputSampleRate / self.sampleRate)
                    let resampledSamples = stride(from: 0, to: samples.count, by: ratio).map { samples[$0] }
                    self.audioBuffer.append(contentsOf: resampledSamples)
                } else {
                    self.audioBuffer.append(contentsOf: samples)
                }

                if self.audioBuffer.count > self.maxBufferSamples {
                    print("OpenClaw: buffer limit reached. Auto-stopping.")
                    DispatchQueue.main.async {
                        self.isRecording = false
                        self.stopRecording()
                    }
                    return
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

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            isStartingRecording = false
            print("OpenClaw: recording started")
        } catch {
            print("OpenClaw: failed to start audio engine: \(error)")
            isStartingRecording = false
        }
    }

    private func stopRecording() {
        isRecording = false
        audioEngine.stop()
        inputNode.removeTap(onBus: 0)
        removeEscapeMonitor()

        print("OpenClaw: recording stopped (\(audioBuffer.count) samples)")

        // Validate audio
        guard !audioBuffer.isEmpty else {
            delegate?.openClawRecordingWasCancelled()
            return
        }

        let durationSeconds = Double(audioBuffer.count) / sampleRate
        if durationSeconds < 0.30 {
            print("OpenClaw: recording too short (\(String(format: "%.2f", durationSeconds))s)")
            delegate?.openClawRecordingWasCancelled()
            return
        }

        let rms = sqrt(audioBuffer.reduce(0) { $0 + $1 * $1 } / Float(audioBuffer.count))
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
            await transcribeAndSend()
        }
    }

    @MainActor
    private func transcribeAndSend() async {
        // Pad short audio
        var paddedBuffer = audioBuffer
        let minSamplesForPadding = Int(1.5 * sampleRate)
        if audioBuffer.count < minSamplesForPadding {
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

        guard let text = transcription, !text.isEmpty else {
            isProcessing = false
            delegate?.openClawDidFail(error: "Transcription produced no text")
            return
        }

        lastTranscription = text
        print("OpenClaw: transcription: \"\(text)\"")

        // Ensure WebSocket is connected
        if !openClawManager.isAuthenticated {
            openClawManager.connect()
            // Wait briefly for connection
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !openClawManager.isAuthenticated {
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

            // Consumer finished — signal TTS complete
            await MainActor.run { [weak self] in
                self?.ttsQueueTask = nil
                self?.delegate?.openClawTTSDidFinish()
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

    private func cancelStreamingTTS() {
        ttsQueueTask?.cancel()
        ttsQueueTask = nil
        currentTTSTask?.cancel()
        currentTTSTask = nil
        ttsSentenceQueue.removeAll()
        ttsQueuedCount = 0
        ttsFinishSignaled = false
        ttsSpeaking = false
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
        player.play()

        // Wait for playback to finish
        while player.isPlaying {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
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
