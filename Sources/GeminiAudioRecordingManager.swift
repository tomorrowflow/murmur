import Foundation
import AVFoundation
import AppKit
import SharedModels
import CoreAudio

protocol GeminiAudioRecordingManagerDelegate: AnyObject {
    func audioLevelDidUpdate(db: Float)
    func transcriptionDidStart()
    func transcriptionDidComplete(text: String)
    func transcriptionDidFail(error: String)
    func recordingWasCancelled()
    func recordingWasSkippedDueToSilence()
}

class GeminiAudioRecordingManager {
    weak var delegate: GeminiAudioRecordingManagerDelegate?

    // Audio properties
    private var audioEngine: AVAudioEngine!
    private var inputNode: AVAudioInputNode!
    // Tap callback appends on the audio thread while main clears/reads —
    // all access must go through bufferQueue (see AudioTranscriptionManager).
    private var audioBuffer: [Float] = []
    private let bufferQueue = DispatchQueue(label: "com.murmur.gemini.audioBuffer")
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
    private var isStartingRecording = false
    private var escapeKeyMonitor: Any?

    // Gemini transcriber
    private let geminiTranscriber = GeminiAudioTranscriber()

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
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func toggleRecording() {
        // Prevent race condition if called while starting
        if isStartingRecording {
            return
        }

        isRecording.toggle()

        if isRecording {
            startRecording()
        } else {
            stopRecording()
        }
    }

    func startRecording() {
        isStartingRecording = true
        bufferQueue.sync {
            audioBuffer.removeAll()
            autoStopRequested = false
        }
        activeMaxBufferSamples = maxBufferSamples

        // Create fresh audio engine to avoid state issues
        audioEngine = AVAudioEngine()
        inputNode = audioEngine.inputNode
        configureInputDevice()

        // Set up global Escape key monitor to cancel recording
        escapeKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // 53 is the key code for Escape
                if self?.isRecording == true {
                    print("🛑 Gemini recording cancelled by Escape key")
                    DispatchQueue.main.async {
                        self?.cancelRecording()
                    }
                }
            }
        }

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        let resampler = StreamingResampler(targetSampleRate: sampleRate)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            let channelData = buffer.floatChannelData?[0]
            let frameLength = Int(buffer.frameLength)

            if let channelData = channelData {
                // Resample to 16kHz mono
                let samples = resampler?.resample(buffer)
                    ?? Array(UnsafeBufferPointer(start: channelData, count: frameLength))

                self.bufferQueue.async {
                    self.audioBuffer.append(contentsOf: samples)

                    // Prevent memory explosion from runaway recording
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

                // Calculate audio level
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

        do {
            audioEngine.prepare()
            try audioEngine.start()
            print("🎤 Gemini audio recording started...")
            isStartingRecording = false
        } catch {
            print("Failed to start audio engine: \(error)")
            isRecording = false
            isStartingRecording = false
            inputNode.removeTap(onBus: 0)
            AudioDeviceManager.shared.restoreDefaultInputDeviceIfOverridden()
            if let monitor = escapeKeyMonitor {
                NSEvent.removeMonitor(monitor)
                escapeKeyMonitor = nil
            }
            delegate?.transcriptionDidFail(error: "Could not start the microphone: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.reset()
        AudioDeviceManager.shared.restoreDefaultInputDeviceIfOverridden()

        // Remove Escape key monitor
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }

        // Snapshot under the queue: late tap callbacks may still be appending.
        let samples = bufferQueue.sync { audioBuffer }

        print("⏹ Gemini recording stopped")
        print("Captured \(samples.count) audio samples")

        // Process the recording
        processRecording(samples: samples)
    }

    func cancelRecording() {
        isRecording = false
        inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.reset()
        AudioDeviceManager.shared.restoreDefaultInputDeviceIfOverridden()
        bufferQueue.sync { audioBuffer.removeAll() }

        // Remove Escape key monitor
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }

        print("Gemini recording cancelled")

        delegate?.recordingWasCancelled()
    }

    private func processRecording(samples: [Float]) {
        guard !samples.isEmpty else {
            print("No audio recorded")
            delegate?.recordingWasSkippedDueToSilence()
            return
        }

        // Skip extremely short recordings to avoid spurious transcriptions
        let durationSeconds = Double(samples.count) / sampleRate
        let minDurationSeconds: Double = 0.30
        if durationSeconds < minDurationSeconds {
            print("Recording too short (\(String(format: "%.2f", durationSeconds))s). Skipping transcription.")
            delegate?.recordingWasSkippedDueToSilence()
            return
        }

        // Calculate RMS (Root Mean Square) to detect silence
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        let db = 20 * log10(max(rms, 0.00001))

        // Threshold for silence detection
        let silenceThreshold: Float = -55.0

        if db < silenceThreshold {
            print("Audio too quiet (RMS: \(rms), dB: \(db)). Skipping transcription.")
            delegate?.recordingWasSkippedDueToSilence()
            return
        }

        // Start transcription
        delegate?.transcriptionDidStart()

        print("Sending audio to Gemini API for transcription (\(Double(samples.count) / sampleRate) seconds)...")

        // Send to Gemini API
        geminiTranscriber.transcribe(audioBuffer: samples) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let transcription):
                    var trimmed = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        // Apply text replacements from config
                        trimmed = TextReplacements.shared.processText(trimmed)

                        print("✅ Gemini transcription: \"\(trimmed)\"")

                        // Save to history
                        TranscriptionHistory.shared.addEntry(trimmed)

                        // Notify delegate
                        self?.delegate?.transcriptionDidComplete(text: trimmed)
                    } else {
                        print("No transcription generated (possibly silence)")
                        self?.delegate?.recordingWasSkippedDueToSilence()
                    }

                case .failure(let error):
                    print("Gemini transcription error: \(error.localizedDescription)")
                    self?.delegate?.transcriptionDidFail(error: "Gemini transcription failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
