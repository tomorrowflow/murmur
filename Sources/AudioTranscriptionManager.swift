import Foundation
import AVFoundation
import WhisperKit
import AppKit
import SharedModels
import CoreAudio

protocol AudioTranscriptionManagerDelegate: AnyObject {
    func audioLevelDidUpdate(db: Float)
    func transcriptionDidStart()
    func transcriptionDidComplete(text: String)
    func transcriptionDidFail(error: String)
    func recordingWasCancelled()
    func recordingWasSkippedDueToSilence()
}

class AudioTranscriptionManager {
    weak var delegate: AudioTranscriptionManagerDelegate?
    
    // Audio properties
    private var audioEngine: AVAudioEngine!
    private var inputNode: AVAudioInputNode!
    // The tap callback runs on AVAudioEngine's internal thread while the main
    // thread clears/reads the buffer (Bluetooth warmup, cancel, stop) — all
    // access must go through bufferQueue to avoid heap-corrupting races.
    private var audioBuffer: [Float] = []
    private let bufferQueue = DispatchQueue(label: "com.murmur.stt.audioBuffer")
    /// Serializes every AVAudioEngine mutation off the main thread. Starting the engine
    /// on a Bluetooth mic blocks for 1-2s while the device renegotiates A2DP→HFP; doing
    /// that on main froze the UI and skewed the push-to-talk key timings. Serial, so a
    /// stop enqueued during a start always runs after that start completes.
    private let engineQueue = DispatchQueue(label: "com.murmur.stt.engine")
    private var autoStopRequested = false  // confined to bufferQueue
    private var activeMaxBufferSamples = Int.max  // snapshot taken at recording start
    private let sampleRate: Double = 16000
    private var maxBufferSamples: Int {
        let seconds = UserDefaults.standard.integer(forKey: "ptt.maxRecordingSeconds")
        if seconds == 0 { return Int.max }  // Unlimited
        let effectiveSeconds = seconds > 0 ? seconds : 300  // Default 5 minutes
        return 16000 * effectiveSeconds
    }
    
    // Recording state
    var isRecording = false
    private var isStartingRecording = false  // Prevents race condition
    private var escapeKeyMonitor: Any?

    /// Called once when the first audio buffer arrives after starting recording.
    /// Used to detect when Bluetooth mic profile switch is complete.
    var onMicReady: (() -> Void)?
    private var micReadyFired = false

    // AirPods/HFP recovery: macOS posts AVAudioEngineConfigurationChange when
    // a Bluetooth mic switches codec (A2DP→HFP), which auto-stops the engine
    // before any buffer arrives. We restart it up to `maxConfigChangeRetries`
    // times so the recording actually begins.
    private var configChangeObserver: NSObjectProtocol?
    private var configChangeRetries = 0
    private let maxConfigChangeRetries = 3

    // Transcription state
    private var isTranscribing = false
    
