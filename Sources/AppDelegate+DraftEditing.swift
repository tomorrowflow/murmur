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
    // MARK: - Draft Editing

    func toggleDraftEditing() {
        if let manager = draftEditingManager, manager.isActive {
            stopDraftEditing()
            return
        }

        let editorPref = UserDefaults.standard.string(forKey: "draftEditing.editor") ?? "auto"

        let useTextMate: Bool
        let useObsidian: Bool

        switch editorPref {
        case "textmate":
            useTextMate = true
            useObsidian = false
        case "obsidian":
            useTextMate = false
            useObsidian = true
        default: // "auto" — use whichever editor is frontmost
            let frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            if frontApp == "com.macromates.TextMate" {
                useTextMate = true
                useObsidian = false
            } else if frontApp == "md.obsidian" {
                useTextMate = false
                useObsidian = true
            } else {
                // Neither is frontmost — check which is running
                let tm = TextMateAdapter()
                let ob = ObsidianAdapter()
                useTextMate = tm.isRunning()
                useObsidian = !useTextMate && ob.isRunning()
            }
        }

        if useTextMate {
            let cursorLine = TextMateAdapter.getCursorLine()
            Task {
                guard let filePath = await TextMateAdapter.frontDocumentPath() else {
                    AppNotifier.notify(title: "Draft Editing", body: "No markdown file found in TextMate.")
                    return
                }
                await MainActor.run {
                    self.startDraftEditing(filePath: filePath, adapter: TextMateAdapter(), startLine: cursorLine)
                }
            }
        } else if useObsidian {
            Task {
                // Get cursor and file path from the companion plugin (both async-safe)
                let cursorData = await ObsidianAdapter.getCursorAndFile()
                let cursorLine = cursorData?.line
                guard let filePath = cursorData?.file, !filePath.isEmpty else {
                    AppNotifier.notify(title: "Draft Editing", body: "No markdown file found in Obsidian. Make sure the Murmur Bridge plugin is enabled.")
                    return
                }
                await MainActor.run {
                    self.startDraftEditing(filePath: filePath, adapter: ObsidianAdapter(), startLine: cursorLine)
                }
            }
        } else {
            AppNotifier.notify(title: "Draft Editing", body: "No supported editor found. Open a markdown file in TextMate or Obsidian.")
        }
    }

    func startDraftEditing(filePath: String, adapter: EditorAdapter, startLine: Int? = nil) {
        NSLog("DraftEditing: starting session for \(filePath)")

        let manager = DraftEditingManager()
        manager.delegate = self
        draftEditingManager = manager

        let overlay = DraftEditingOverlayWindow()
        overlay.onStop = { [weak self] in
            self?.stopDraftEditing()
        }
        overlay.onPlayPause = { [weak self] in
            self?.draftEditingManager?.togglePause()
            if let isPaused = self?.draftEditingManager?.isPaused {
                self?.draftEditingOverlay?.updatePaused(isPaused)
            }
        }
        overlay.onNext = { [weak self] in
            self?.draftEditingManager?.nextParagraph()
        }
        overlay.onPrev = { [weak self] in
            self?.draftEditingManager?.prevParagraph()
        }
        overlay.onUndoEdit = { [weak self] index in
            self?.draftEditingManager?.undoEdit(historyIndex: index)
        }
        overlay.onExportAudio = { [weak self] in
            guard let data = self?.draftEditingManager?.combinedAudioData() else { return }
            DispatchQueue.main.async {
                let savePanel = NSSavePanel()
                savePanel.allowedContentTypes = [.wav]
                savePanel.nameFieldStringValue = "Draft Editing.wav"
                savePanel.begin { response in
                    if response == .OK, let url = savePanel.url {
                        try? data.write(to: url)
                    }
                }
            }
        }
        draftEditingOverlay = overlay
        overlay.viewModel.editorConnected = true
        overlay.viewModel.targetAppName = adapter.editorName
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == adapter.bundleIdentifier }) {
            overlay.viewModel.targetAppIcon = running.icon
        } else if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: adapter.bundleIdentifier) {
            overlay.viewModel.targetAppIcon = NSWorkspace.shared.icon(forFile: appURL.path)
        }
        overlay.show(state: .loading)

        startWaveformAnimation()
        manager.startSession(filePath: filePath, adapter: adapter, startLine: startLine)
    }

    func stopDraftEditing() {
        draftEditingManager?.stop()
        draftEditingOverlay?.dismiss()
        draftEditingManager = nil
        draftEditingOverlay = nil
        draftEditInterruptActive = false
        stopWaveformAnimation()
    }

    func startDraftEditInterrupt() {
        guard let manager = draftEditingManager, manager.isActive else {
            resetLeftOptionState()
            return
        }

        if audioManager.isRecording || openClawRecordingManager?.isRecording == true {
            print("DraftEdit interrupt: blocked - another recording is active")
            resetLeftOptionState()
            return
        }

        print("DraftEdit interrupt: started (double-tap-hold)")
        PTTTonePlayer.shared.playStartTone()
        draftEditInterruptActive = true
        draftEditingOverlay?.updateState(.listening)

        DispatchQueue.main.asyncAfter(deadline: .now() + PTTTonePlayer.shared.startToneDelayBeforeRecording()) { [weak self] in
            guard let self = self, self.draftEditInterruptActive else { return }
            manager.beginEditInterrupt()
            self.stopTranscriptionIndicator()
            self.audioManager.toggleRecording()
        }
    }

    func stopDraftEditInterrupt() {
        guard audioManager.isRecording else {
            if draftEditInterruptActive {
                print("DraftEdit interrupt: cancelled — released before recording started")
                draftEditInterruptActive = false
                if let managerState = draftEditingManager?.state {
                    draftEditingOverlay?.updateState(managerState)
                }
            }
            return
        }

        print("DraftEdit interrupt: released — stopping")
        PTTTonePlayer.shared.playInterruptTone()
        audioManager.toggleRecording()
    }

    // MARK: - DraftEditingManagerDelegate

    func draftDidChangeState(_ state: DraftEditingState) {
        draftEditingOverlay?.updateState(state)
        switch state {
        case .reading:
            startWaveformAnimation()
        case .idle:
            // Session was stopped (e.g. by Escape key)
            stopDraftEditing()
        case .complete:
            stopWaveformAnimation()
            // Auto-dismiss after 5 seconds, clearing highlights
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                if self?.draftEditingManager?.state == .complete {
                    self?.stopDraftEditing()
                }
            }
        case .error:
            stopWaveformAnimation()
        default:
            break
        }
    }

    func draftDidLoadDocument(_ document: MarkdownDocument) {
        draftEditingOverlay?.loadDocument(document)
    }

    func draftDidActivateParagraph(index: Int, paragraph: MarkdownParagraph) {
        draftEditingOverlay?.activateParagraph(index: index, paragraph: paragraph)
    }

    func draftDidActivateSegment(_ segment: TTSSegment, inParagraph index: Int) {
        // Could update overlay with current segment info if needed
    }

    func draftDidCompleteEdit(paragraphIndex: Int, original: String, replacement: String) {
        draftEditingOverlay?.completeEdit(paragraphIndex: paragraphIndex, original: original, replacement: replacement)
        if let history = draftEditingManager?.editHistory {
            draftEditingOverlay?.updateEditHistory(history)
        }
    }

    func draftDidUpdateStreamingEdit(_ text: String) {
        draftEditingOverlay?.updateStreamingEdit(text)
    }

    func draftDidError(_ message: String) {
        AppNotifier.notify(title: "Draft Editing Error", body: message)
    }
}
