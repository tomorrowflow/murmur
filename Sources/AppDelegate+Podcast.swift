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
    // MARK: - PodcastManagerDelegate

    func podcastDidChangeState(_ state: PodcastState) {
        podcastOverlay?.updateState(state)

        switch state {
        case .playing:
            startWaveformAnimation()
        case .complete:
            stopWaveformAnimation()
            savePodcastToHistoryIfNeeded()
        case .error, .idle:
            stopWaveformAnimation()
        case .disconnected:
            // The podcast finished and the server dropped us — still worth
            // preserving the audio+script locally.
            savePodcastToHistoryIfNeeded()
        default:
            break
        }
    }

    /// Persist the current podcast's script + audio to history. Idempotent per
    /// session so repeated .complete transitions (e.g. after a replay) don't
    /// create duplicate entries.
    private func savePodcastToHistoryIfNeeded() {
        guard let manager = podcastManager, !savedCurrentPodcastToHistory else { return }
        guard let overlay = podcastOverlay else { return }
        let transcript = overlay.viewModel.transcript
        guard !transcript.isEmpty else { return }
        let title = overlay.viewModel.title.isEmpty ? "Podcast" : overlay.viewModel.title
        let markdown = renderPodcastMarkdown(title: title, lines: transcript)
        let audioData = manager.combinedAudioData()
        TranscriptionHistory.shared.addPodcastEntry(
            title: title,
            markdown: markdown,
            audioData: audioData
        )
        savedCurrentPodcastToHistory = true
    }

    private func renderPodcastMarkdown(title: String, lines: [ScriptLine]) -> String {
        var md = "# Podcast: \(title)\n\n"
        for line in lines {
            if line.isInterruptMarker {
                md += "\n---\n*Interrupt: \(line.text)*\n---\n\n"
            } else {
                md += "**\(line.speaker):** \(line.text)\n\n"
            }
        }
        return md
    }

    func podcastDidUpdateTranscript(_ lines: [ScriptLine]) {
        podcastOverlay?.updateTranscript(lines)
    }

    func podcastDidUpdateTitle(_ title: String) {
        podcastOverlay?.updateTitle(title)
    }

    func podcastDidActivateLine(_ lineId: UUID) {
        podcastOverlay?.activateLine(lineId)
    }

    func podcastDidUpdateProgress(stage: String, percent: Int, message: String?) {
        podcastOverlay?.updateProgress(message: message ?? stage, percent: percent)
    }

    func podcastDidUpdateChunkProgress(current: Int, total: Int) {
        podcastOverlay?.updateChunkProgress(current: current, total: total)
    }

    func podcastDidUpdateCacheStatus(canExport: Bool, hasAny: Bool) {
        podcastOverlay?.updateCacheStatus(canExport: canExport, hasAny: hasAny)
    }

    func podcastDidError(_ message: String) {
        stopWaveformAnimation()
        // Error is shown inline in the podcast overlay — no separate notification needed
    }

    // MARK: - Podcast Helpers

    private func ensurePodcastManager() -> PodcastManager {
        if podcastManager == nil {
            let manager = PodcastManager()
            manager.delegate = self
            manager.onRemotePlayPause = { [weak self] in
                guard let manager = self?.podcastManager else { return }
                if manager.state == .complete {
                    manager.replayFromStart()
                } else if manager.isPaused {
                    manager.resumePlayback()
                    self?.podcastOverlay?.viewModel.isPaused = false
                } else {
                    manager.pausePlayback()
                    self?.podcastOverlay?.viewModel.isPaused = true
                }
            }
            podcastManager = manager
        }
        return podcastManager!
    }

    private func ensurePodcastOverlay() -> PodcastOverlayWindow {
        if podcastOverlay == nil {
            podcastOverlay = PodcastOverlayWindow()
            podcastOverlay?.onStop = { [weak self] in
                self?.podcastManager?.stopSession()
                self?.stopWaveformAnimation()
            }
            podcastOverlay?.onPlayPause = { [weak self] in
                guard let manager = self?.podcastManager else { return }
                if manager.state == .complete {
                    manager.replayFromStart()
                } else if manager.isPaused {
                    manager.resumePlayback()
                    self?.podcastOverlay?.viewModel.isPaused = false
                } else {
                    manager.pausePlayback()
                    self?.podcastOverlay?.viewModel.isPaused = true
                }
            }
            podcastOverlay?.onExportAudio = { [weak self] in
                self?.exportPodcastAudio()
            }
            podcastOverlay?.viewModel.onWebSearchToggled = { [weak self] enabled in
                self?.podcastManager?.webSearchEnabled = enabled
            }
        }
        return podcastOverlay!
    }

    private func exportPodcastAudio() {
        let segmentCount = podcastManager?.audioSegmentCount ?? 0
        NSLog("Podcast: preparing audio export (\(segmentCount) segments)")

        // Combine audio off the main thread to avoid blocking UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let audioData = self?.podcastManager?.combinedAudioData() else {
                NSLog("Podcast: no audio data to export")
                return
            }
            NSLog("Podcast: combined \(audioData.count) bytes, showing save panel")

            DispatchQueue.main.async {
                let savePanel = NSSavePanel()
                savePanel.allowedContentTypes = [.wav]
                let title = self?.podcastOverlay?.viewModel.title ?? "Podcast"
                savePanel.nameFieldStringValue = "\(title).wav"
                savePanel.level = .floating + 1

                savePanel.begin { response in
                    if response == .OK, let url = savePanel.url {
                        do {
                            try audioData.write(to: url)
                            NSLog("Podcast: exported audio to \(url.path)")
                        } catch {
                            NSLog("Podcast: failed to export audio: \(error)")
                        }
                    }
                }
            }
        }
    }

    func togglePodcast() {
        let manager = ensurePodcastManager()
        if manager.isSessionActive {
            print("Podcast: stopping session")
            manager.stopSession()
            podcastOverlay?.dismiss()
            stopWaveformAnimation()
        } else {
            // Try selected text first via accessibility, then Cmd+C simulation, then clipboard
            var content = getSelectedTextViaAccessibility() ?? ""
            if content.isEmpty {
                NSLog("Podcast: accessibility API returned no text, trying Cmd+C simulation")
                content = getSelectedTextViaCopy() ?? ""
            }
            if content.isEmpty {
                content = NSPasteboard.general.string(forType: .string) ?? ""
                if !content.isEmpty {
                    NSLog("Podcast: using existing clipboard content (\(content.count) chars)")
                }
            } else {
                NSLog("Podcast: using selected text (\(content.count) chars)")
            }

            guard !content.isEmpty else {
                NSLog("Podcast: no content — neither selection nor clipboard")
                AppNotifier.notify(title: "No Content", body: "Select text or copy a URL/article to clipboard, then press Cmd+Opt+P")
                return
            }

            let overlay = ensurePodcastOverlay()
            overlay.show(state: .connecting)

            // Detect content type
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            let contentType = trimmed.hasPrefix("http") ? "url" : "text"
            let preview = String(trimmed.prefix(200))
            NSLog("Podcast: starting session (type=\(contentType), length=\(content.count))")
            NSLog("Podcast: content preview: \(preview)")
            savedCurrentPodcastToHistory = false
            manager.startSession(contentType: contentType, content: content)
        }
    }

    func startPodcastInterrupt() {
        guard let manager = podcastManager, manager.isSessionActive else {
            resetLeftOptionState()
            return
        }

        if audioManager.isRecording || openClawRecordingManager?.isRecording == true {
            print("Podcast interrupt: blocked - another recording is active")
            resetLeftOptionState()
            return
        }

        print("Podcast interrupt: started (double-tap-hold)")
        // Play tone BEFORE stopping podcast audio — if we stop first, the audio
        // device may not be ready for the tone (same device-wake issue as first words)
        PTTTonePlayer.shared.playStartTone()
        podcastInterruptActive = true
        podcastOverlay?.updateState(.listening)

        // Delay interrupt + recording start slightly so the start tone is audible
        DispatchQueue.main.asyncAfter(deadline: .now() + PTTTonePlayer.shared.startToneDelayBeforeRecording()) { [weak self] in
            guard let self = self, self.podcastInterruptActive else { return }
            manager.beginInterrupt()
            self.stopTranscriptionIndicator()
            self.audioManager.toggleRecording()
        }
    }

    func stopPodcastInterrupt() {
        guard audioManager.isRecording else {
            // Key released before 180ms delay fired — cancel the pending interrupt
            if podcastInterruptActive {
                print("Podcast interrupt: cancelled — released before recording started")
                podcastInterruptActive = false
                // Restore overlay to match the actual manager state
                if let managerState = podcastManager?.state {
                    podcastOverlay?.updateState(managerState)
                }
            }
            return
        }

        print("Podcast interrupt: released — stopping")
        PTTTonePlayer.shared.playInterruptTone()
        audioManager.toggleRecording()
        // transcriptionDidComplete will route to podcastManager.sendInterrupt
    }
}
