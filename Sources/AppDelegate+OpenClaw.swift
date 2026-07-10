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
    func connectOpenClaw(url: String, token: String, password: String?, sessionKey: String) {
        // Tear down existing connection if any
        disconnectOpenClaw()

        let manager = OpenClawManager(url: url, token: token, password: password, sessionKey: sessionKey)
        openClawManager = manager
        openClawRecordingManager = OpenClawRecordingManager(
            openClawManager: manager,
            streamingPlayer: streamingPlayer,
            audioCollector: audioCollector
        )
        openClawRecordingManager?.delegate = self
        // Refresh the status bar hint whenever (dis)connection or auth state
        // shifts so the user can tell at a glance whether OpenClaw is ready.
        manager.onStatusChange = { [weak self] _, _, _ in
            DispatchQueue.main.async { self?.refreshOpenClawStatusHint() }
        }
        if openClawOverlay == nil {
            openClawOverlay = OpenClawOverlayWindow()
            openClawOverlay?.onCancel = { [weak self] in
                // X button: cut everything OpenClaw is doing — any active
                // recording, any in-flight TTS, and any auto-mic that's
                // queued or open.
                self?.openClawRecordingManager?.cancelRecording()
                self?.openClawRecordingManager?.cancelStreamingTTS()
                self?.cancelOpenClawAutoMicPending()
                self?.stopWaveformAnimation()
            }
        }
        manager.connect()
        print("OpenClaw: initialized (url=\(url))")
    }

    func disconnectOpenClaw() {
        // shutdown() invalidates the URLSession — without it the session
        // retains the manager forever and every settings re-save leaks one.
        openClawManager?.shutdown()
        openClawManager = nil
        openClawRecordingManager = nil
    }

    // MARK: - OpenClawRecordingManagerDelegate

    func openClawAudioLevelDidUpdate(db: Float) {
        AudioLevelMonitor.shared.update(db: db)
        updateStatusBarWithLevel(db: db)
        openClawOverlay?.show(state: bluetoothWarmingUp ? .connecting : .listening)
        // refreshOpenClawStatusHint is idempotent and cheap — call once so
        // the menu reflects "listening" as soon as the first frame arrives.
        // Subsequent frames are harmless no-ops on the menu (NSMenuItem just
        // stores the new title; if equal, AppKit doesn't redraw).
        refreshOpenClawStatusHint()
        // Drive auto-mic silence detection if this audio level update is
        // arriving from a follow-up recording we opened automatically.
        if openClawAutoMicActive {
            handleOpenClawAutoMicLevel(db: db)
        }
    }

    func openClawDidStartProcessing() {
        startTranscriptionIndicator()
        openClawOverlay?.show(state: .processing)
        // Once the user's question is on the wire, the auto-mic round is
        // over — clear flags. The next round will re-arm when TTS finishes.
        clearOpenClawAutoMicTimers()
        openClawAutoMicActive = false
        openClawAutoMicVoiceDetected = false
        refreshOpenClawStatusHint()
    }

    func openClawDidReceiveResponse(text: String) {
        startWaveformAnimation()
        openClawOverlay?.updateResponse(text)
    }

    func openClawDidFinish(question: String, answer: String) {
        stopWaveformAnimation()
        openClawOverlay?.updateResponse(answer)
        openClawOverlay?.complete()
        refreshOpenClawStatusHint()
    }

    func openClawDidFail(error: String) {
        stopWaveformAnimation()
        openClawOverlay?.showError(error)
        cancelOpenClawAutoMicPending()
        refreshOpenClawStatusHint()
    }

    func openClawRecordingWasCancelled() {
        stopWaveformAnimation()
        openClawOverlay?.dismiss()
        cancelOpenClawAutoMicPending()
        refreshOpenClawStatusHint()
    }

    func openClawTTSDidStart() {
        openClawOverlay?.ttsStarted()
        // If something is queued to auto-fire (e.g. a re-arm scheduled before
        // a fresh delta arrived), stand it down — the new TTS will trigger
        // its own auto-mic on completion.
        cancelOpenClawAutoMicPending()
        refreshOpenClawStatusHint()
    }

    func openClawTTSDidFinish() {
        openClawOverlay?.ttsFinished()
        refreshOpenClawStatusHint()
        armOpenClawAutoMicAfterTTS()
    }

    // MARK: - OpenClaw Auto-Mic Loop

    /// Schedule the follow-up mic to open shortly after TTS ends, gated by the
    /// `ptt.openClaw.autoRecordAfterTTS` setting and current OpenClaw state.
    /// The deferred work item plays a distinct chirp and starts recording so
    /// the user can keep the conversation going hands-free.
    private func armOpenClawAutoMicAfterTTS() {
        let enabled = UserDefaults.standard.object(forKey: "ptt.openClaw.autoRecordAfterTTS") as? Bool ?? true
        guard enabled else { return }
        guard let recordingManager = openClawRecordingManager else { return }
        // Don't auto-mic if anything else is in flight: another recording,
        // a still-processing chat (a fresh delta could fire a new TTS), STT
        // PTT, podcast, draft edit, or read-aloud.
        if recordingManager.isRecording || recordingManager.isProcessing || recordingManager.isAnswering { return }
        if audioManager.isRecording { return }
        if podcastManager?.isSessionActive == true { return }
        if draftEditingManager?.isActive == true { return }
        if readAloudManager?.isActive == true { return }
        // Belt-and-suspenders: if the user is mid-double-tap-hold on left
        // Option, a manual recording is about to begin (or just began but
        // hasn't flipped isRecording yet because of the start-tone delay).
        // Auto-arming here would race the manual recording and stop it
        // prematurely — exactly the "recording restarted at zero" bug.
        if leftOptionState == .recording || leftOptionState == .recordingToggle { return }
        // Cancel any prior pending auto-mic — we're the most recent end of
        // speech, take over the slot.
        cancelOpenClawAutoMicPending()

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Re-validate state at fire time — the user may have started
            // something else during the inter-TTS gap.
            guard let recordingManager = self.openClawRecordingManager else { return }
            if recordingManager.isRecording || recordingManager.isProcessing || recordingManager.isAnswering { return }
            if self.audioManager.isRecording { return }
            self.fireOpenClawAutoMic()
        }
        openClawAutoMicFireWorkItem = work
        refreshOpenClawStatusHint()
        // Distinct three-note chirp so the user can tell the system opened
        // the mic, not them. Tone is fired now so the recording starts in
        // sync with its tail.
        PTTTonePlayer.shared.playOpenClawFollowUpTone()
        let delay = PTTTonePlayer.shared.openClawFollowUpToneDelayBeforeRecording()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fireOpenClawAutoMic() {
        guard let recordingManager = openClawRecordingManager else { return }
        print("OpenClaw auto-mic: opening follow-up recording")
        openClawAutoMicActive = true
        openClawAutoMicVoiceDetected = false
        openClawAutoMicFireWorkItem = nil
        openClawOverlay?.show(state: .listening)
        refreshOpenClawStatusHint()
        // Dead-start safety: if the user was just listening passively and
        // didn't intend to reply, silently close the mic after a short window.
        openClawAutoMicDeadStartTimer?.invalidate()
        openClawAutoMicDeadStartTimer = Timer.scheduledTimer(withTimeInterval: Self.openClawAutoMicDeadStartSeconds, repeats: false) { [weak self] _ in
            guard let self = self, self.openClawAutoMicActive, !self.openClawAutoMicVoiceDetected else { return }
            print("OpenClaw auto-mic: dead-start timeout — silently cancelling")
            self.openClawAutoMicActive = false
            self.openClawAutoMicVoiceDetected = false
            self.clearOpenClawAutoMicTimers()
            self.openClawRecordingManager?.cancelRecording()
        }
        recordingManager.toggleRecording()
    }

    /// Drive the per-utterance silence auto-stop. Called on every audio level
    /// frame while auto-mic is active. First voice frame disarms the
    /// dead-start safety; subsequent silence after voice arms the stop timer.
    private func handleOpenClawAutoMicLevel(db: Float) {
        let isVoice = db > Self.openClawAutoMicVoiceThresholdDb
        if isVoice {
            if !openClawAutoMicVoiceDetected {
                openClawAutoMicVoiceDetected = true
                openClawAutoMicDeadStartTimer?.invalidate()
                openClawAutoMicDeadStartTimer = nil
            }
            // Reset silence timer on every voice frame so it only fires after
            // a sustained pause.
            openClawAutoMicSilenceTimer?.invalidate()
            openClawAutoMicSilenceTimer = nil
        } else if openClawAutoMicVoiceDetected, openClawAutoMicSilenceTimer == nil {
            openClawAutoMicSilenceTimer = Timer.scheduledTimer(withTimeInterval: Self.openClawAutoMicSilenceSeconds, repeats: false) { [weak self] _ in
                guard let self = self, self.openClawAutoMicActive, self.openClawAutoMicVoiceDetected else { return }
                guard let recordingManager = self.openClawRecordingManager, recordingManager.isRecording else { return }
                print("OpenClaw auto-mic: silence after speech — stopping and transcribing")
                self.openClawAutoMicActive = false
                self.clearOpenClawAutoMicTimers()
                PTTTonePlayer.shared.playStopTone()
                // toggleRecording on a recording manager → stopRecording →
                // transcribeAndSend → openClawManager.sendChat. The next TTS
                // round, when it ends, will arm auto-mic again.
                recordingManager.toggleRecording()
            }
        }
    }

    /// Cancel any deferred auto-mic fire that hasn't started recording yet.
    /// Safe to call any time the user takes manual action (left-Option PTT,
    /// Cmd+Opt+O, X button, escape).
    func cancelOpenClawAutoMicPending() {
        openClawAutoMicFireWorkItem?.cancel()
        openClawAutoMicFireWorkItem = nil
        clearOpenClawAutoMicTimers()
        openClawAutoMicActive = false
        openClawAutoMicVoiceDetected = false
        refreshOpenClawStatusHint()
    }

    private func clearOpenClawAutoMicTimers() {
        openClawAutoMicDeadStartTimer?.invalidate()
        openClawAutoMicDeadStartTimer = nil
        openClawAutoMicSilenceTimer?.invalidate()
        openClawAutoMicSilenceTimer = nil
    }
}
