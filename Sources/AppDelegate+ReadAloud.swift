import Cocoa
import SwiftUI
import KeyboardShortcuts
import AVFoundation
import WhisperKit
import SharedModels
import Combine
import ApplicationServices
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

extension AppDelegate {
    private func debugLog(_ msg: String) {
        let logFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("murmur_debug.log")
        let line = "\(Date()): \(msg)\n"
        if let handle = try? FileHandle(forWritingTo: logFile) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? line.data(using: .utf8)?.write(to: logFile)
        }
    }

    func handleReadSelectedTextToggle() {
        debugLog("handleReadSelectedTextToggle called, isCurrentlyPlaying=\(isCurrentlyPlaying), readAloudActive=\(readAloudManager?.isActive ?? false)")
        NSLog("TTS: handleReadSelectedTextToggle called, isCurrentlyPlaying=\(isCurrentlyPlaying), readAloudActive=\(readAloudManager?.isActive ?? false)")

        // If read-aloud session is active, stop it
        if readAloudManager?.isActive == true {
            readAloudManager?.stop()
            readAloudOverlay?.dismiss()
            readAloudManager = nil
            readAloudOverlay = nil
            readAloudInterruptActive = false
            stopWaveformAnimation()
            return
        }

        // If currently playing (legacy TTS), stop the audio
        if isCurrentlyPlaying {
            stopCurrentPlayback()
            return
        }

        // Start interactive read-aloud session
        startReadAloudSession()
    }

    func stopCurrentPlayback() {
        print("🛑 Stopping audio playback")

        // Stop read-aloud session if active
        if readAloudManager?.isActive == true {
            readAloudManager?.stop()
            readAloudOverlay?.dismiss()
            readAloudManager = nil
            readAloudOverlay = nil
            readAloudInterruptActive = false
        }

        // Cancel the current streaming task
        currentStreamingTask?.cancel()
        currentStreamingTask = nil

        // Stop Kokoro NSSound playback
        currentPlayingSound?.stop()
        currentPlayingSound = nil

        // Reset playing state
        isCurrentlyPlaying = false
        stopWaveformAnimation()

        AppNotifier.notify(title: "Audio Stopped", body: "Text-to-speech playback stopped")
    }

    func readSelectedText() {
        guard let selectedText = getSelectedTextViaAccessibility(), !selectedText.isEmpty else {
            NSLog("TTS: no selected text found via Accessibility API")
            AppNotifier.notify(title: "No Text Selected", body: "Please select some text first before using TTS")
            return
        }

        NSLog("TTS: got selected text via Accessibility (\(selectedText.count) chars)")

        isCurrentlyPlaying = true
        startWaveformAnimation()

        currentStreamingTask = Task { [weak self] in
            do {
                // Check for Kokoro inside the task (MainActor-isolated property)
                let ttsManager = await MainActor.run { ModelStateManager.shared.loadedTtsManager }

                if let ttsManager = ttsManager {
                    let wavData = try await ttsManager.synthesize(text: selectedText)
                    guard !Task.isCancelled else { return }

                    let sound = NSSound(data: wavData)
                    await MainActor.run { self?.currentPlayingSound = sound }
                    sound?.play()

                    while sound?.isPlaying == true && !Task.isCancelled {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                } else {
                    AppNotifier.notify(title: "TTS Not Available", body: "No TTS engine loaded")
                }
            } catch is CancellationError {
                NSLog("TTS: playback cancelled")
            } catch {
                NSLog("TTS: error: \(error)")
                AppNotifier.notify(title: "TTS Error", body: error.localizedDescription)
            }

            DispatchQueue.main.async {
                self?.isCurrentlyPlaying = false
                self?.currentStreamingTask = nil
                self?.currentPlayingSound = nil
                self?.stopWaveformAnimation()
            }
        }
    }

    // MARK: - Read Aloud

    func startReadAloudSession() {
        debugLog("startReadAloudSession called")
        let trusted = AXIsProcessTrusted()
        debugLog("AXIsProcessTrusted = \(trusted)")

        let selectedText = getSelectedTextViaAccessibility()
        debugLog("getSelectedTextViaAccessibility returned: \(selectedText == nil ? "nil" : "\(selectedText!.count) chars")")

        guard let selectedText = selectedText, !selectedText.isEmpty else {
            debugLog("ReadAloud: no selected text found, trying clipboard fallback")
            // Try clipboard fallback
            if let clipText = getSelectedTextViaCopy(), !clipText.isEmpty {
                debugLog("ReadAloud: got text via Cmd+C fallback (\(clipText.count) chars)")
                startReadAloudWithText(clipText)
                return
            }
            debugLog("ReadAloud: no text from any method")
            NSLog("ReadAloud: no selected text found")
            AppNotifier.notify(title: "No Text Selected", body: "Please select some text first")
            return
        }

        startReadAloudWithText(selectedText)
    }

    func startReadAloudWithText(_ text: String, skipTranslation: Bool = false, sourceAppOverride: NSRunningApplication? = nil) {
        debugLog("ReadAloud: starting session with \(text.count) chars")
        NSLog("ReadAloud: starting session with \(text.count) chars")

        // Prefer the explicit source (e.g. terminal resolved from the hook's
        // PPID chain) over the current frontmost — so a backgrounded Ghostty
        // recap shows Ghostty's icon, not whatever app the user is using now.
        let sourceApp = sourceAppOverride ?? NSWorkspace.shared.frontmostApplication

        let manager = ReadAloudManager()
        manager.delegate = self
        readAloudManager = manager

        let overlay = ReadAloudOverlayWindow()
        overlay.viewModel.targetAppIcon = sourceApp?.icon
        overlay.viewModel.targetAppName = sourceApp?.localizedName
        overlay.onStop = { [weak self] in
            // Explicit user dismiss cancels any queued auto-record. Without
            // this, a Task that's already past `guard !Task.isCancelled`
            // will still set state=.complete on MainActor after stop() runs,
            // and our state handler would spawn the recording overlay the
            // user just closed.
            self?.pendingAutoRecordAfterReadAloud = false
            self?.recapTargetApp = nil
            self?.recapTargetWindow = nil
            self?.readAloudManager?.stop()
            self?.readAloudOverlay?.dismiss()
            self?.readAloudManager = nil
            self?.readAloudOverlay = nil
            self?.readAloudInterruptActive = false
            self?.stopWaveformAnimation()
            // User closed this session — let the next queued recap proceed.
            self?.drainRecapQueueIfIdle()
        }
        overlay.onPlayPause = { [weak self] in
            guard let self = self, let manager = self.readAloudManager else { return }
            switch manager.state {
            case .awaitingResume:
                manager.resumeFromAwait()
            case .complete:
                manager.startReading(text: manager.fullText)
            case .listening:
                // Cancel interrupt and resume reading
                self.readAloudInterruptActive = false
                if self.audioManager.isRecording {
                    self.audioManager.toggleRecording()
                }
                manager.cancelInterrupt()
            case .reading, .speakingAnswer:
                // Unified pause/resume for both reading and answer playback
                manager.togglePause()
                self.readAloudOverlay?.updatePaused(manager.isPaused)
            case .processingQuestion:
                // Can't pause while waiting for LLM — skip instead
                manager.skipAnswerAndResume()
            default:
                break
            }
        }
        overlay.onWebSearchToggled = { enabled in
            UserDefaults.standard.set(enabled, forKey: "readAloud.webSearchEnabled")
        }
        overlay.onMuteToggled = { [weak self] muted in
            self?.readAloudManager?.isMuted = muted
        }
        overlay.viewModel.isMuted = manager.isMuted
        overlay.onExportAudio = { [weak self] in
            guard let data = self?.readAloudManager?.combinedAudioData() else { return }
            DispatchQueue.main.async {
                let savePanel = NSSavePanel()
                savePanel.allowedContentTypes = [.wav]
                savePanel.nameFieldStringValue = "Read Aloud.wav"
                savePanel.begin { response in
                    if response == .OK, let url = savePanel.url {
                        try? data.write(to: url)
                    }
                }
            }
        }
        readAloudOverlay = overlay
        overlay.show(state: skipTranslation ? .reading : .translating)

        startWaveformAnimation()
        manager.startReading(text: text, skipTranslation: skipTranslation)
    }

    func startReadAloudInterrupt() {
        guard let manager = readAloudManager, manager.isActive else {
            resetLeftOptionState()
            return
        }

        if audioManager.isRecording || openClawRecordingManager?.isRecording == true {
            print("ReadAloud interrupt: blocked - another recording is active")
            resetLeftOptionState()
            return
        }

        print("ReadAloud interrupt: started (double-tap-hold)")
        PTTTonePlayer.shared.playStartTone()
        readAloudInterruptActive = true
        readAloudOverlay?.updateState(.listening)

        DispatchQueue.main.asyncAfter(deadline: .now() + PTTTonePlayer.shared.startToneDelayBeforeRecording()) { [weak self] in
            guard let self = self, self.readAloudInterruptActive else { return }
            manager.beginInterrupt()
            self.stopTranscriptionIndicator()
            self.audioManager.toggleRecording()
        }
    }

    func stopReadAloudInterrupt() {
        guard audioManager.isRecording else {
            if readAloudInterruptActive {
                print("ReadAloud interrupt: cancelled — released before recording started")
                readAloudInterruptActive = false
                if let managerState = readAloudManager?.state {
                    readAloudOverlay?.updateState(managerState)
                }
            }
            return
        }

        print("ReadAloud interrupt: released — stopping")
        PTTTonePlayer.shared.playInterruptTone()
        audioManager.toggleRecording()
    }

    // MARK: - ReadAloudManagerDelegate

    func readAloudDidChangeState(_ state: ReadAloudState) {
        // Handle auto-record FIRST. updateState(.complete) would schedule an
        // async orderFront on the panel that would race past our dismissNow
        // and re-show the overlay just as the recording UI comes up.
        // Auto-record only if the user hasn't already torn down the session.
        // `readAloudManager == nil` means they hit X before the playback task's
        // tail ran; we shouldn't spawn a recording they didn't ask for.
        if state == .complete && pendingAutoRecordAfterReadAloud && readAloudManager != nil {
            pendingAutoRecordAfterReadAloud = false
            readAloudManager?.stop()
            readAloudOverlay?.dismissNow()
            readAloudManager = nil
            readAloudOverlay = nil
            readAloudInterruptActive = false
            stopProcessingAnimation()
            stopWaveformAnimation()
            let targetApp = recapTargetApp
            let targetWindow = recapTargetWindow
            recapTargetApp = nil
            recapTargetWindow = nil
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.startSTTPushToTalk(overrideTargetApp: targetApp, overrideTargetWindow: targetWindow, isAutoRecordAfterRecap: true)
                self.rightOptionState = .recordingToggle
            }
            return
        }

        readAloudOverlay?.updateState(state)
        switch state {
        case .reading, .speakingAnswer:
            // If the recap processing sweep is running, keep it — .reading
            // fires before any audio is synthesized, and the level meter
            // would just show flat bars. The meter takes over on the first
            // audible sentence (readAloudDidActivateSentence).
            if processingAnimationTimer == nil {
                startWaveformAnimation()
            }
        case .complete, .error, .idle:
            stopProcessingAnimation()
            stopWaveformAnimation()
        default:
            break
        }
    }

    func readAloudDidUpdateSentences(_ sentences: [String]) {
        readAloudOverlay?.updateSentences(sentences)
    }

    func readAloudDidActivateSentence(index: Int) {
        // Audio is audible from here — switch the status bar from the
        // processing sweep to the live level meter. Idempotent per sentence.
        startWaveformAnimation()
        readAloudOverlay?.activateSentence(index: index)
    }

    func readAloudDidInsertQA(question: String, answer: String, afterSentenceIndex: Int) {
        readAloudOverlay?.insertQA(question: question, answer: answer, afterSentenceIndex: afterSentenceIndex)
    }

    func readAloudDidUpdateStreamingAnswer(_ text: String) {
        readAloudOverlay?.updateStreamingAnswer(text)
    }

    func readAloudDidUpdateTranslationStatus(_ status: String) {
        readAloudOverlay?.updateTranslationStatus(status)
    }

    func readAloudDidError(_ message: String) {
        AppNotifier.notify(title: "Read Aloud Error", body: message)
    }
}
