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
    
    /// Owns the AVAudioEngine, its input tap, the sample buffer and Bluetooth recovery.
    private let recorder = AudioEngineRecorder(
        configuration: .init(label: "stt", targetSampleRate: 16000)
    )

    private let sampleRate: Double = 16000
    private var maxBufferSamples: Int {
        let seconds = UserDefaults.standard.integer(forKey: "ptt.maxRecordingSeconds")
        if seconds == 0 { return Int.max }  // Unlimited
        let effectiveSeconds = seconds > 0 ? seconds : 300  // Default 5 minutes
        return 16000 * effectiveSeconds
    }

    // Recording state
    var isRecording: Bool { recorder.isRecording }
    private var escapeKeyMonitor: Any?

    /// Called once when the first audio buffer arrives after starting recording.
    /// Used to detect when Bluetooth mic profile switch is complete.
    var onMicReady: (() -> Void)? {
        get { recorder.onMicReady }
        set { recorder.onMicReady = newValue }
    }

    // Transcription state
    private var isTranscribing = false

    init() {
        requestMicrophonePermission()

        recorder.onLevel = { [weak self] db in
            self?.delegate?.audioLevelDidUpdate(db: db)
        }
        recorder.onBufferLimit = { [weak self] in
            print("⚠️ Audio buffer limit reached. Auto-stopping recording.")
            self?.stopRecording()
        }
        recorder.onStartFailure = { [weak self] message in
            self?.abandonSession(reason: message)
        }
        recorder.onEngineLost = { [weak self] message in
            self?.abandonSession(reason: message)
        }
    }

    /// The engine died or never came up. Undo everything `startRecording` set up and tell the UI.
    private func abandonSession(reason: String) {
        AudioDucker.shared.restore()
        MediaRemoteController.shared.resumeIfWePaused()
        removeEscapeKeyMonitor()
        delegate?.transcriptionDidFail(error: reason)
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
        recorder.clearBuffer()
    }

    func toggleRecording() {
        // A stop is always honoured, even mid-start: the recorder serializes its engine
        // work, so the teardown runs once the in-flight start finishes. Dropping it here
        // would strand a live recording with no way to stop it.
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if authStatus == .denied || authStatus == .restricted {
            delegate?.transcriptionDidFail(error: "Microphone access denied. Enable it in System Settings > Privacy & Security > Microphone.")
            showPermissionAlert()
            return
        }

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

        let limit = maxBufferSamples
        let mode = AudioDuckMode.current
        if mode.ducksRecording {
            AudioDucker.shared.duck()
        }
        if mode.pausesMediaDuringRecording {
            // Gate the engine start on the pause snapshot resolving. The AVAudioEngine +
            // Bluetooth profile switch can disrupt Now Playing state mid-snapshot — if the
            // snapshot races ahead, it can read a transient "not playing" and skip the pause,
            // letting the video resume itself when routing settles. `isRecording` still flips
            // immediately, so a release during the gate stops the session rather than being
            // dropped on the floor.
            recorder.start(maxBufferSamples: limit) { launch in
                MediaRemoteController.shared.pause { launch() }
            }
        } else {
            recorder.start(maxBufferSamples: limit)
        }
    }

    private func removeEscapeKeyMonitor() {
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }
    }

    func stopRecording() {
        // AppKit and playback state stay on main; the recorder serializes its teardown behind
        // any start still in flight, so releasing the key mid-warm-up still stops cleanly.
        removeEscapeKeyMonitor()
        AudioDucker.shared.restore()
        MediaRemoteController.shared.resumeIfWePaused()

        recorder.stop { [weak self] samples in
            guard let self = self else { return }
            print("\u{23F9} Recording stopped")
            print("Captured \(samples.count) audio samples")
            Task { @MainActor in
                await self.processRecording(samples: samples)
            }
        }
    }

    /// Cancel an in-flight recording.
    /// - Parameter asSilence: when true, routes to `recordingWasSkippedDueToSilence`
    ///   instead of `recordingWasCancelled`. Used by the auto-record silence
    ///   timeout so the UI shows "skipped due to silence" rather than the
    ///   louder "recording cancelled" notification.
    func cancelRecording(asSilence: Bool = false) {
        AudioDucker.shared.restore()
        MediaRemoteController.shared.resumeIfWePaused()
        removeEscapeKeyMonitor()
        recorder.cancel()

        print(asSilence ? "Recording cancelled \u{2014} silence timeout" : "Recording cancelled")

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
            // Serialize shared-model access with background call transcription.
            let transcriptionResult = try await TranscriptionEngineGate.shared.run {
                try await whisperKit.transcribe(
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
            }

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
            // Serialize shared-model access with background call transcription.
            let transcription = try await TranscriptionEngineGate.shared.run {
                try await transcriber.transcribe(audioSamples: paddedBuffer)
            }
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
            print("No transcription generated (possibly silence)")
            delegate?.recordingWasSkippedDueToSilence()
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

}