    init() {
        setupAudioEngine()
        requestMicrophonePermission()
    }
    
    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        inputNode = audioEngine.inputNode
        configureInputDevice()
    }

    private func configureInputDevice() {
        if let deviceName = AudioDeviceManager.shared.applyInputDeviceOverrideIfNeeded() {
            print("✅ Set system default input to: \(deviceName)")
        } else {
            print("✅ Using system default input device")
        }

        let format = inputNode.outputFormat(forBus: 0)
        print("   Format: \(format.sampleRate)Hz, \(format.channelCount) channels")
    }
    
    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if granted {
                print("Microphone permission granted")
            } else {
                print("Microphone permission denied")
                DispatchQueue.main.async {
                    self.showPermissionAlert()
                }
            }
        }
    }
    
    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Permission Required"
        alert.informativeText = "Please grant microphone access in System Settings > Privacy & Security > Microphone"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
    
    /// Discard any audio captured so far (used after Bluetooth mic warmup).
    func clearAudioBuffer() {
        bufferQueue.sync { audioBuffer.removeAll() }
    }

    func toggleRecording() {
        if isRecording {
            // A stop is always honoured, even mid-start: the engine work is serialized,
            // so the teardown simply runs once the in-flight start finishes. Dropping it
            // here would strand a live recording with no way to stop it.
            isRecording = false
            stopRecording()
        } else {
            // Ignore a second start while one is still coming up.
            guard !isStartingRecording else { return }
            isRecording = true
            startRecording()
        }
    }

    func startRecording() {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if authStatus == .denied || authStatus == .restricted {
            isRecording = false
            delegate?.transcriptionDidFail(error: "Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone.")
            showPermissionAlert()
            return
        }

        isStartingRecording = true
        bufferQueue.sync {
            audioBuffer.removeAll()
            autoStopRequested = false
        }
        activeMaxBufferSamples = maxBufferSamples
        micReadyFired = false

        // Set up global Escape key monitor to cancel recording
        escapeKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                if self?.isRecording == true {
                    print("🛑 Recording cancelled by Escape key")
                    DispatchQueue.main.async {
                        self?.cancelRecording()
                    }
                }
            }
        }

        let mode = AudioDuckMode.current
        if mode.ducksRecording {
            AudioDucker.shared.duck()
        }
        if mode.pausesMediaDuringRecording {
            // Defer engine start until the pause snapshot resolves. The
            // AVAudioEngine + Bluetooth profile switch can disrupt Now
            // Playing state mid-snapshot — if the snapshot races ahead,
            // it can read a transient "not playing" and skip the pause,
            // letting the video resume itself when routing settles.
            MediaRemoteController.shared.pause { [weak self] in
                self?.startRecordingWithAVAudioEngine()
            }
        } else {
            startRecordingWithAVAudioEngine()
        }
    }

    /// Brings the engine up on `engineQueue`. `AVAudioEngine.start()` blocks for 1-2s on a
    /// Bluetooth mic; keeping it off main is what lets the overlay paint and the push-to-talk
    /// key timings stay honest.
    private func startRecordingWithAVAudioEngine() {
        engineQueue.async { [weak self] in
            guard let self = self else { return }

            // Create fresh audio engine to avoid state issues
            self.audioEngine = AVAudioEngine()
            self.inputNode = self.audioEngine.inputNode
            self.configureInputDevice()
            self.configChangeRetries = 0

            self.installInputTap()
            self.registerConfigChangeObserver()

            do {
                self.audioEngine.prepare()
                try self.audioEngine.start()
                print("🎤 Recording started...")
                DispatchQueue.main.async { self.isStartingRecording = false }
            } catch {
                print("Failed to start audio engine: \(error)")
                self.removeConfigChangeObserver()
                self.inputNode.removeTap(onBus: 0)
                AudioDeviceManager.shared.restoreDefaultInputDeviceIfOverridden()
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.isStartingRecording = false
                    AudioDucker.shared.restore()
                    MediaRemoteController.shared.resumeIfWePaused()
                    self.removeEscapeKeyMonitor()
                    self.delegate?.transcriptionDidFail(error: "Could not start the microphone: \(error.localizedDescription)")
                }
            }
        }
    }

    private func removeEscapeKeyMonitor() {
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
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
                        print("⚠️ Audio buffer limit reached. Auto-stopping recording.")
                        DispatchQueue.main.async {
                            guard self.isRecording else { return }
                            self.isRecording = false
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
                    self.delegate?.audioLevelDidUpdate(db: db)
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

        // Restarting the engine must not race the start that is still coming up on
        // engineQueue — the codec switch that triggers this notification is emitted
        // from inside that very start on Bluetooth.
        engineQueue.async { [weak self] in
            guard let self = self else { return }

            let failOnMain: (String) -> Void = { [weak self] message in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isRecording = false
                    AudioDucker.shared.restore()
                    MediaRemoteController.shared.resumeIfWePaused()
                    self.removeEscapeKeyMonitor()
                    self.delegate?.transcriptionDidFail(error: message)
                }
            }

            guard self.configChangeRetries < self.maxConfigChangeRetries else {
                print("⚠️ Audio engine restart budget exhausted after Bluetooth codec switch")
                self.teardownEngine()
                self.clearAudioBuffer()
                failOnMain("Mic failed to start (Bluetooth audio device unstable). Try again or pick a different input device.")
                return
            }
            self.configChangeRetries += 1
            print("🔁 Audio engine config changed (Bluetooth codec switch?). Restart attempt \(self.configChangeRetries)/\(self.maxConfigChangeRetries)")

            self.inputNode.removeTap(onBus: 0)
            // Re-acquire input node — its format may have changed after the codec switch.
            self.inputNode = self.audioEngine.inputNode
            self.installInputTap()

            do {
                self.audioEngine.prepare()
                try self.audioEngine.start()
            } catch {
                print("⚠️ Failed to restart audio engine after config change: \(error)")
                // Schedule a retry on next config-change notification, or bail out
                // if the engine refuses to come back up.
                self.removeConfigChangeObserver()
                failOnMain("Failed to restart audio engine: \(error.localizedDescription)")
            }
        }
    }

    func stopRecording() {
        // AppKit and playback state stay on main; the engine teardown is serialized behind
        // any start still in flight, so releasing the key mid-warm-up still stops cleanly.
        removeEscapeKeyMonitor()
        AudioDucker.shared.restore()
        MediaRemoteController.shared.resumeIfWePaused()

        engineQueue.async { [weak self] in
            guard let self = self else { return }
            self.teardownEngine()

            // Snapshot under the queue: late tap callbacks may still be appending.
            let samples = self.bufferQueue.sync { self.audioBuffer }

            print("⏹ Recording stopped")
            print("Captured \(samples.count) audio samples")

            Task { @MainActor in
                await self.processRecording(samples: samples)
            }
        }
    }

    /// Engine teardown. Must run on `engineQueue`.
    private func teardownEngine() {
        removeConfigChangeObserver()
        inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.reset()
        AudioDeviceManager.shared.restoreDefaultInputDeviceIfOverridden()
    }

    /// Cancel an in-flight recording.
    /// - Parameter asSilence: when true, routes to `recordingWasSkippedDueToSilence`
    ///   instead of `recordingWasCancelled`. Used by the auto-record silence
    ///   timeout so the UI shows "skipped due to silence" rather than the
    ///   louder "recording cancelled" notification.
    func cancelRecording(asSilence: Bool = false) {
        isRecording = false
        AudioDucker.shared.restore()
        MediaRemoteController.shared.resumeIfWePaused()
        removeEscapeKeyMonitor()

        engineQueue.async { [weak self] in
            guard let self = self else { return }
            self.teardownEngine()
            self.clearAudioBuffer()
        }

        print(asSilence ? "Recording cancelled — silence timeout" : "Recording cancelled")

        if asSilence {
            delegate?.recordingWasSkippedDueToSilence()
        } else {
            delegate?.recordingWasCancelled()
        }
    }
    
    @MainActor
    private func processRecording(samples: [Float]) async {
        guard !samples.isEmpty else {
            print("No audio recorded")
            // Nothing to transcribe; ensure UI resets
            delegate?.recordingWasSkippedDueToSilence()
            return
        }

        // Skip extremely short recordings to avoid spurious transcriptions.
        // Anything under ~0.6s is almost always a stray double-tap or clipped
        // start; Whisper/Parakeet hallucinate single tokens on zero-padded
        // sub-second audio.
        let durationSeconds = Double(samples.count) / sampleRate
        let minDurationSeconds: Double = 0.60
        if durationSeconds < minDurationSeconds {
            print("Recording too short (\(String(format: "%.2f", durationSeconds))s). Skipping transcription.")
            delegate?.recordingWasSkippedDueToSilence()
            return
        }

        // Calculate RMS (Root Mean Square) to detect silence
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        let db = 20 * log10(max(rms, 0.00001))

        // Threshold for silence detection (stricter to avoid false positives)
        // Lowered to -55dB to capture quieter audio
        let silenceThreshold: Float = -55.0

        if db < silenceThreshold {
            print("Audio too quiet (RMS: \(rms), dB: \(db)). Skipping transcription.")
            // Reset the status bar icon when skipping quiet audio
            delegate?.recordingWasSkippedDueToSilence()
            return
        }

        // Start transcription
        delegate?.transcriptionDidStart()
        isTranscribing = true

        // Route to appropriate transcriber based on selected engine
        switch ModelStateManager.shared.selectedEngine {
        case .whisperKit:
            await transcribeWithWhisperKit(samples: samples)
        case .parakeet:
            await transcribeWithParakeet(samples: samples)
        }
    }

    @MainActor
    private func transcribeWithWhisperKit(samples: [Float]) async {
        // Load model if not already loaded
        if ModelStateManager.shared.loadedWhisperKit == nil {
            if let selectedModel = ModelStateManager.shared.selectedModel {
                _ = await ModelStateManager.shared.loadModel(selectedModel)
            }
        }

        guard let whisperKit = ModelStateManager.shared.loadedWhisperKit else {
            print("WhisperKit not initialized - please select and download a model in Settings")
            isTranscribing = false
            delegate?.transcriptionDidFail(error: "No WhisperKit model loaded. Please select a model in Settings.")
            return
        }

        // Pad short audio with 1 second of silence to improve transcription reliability
        let paddingThresholdSeconds = 1.5
        let paddingDurationSeconds = 1.0
        let minSamplesForPadding = Int(paddingThresholdSeconds * sampleRate)
        let paddingSamples = Int(paddingDurationSeconds * sampleRate)

        var paddedBuffer = samples
        if samples.count < minSamplesForPadding {
            paddedBuffer.append(contentsOf: [Float](repeating: 0.0, count: paddingSamples))
            print("Padded short audio with \(paddingDurationSeconds)s of silence")
        }

        print("Transcribing \(samples.count) samples (\(Double(samples.count) / sampleRate) seconds) with WhisperKit...")

        do {
            let transcriptionResult = try await whisperKit.transcribe(
                audioArray: paddedBuffer,
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

            isTranscribing = false

            if let firstResult = transcriptionResult.first {
                let transcription = firstResult.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                handleTranscriptionResult(transcription, samples: samples)
            }
        } catch {
            print("WhisperKit transcription error: \(error)")
            isTranscribing = false
            delegate?.transcriptionDidFail(error: "Transcription failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func transcribeWithParakeet(samples: [Float]) async {
        // Load model if not already loaded
        if ModelStateManager.shared.loadedParakeetTranscriber == nil ||
           ModelStateManager.shared.parakeetLoadingState != .loaded {
            await ModelStateManager.shared.loadParakeetModel()
        }

        guard let transcriber = ModelStateManager.shared.loadedParakeetTranscriber,
              transcriber.isReady else {
            print("Parakeet not initialized - please select Parakeet in Settings and wait for model to load")
            isTranscribing = false
            delegate?.transcriptionDidFail(error: "No Parakeet model loaded. Please wait for model to download in Settings.")
            return
        }

        // Pad short audio with 1 second of silence to improve transcription reliability
        let paddingThresholdSeconds = 1.5
        let paddingDurationSeconds = 1.0
        let minSamplesForPadding = Int(paddingThresholdSeconds * sampleRate)
        let paddingSamples = Int(paddingDurationSeconds * sampleRate)

        var paddedBuffer = samples
        if samples.count < minSamplesForPadding {
            paddedBuffer.append(contentsOf: [Float](repeating: 0.0, count: paddingSamples))
            print("Padded short audio with \(paddingDurationSeconds)s of silence")
        }

        print("Transcribing \(samples.count) samples (\(Double(samples.count) / sampleRate) seconds) with Parakeet...")

        do {
            let transcription = try await transcriber.transcribe(audioSamples: paddedBuffer)
            isTranscribing = false
            handleTranscriptionResult(transcription, samples: samples)
        } catch {
            print("Parakeet transcription error: \(error)")
            isTranscribing = false
            delegate?.transcriptionDidFail(error: "Transcription failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func handleTranscriptionResult(_ rawTranscription: String, samples: [Float]) {
        let transcription = rawTranscription.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let durationSeconds = Double(samples.count) / sampleRate
        if STTHallucinationFilter.isLikelyHallucination(transcription, audioDurationSeconds: durationSeconds) {
            print("Skipping likely hallucination on short audio (\(String(format: "%.2f", durationSeconds))s): \"\(transcription)\"")
            delegate?.recordingWasSkippedDueToSilence()
            return
        }
        if !transcription.isEmpty {
            finishTranscription(transcription)
        } else {
            // Attempt Gemini fallback if API key is available
            if ProcessInfo.processInfo.environment["GEMINI_API_KEY"] != nil {
                print("Local transcription returned empty — falling back to Gemini")
                Task { await fallbackToGemini(samples: samples) }
            } else {
                print("No transcription generated (possibly silence)")
                delegate?.recordingWasSkippedDueToSilence()
            }
        }
    }

    @MainActor
    private func finishTranscription(_ rawText: String) {
        var transcription = rawText
        // Apply text replacements from config
        transcription = TextReplacements.shared.processText(transcription)

        print("Transcription: \"\(transcription)\"")

        // Save to history
        TranscriptionHistory.shared.addEntry(transcription)

        // Notify delegate
        delegate?.transcriptionDidComplete(text: transcription)
    }

    @MainActor
    private func fallbackToGemini(samples: [Float]) async {
        let gemini = GeminiAudioTranscriber()
        let buffer = samples

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gemini.transcribe(audioBuffer: buffer) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let text):
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let duration = Double(buffer.count) / (self?.sampleRate ?? 16000)
                        if STTHallucinationFilter.isLikelyHallucination(trimmed, audioDurationSeconds: duration) {
                            print("Gemini fallback returned likely hallucination on short audio: \"\(trimmed)\"")
                            self?.delegate?.recordingWasSkippedDueToSilence()
                        } else if !trimmed.isEmpty {
                            print("Gemini fallback transcription succeeded")
                            self?.finishTranscription(trimmed)
                        } else {
                            print("Gemini fallback also returned empty")
                            self?.delegate?.recordingWasSkippedDueToSilence()
                        }
                    case .failure(let error):
                        print("Gemini fallback failed: \(error.localizedDescription)")
                        self?.delegate?.recordingWasSkippedDueToSilence()
                    }
                    continuation.resume()
                }
            }
        }
    }
}
