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
    // MARK: - Double-Tap-and-Hold Option Keys (Push-to-Talk)
    // Left Option → OpenClaw, Right Option → STT Recording

    func setupOptionDoubleTapMonitor() {
        // Global monitor captures events when other apps are focused (normal for a menu bar app).
        // Local monitor captures events when Murmur itself is focused (rare — settings window, etc).
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard let self = self else { return }
            self.handleOptionKeyEvent(event)
        }

        optionDoubleTapMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            // Global monitor fires on a non-main thread; dispatch to main
            // to avoid Swift exclusivity violations with the local monitor.
            DispatchQueue.main.async { handler(event) }
        }

        // Local monitor must return the event to avoid swallowing it
        optionDoubleTapLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event  // pass through — don't consume
        }
    }

    private func handleOptionKeyEvent(_ event: NSEvent) {
        let leftOptionKeyCode: UInt16 = 58
        let rightOptionKeyCode: UInt16 = 61

        let optionDown = event.modifierFlags.contains(.option)

        // Ignore if other modifiers are held (Cmd, Ctrl, Shift) — don't interfere with shortcuts.
        // Hands-free (toggle) recordings survive: the user has their hands back on the keyboard
        // and may well hit Cmd+Tab, which would otherwise strand the recording in .idle with no
        // Option press able to stop it.
        let otherModifiers: NSEvent.ModifierFlags = [.command, .control, .shift]
        if !event.modifierFlags.intersection(otherModifiers).isEmpty {
            if !leftOptionState.isHandsFreeRecording { self.resetLeftOptionState() }
            if !rightOptionState.isHandsFreeRecording { self.resetRightOptionState() }
            return
        }

        // The global and local monitors can both see the same physical event. Two distinct key
        // events never share a hardware timestamp, so (keyCode, timestamp) identifies one press
        // uniquely — process the first delivery, drop the echo.
        if event.timestamp > 0 {
            let key = OptionEventKey(keyCode: event.keyCode, timestamp: event.timestamp)
            if lastOptionEventKey == key { return }
            lastOptionEventKey = key
        }

        // Timestamp the event, not the moment we got around to handling it. The global monitor
        // hands events to the main queue asynchronously, and starting the audio engine on a
        // Bluetooth mic blocks main for 1-2s during the A2DP→HFP switch. Sampling the clock here
        // would charge that stall to the user's hold duration and misread a quick double-tap
        // release as hold-to-record. `event.timestamp` shares systemUptime's epoch.
        let now = event.timestamp > 0 ? event.timestamp : ProcessInfo.processInfo.systemUptime

        let openClawPTTEnabled = UserDefaults.standard.object(forKey: "ptt.openClaw.enabled") as? Bool ?? true
        let podcastActive = self.podcastManager?.isSessionActive == true
        let readAloudActive = self.readAloudManager?.isActive == true
        let draftEditActive = self.draftEditingManager?.isActive == true
        if event.keyCode == leftOptionKeyCode && (openClawPTTEnabled || podcastActive || readAloudActive || draftEditActive) {
            self.handleDoubleTapHold(
                optionDown: optionDown, now: now,
                state: &self.leftOptionState,
                firstPressTime: &self.leftOptionFirstPressTime,
                firstReleaseTime: &self.leftOptionFirstReleaseTime,
                handsFreeArmedAt: &self.leftOptionHandsFreeArmedAt,
                resetTimer: &self.leftOptionResetTimer,
                onStart: {
                    if self.podcastManager?.isSessionActive == true {
                        self.startPodcastInterrupt()
                    } else if self.draftEditingManager?.isActive == true {
                        self.startDraftEditInterrupt()
                    } else if self.readAloudManager?.isActive == true {
                        self.startReadAloudInterrupt()
                    } else {
                        self.startOpenClawPushToTalk()
                    }
                },
                onStop: {
                    if self.podcastInterruptActive {
                        self.stopPodcastInterrupt()
                    } else if self.draftEditInterruptActive {
                        self.stopDraftEditInterrupt()
                    } else if self.readAloudInterruptActive {
                        self.stopReadAloudInterrupt()
                    } else {
                        self.stopOpenClawPushToTalk()
                    }
                },
                onReset: { self.resetLeftOptionState() }
            )
        } else if event.keyCode == rightOptionKeyCode && UserDefaults.standard.object(forKey: "ptt.stt.enabled") as? Bool ?? true {
            self.handleDoubleTapHold(
                optionDown: optionDown, now: now,
                state: &self.rightOptionState,
                firstPressTime: &self.rightOptionFirstPressTime,
                firstReleaseTime: &self.rightOptionFirstReleaseTime,
                handsFreeArmedAt: &self.rightOptionHandsFreeArmedAt,
                resetTimer: &self.rightOptionResetTimer,
                onStart: { self.startSTTPushToTalk() },
                onStop: { self.stopSTTPushToTalk() },
                onReset: { self.resetRightOptionState() }
            )
        }
    }

    /// One run-loop turn, so a freshly-ordered-front overlay panel commits its
    /// first frame before the caller blocks main starting the audio engine.
    static let overlayPaintDelay: TimeInterval = 0.05

    /// Longest a single tap may last before it stops counting as a tap.
    private static let tapMaxDuration: TimeInterval = 0.3
    /// Longest gap between the two taps of a double-tap.
    private static let doubleTapMaxGap: TimeInterval = 0.4
    /// How long the *second* tap must be held to mean "hold-to-record" rather
    /// than "start hands-free recording". Measured releases of an intentional
    /// double-tap run 0.28-0.9s, while a real hold runs for as long as the user
    /// speaks — seconds. Sits in the empty gap between those two populations.
    private static let handsFreeReleaseWindow: TimeInterval = 1.0

    private func handleDoubleTapHold(
        optionDown: Bool, now: TimeInterval,
        state: inout OptionDoubleTapState,
        firstPressTime: inout TimeInterval,
        firstReleaseTime: inout TimeInterval,
        handsFreeArmedAt: inout TimeInterval,
        resetTimer: inout Timer?,
        onStart: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onReset: @escaping () -> Void
    ) {
        switch state {
        case .idle:
            if optionDown {
                state = .firstPress
                firstPressTime = now
                resetTimer?.invalidate()
                resetTimer = Timer.scheduledTimer(withTimeInterval: Self.tapMaxDuration, repeats: false) { _ in
                    onReset()
                }
            }

        case .firstPress:
            if !optionDown {
                let tapDuration = now - firstPressTime
                if tapDuration < Self.tapMaxDuration {
                    state = .firstRelease
                    firstReleaseTime = now
                    resetTimer?.invalidate()
                    resetTimer = Timer.scheduledTimer(withTimeInterval: Self.doubleTapMaxGap, repeats: false) { _ in
                        onReset()
                    }
                } else {
                    onReset()
                }
            }

        case .firstRelease:
            if optionDown {
                let gap = now - firstReleaseTime
                if gap < Self.doubleTapMaxGap {
                    resetTimer?.invalidate()
                    resetTimer = nil
                    firstPressTime = now  // track second press time for hold detection
                    state = .recording
                    onStart()
                } else {
                    onReset()
                }
            }

        case .recording:
            if !optionDown {
                let holdDuration = now - firstPressTime
                let handsFree = holdDuration < Self.handsFreeReleaseWindow
                print(String(format: "PTT: second-tap held %.3fs → %@", holdDuration, handsFree ? "toggle (hands-free)" : "hold (stop)"))
                if handsFree {
                    // Quick release after double-tap: toggle mode — recording continues
                    state = .recordingToggle
                    handsFreeArmedAt = now
                } else {
                    // Held key: classic hold-to-record — stop on release
                    state = .idle
                    onStop()
                }
            }

        case .recordingToggle:
            if optionDown {
                // A press stops recording — but it must have *happened* after the
                // release that armed hands-free mode. The global monitor hands
                // events to the main queue asynchronously while the local monitor
                // runs inline, so a DOWN can be delivered after its own UP once
                // the audio engine stalls main. Such an event carries an earlier
                // hardware timestamp than the UP, and cannot be a stop request.
                guard now > handsFreeArmedAt else {
                    print(String(format: "PTT: ignoring out-of-order DOWN (ts %.3f <= armed %.3f)", now, handsFreeArmedAt))
                    return
                }
                state = .idle
                onStop()
            }
        }
    }

    func resetLeftOptionState() {
        leftOptionState = .idle
        leftOptionResetTimer?.invalidate()
        leftOptionResetTimer = nil
    }

    func resetRightOptionState() {
        rightOptionState = .idle
        rightOptionResetTimer?.invalidate()
        rightOptionResetTimer = nil
    }

    private func startOpenClawPushToTalk() {
        if audioManager.isRecording {
            print("OpenClaw PTT: blocked - audio recording is active")
            DispatchQueue.main.async { self.resetLeftOptionState() }
            return
        }

        guard let recordingManager = openClawRecordingManager else {
            print("OpenClaw PTT: not configured")
            DispatchQueue.main.async { self.resetLeftOptionState() }
            return
        }

        if recordingManager.isRecording {
            print("OpenClaw PTT: already recording")
            DispatchQueue.main.async { self.resetLeftOptionState() }
            return
        }

        // Interrupt-during-speech: if OpenClaw is currently speaking its
        // answer (or between sentences with more queued), a double-tap should
        // cut the audio and immediately open the mic for a follow-up — same
        // ergonomic as the podcast interrupt. The streamed answer text stays
        // in the overlay/history (the in-flight chat is allowed to continue
        // server-side; its tail tokens are dropped because currentRunId will
        // change once the next sendChat fires).
        let interruptEnabled = UserDefaults.standard.object(forKey: "ptt.openClaw.interruptDuringTTS") as? Bool ?? true
        if recordingManager.isAnswering {
            guard interruptEnabled else {
                print("OpenClaw PTT: TTS active but interrupt disabled in settings")
                DispatchQueue.main.async { self.resetLeftOptionState() }
                return
            }
            print("OpenClaw PTT: interrupting active TTS to record follow-up")
            recordingManager.cancelStreamingTTS()
            // Cancel any pending auto-mic that was about to fire when TTS
            // finishes — we're taking that slot manually.
            cancelOpenClawAutoMicPending()
        } else if recordingManager.isProcessing {
            // Chat is in flight but no audio yet — block to avoid racing the
            // first delta. (User can still interrupt once TTS starts.)
            print("OpenClaw PTT: chat in flight, no audio yet — wait for response to start")
            DispatchQueue.main.async { self.resetLeftOptionState() }
            return
        }

        print("OpenClaw PTT: started (double-tap-hold)")
        stopTranscriptionIndicator()

        if AudioDeviceManager.shared.isCurrentInputDeviceBluetooth() {
            // Bluetooth devices (AirPods) switch from A2DP to HFP profile when
            // the mic starts. Both input AND output are unavailable during this
            // switch (can take 1-2s). Wait for the first audio buffer callback
            // (proving the profile switch is complete) before playing the tone.
            print("OpenClaw PTT: Bluetooth mic detected — waiting for profile switch")
            bluetoothWarmingUp = true
            recordingManager.onMicReady = { [weak self] in
                // Input is live, but give HFP output path a moment to stabilize
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    recordingManager.clearAudioBuffer()
                    self?.bluetoothWarmingUp = false
                    PTTTonePlayer.shared.playStartTone()
                    print("OpenClaw PTT: Bluetooth mic ready — tone played")
                }
            }
            recordingManager.toggleRecording()
        } else {
            PTTTonePlayer.shared.playStartTone()
            let startWork = DispatchWorkItem { [weak self] in
                self?.openClawPendingStartWorkItem = nil
                recordingManager.toggleRecording()
            }
            openClawPendingStartWorkItem = startWork
            DispatchQueue.main.asyncAfter(
                deadline: .now() + PTTTonePlayer.shared.startToneDelayBeforeRecording(),
                execute: startWork
            )
        }
    }

    private func stopOpenClawPushToTalk() {
        if let pending = openClawPendingStartWorkItem {
            // Released during the tone-delay window, before the engine
            // started: cancel the deferred start instead of dropping the stop.
            pending.cancel()
            openClawPendingStartWorkItem = nil
            print("OpenClaw PTT: released before recording started — cancelling start")
            return
        }

        guard let recordingManager = openClawRecordingManager, recordingManager.isRecording else {
            return
        }

        print("OpenClaw PTT: released — stopping")
        PTTTonePlayer.shared.playStopTone()
        recordingManager.toggleRecording()
    }

    func startSTTPushToTalk(overrideTargetApp: NSRunningApplication? = nil, overrideTargetWindow: AXUIElement? = nil, isAutoRecordAfterRecap: Bool = false) {
        if openClawRecordingManager?.isRecording == true || openClawRecordingManager?.isProcessing == true {
            print("STT PTT: blocked - OpenClaw recording is active")
            DispatchQueue.main.async { self.resetRightOptionState() }
            return
        }

        // If Read Aloud is playing, treat PTT as an interrupt: stop playback
        // and dismiss its overlay before we start recording.
        if readAloudManager?.isActive == true {
            print("STT PTT: interrupting active Read Aloud session")
            readAloudManager?.stop()
            readAloudOverlay?.dismissNow()
            readAloudManager = nil
            readAloudOverlay = nil
            readAloudInterruptActive = false
            stopWaveformAnimation()
        }

        if audioManager.isRecording {
            print("STT PTT: already recording")
            DispatchQueue.main.async { self.resetRightOptionState() }
            return
        }

        print(isAutoRecordAfterRecap ? "STT PTT: started (auto-record after recap)" : "STT PTT: started (double-tap-hold)")
        sttStartGeneration &+= 1
        let generation = sttStartGeneration
        sttPushToTalkActive = true
        sttPushToTalkStartTime = Date()
        sttAutoRecordAfterRecap = isAutoRecordAfterRecap
        sttHasCapturedVoice = false
        cancelUtteranceSilenceTimer()
        if let app = overrideTargetApp {
            sttPushToTalkTargetApp = app
            sttPushToTalkTargetWindow = overrideTargetWindow
            print("STT PTT: using pre-captured target: \(app.localizedName ?? "Unknown")")
        } else {
            sttPushToTalkTargetApp = NSWorkspace.shared.frontmostApplication
            // Capture the specific focused window via Accessibility API
            if let app = sttPushToTalkTargetApp {
                let appElement = AXUIElementCreateApplication(app.processIdentifier)
                var windowValue: AnyObject?
                if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success {
                    sttPushToTalkTargetWindow = (windowValue as! AXUIElement)
                    var titleValue: AnyObject?
                    if AXUIElementCopyAttributeValue(sttPushToTalkTargetWindow!, kAXTitleAttribute as CFString, &titleValue) == .success {
                        print("STT PTT: captured target window: \"\(titleValue as? String ?? "")\" in \(app.localizedName ?? "Unknown")")
                    } else {
                        print("STT PTT: captured target window (untitled) in \(app.localizedName ?? "Unknown")")
                    }
                } else {
                    sttPushToTalkTargetWindow = nil
                    print("STT PTT: captured target app: \(app.localizedName ?? "Unknown") (no focused window)")
                }
            }
        }
        stopTranscriptionIndicator()

        // Show the overlay immediately so the keystroke feels responsive,
        // regardless of audio device. State starts at .connecting and is
        // explicitly transitioned to .listening once the engine is actually
        // capturing audio — no longer waiting for the first audio buffer to
        // arrive via audioLevelDidUpdate (which on BT can be 1-2s late).
        showSTTOverlayImmediately(state: .connecting)

        if AudioDeviceManager.shared.isCurrentInputDeviceBluetooth() {
            // Bluetooth devices (AirPods) switch from A2DP to HFP profile when
            // the mic starts. Both input AND output are unavailable during this
            // switch (can take 1-2s). Wait for the first audio buffer callback
            // (proving the profile switch is complete) before playing the tone.
            print("STT PTT: Bluetooth mic detected — waiting for profile switch")
            bluetoothWarmingUp = true
            audioManager.onMicReady = { [weak self] in
                // Input is live, but give HFP output AND input paths a moment
                // to fully stabilize. Empirically AirPods need ~1s after the
                // first input buffer before voice capture is reliable; with
                // less the user perceives the start tone but their first word
                // still gets clipped. Overlay stays .connecting through this
                // entire window so the UI mirrors what's actually happening.
                //
                // This chain runs ~2.4s after the key press. The session it
                // belongs to may already be over — a stopped recording, or a
                // newer press that superseded it. Every hop re-checks the
                // generation, or a dead session resurrects its own overlay on
                // top of the live one.
                guard self?.sttStartGeneration == generation else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    guard let self = self, self.sttStartGeneration == generation else { return }
                    self.audioManager.clearAudioBuffer()
                    self.bluetoothWarmingUp = false
                    PTTTonePlayer.shared.playStartTone()
                    DispatchQueue.main.asyncAfter(deadline: .now() + PTTTonePlayer.shared.startToneDelayBeforeRecording()) { [weak self] in
                        guard let self = self, self.sttStartGeneration == generation else { return }
                        print("STT PTT: Bluetooth mic ready — listening")
                        self.transitionSTTOverlayToListening()
                        self.armSilenceTimeoutIfNeeded()
                    }
                }
            }
            // Yield one run-loop turn so the overlay actually paints before
            // `toggleRecording()` starts the engine and stalls main for the
            // 1-2s A2DP→HFP switch. Cancellable, so a release during the gap
            // aborts the start rather than orphaning a recording. The built-in
            // mic path below already gets this for free via its tone delay —
            // which is the whole reason it felt instant and Bluetooth did not.
            let startWork = DispatchWorkItem { [weak self] in
                guard let self = self, self.sttStartGeneration == generation else { return }
                self.sttPendingStartWorkItem = nil
                self.audioManager.toggleRecording()
            }
            sttPendingStartWorkItem = startWork
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.overlayPaintDelay, execute: startWork)
        } else {
            PTTTonePlayer.shared.playStartTone()
            let startWork = DispatchWorkItem { [weak self] in
                guard let self = self, self.sttStartGeneration == generation else { return }
                self.sttPendingStartWorkItem = nil
                self.audioManager.toggleRecording()
                self.transitionSTTOverlayToListening()
                self.armSilenceTimeoutIfNeeded()
            }
            sttPendingStartWorkItem = startWork
            DispatchQueue.main.asyncAfter(
                deadline: .now() + PTTTonePlayer.shared.startToneDelayBeforeRecording(),
                execute: startWork
            )
        }
    }

    /// Show the STT overlay immediately on PTT trigger so the keystroke
    /// feels responsive — even before the audio engine has produced its
    /// first sample. Respects cursor-anchored overlay setting and skips
    /// when an interrupt overlay (podcast/read-aloud/draft-edit) owns
    /// the screen.
    private func showSTTOverlayImmediately(state: AudioTranscriptionOverlayState) {
        guard !podcastInterruptActive,
              !readAloudInterruptActive,
              !draftEditInterruptActive,
              !useCursorAnchoredOverlay else { return }
        let overlay = ensureAudioOverlay()
        if overlay.viewModel.targetAppIcon == nil {
            overlay.viewModel.targetAppIcon = sttPushToTalkTargetApp?.icon
            overlay.viewModel.targetAppName = sttPushToTalkTargetApp?.localizedName
            overlay.viewModel.targetWindowDetail = Self.targetWindowDetail(for: sttPushToTalkTargetWindow)
        }
        overlay.show(state: state)
    }

    /// Move the STT overlay from .connecting → .listening once the audio
    /// engine is confirmed running. Driven from explicit start callbacks
    /// rather than the audio-level path so the transition is tied to
    /// engine state, not the first non-silent buffer.
    private func transitionSTTOverlayToListening() {
        guard !podcastInterruptActive,
              !readAloudInterruptActive,
              !draftEditInterruptActive,
              !useCursorAnchoredOverlay else { return }
        guard audioManager.isRecording else { return }
        audioOverlay?.show(state: .listening)
    }

    /// Arm the dead-start silence timer for the recap auto-record flow. Fires
    /// once, cancels the recording if the user never speaks. Generalized
    /// per-utterance auto-stop is handled separately in `audioLevelDidUpdate`
    /// via `armUtteranceSilenceTimerIfEnabled`.
    private func armSilenceTimeoutIfNeeded() {
        sttSilenceTimeoutTimer?.invalidate()
        guard sttAutoRecordAfterRecap else { return }
        sttSilenceTimeoutTimer = Timer.scheduledTimer(withTimeInterval: Self.sttDeadStartTimeoutSeconds, repeats: false) { [weak self] _ in
            guard let self = self, self.sttAutoRecordAfterRecap, self.audioManager.isRecording else { return }
            print("STT PTT: dead-start timeout — no voice in \(Self.sttDeadStartTimeoutSeconds)s, cancelling")
            self.sttSilenceTimeoutTimer = nil
            self.audioManager.cancelRecording(asSilence: true)
        }
    }

    /// User-configurable: stop the recording (and transcribe) after N seconds
    /// of silence following at least one detected voice sample. Disabled by
    /// default. Distinct from the recap dead-start timeout, which discards.
    private var sttAutoStopEnabled: Bool {
        UserDefaults.standard.bool(forKey: "ptt.autoStopAfterSilence")
    }
    private var sttAutoStopSilenceSeconds: TimeInterval {
        let raw = UserDefaults.standard.double(forKey: "ptt.silenceTimeoutSeconds")
        return raw > 0 ? raw : 5.0
    }


    /// Called from `audioLevelDidUpdate` whenever voice is detected. Resets
    /// the silence countdown — recording continues while the user is talking
    /// and stops N seconds after they fall silent.
    func armUtteranceSilenceTimerIfEnabled() {
        guard sttAutoStopEnabled else { return }
        guard audioManager.isRecording else { return }
        // Skip auto-stop while the user is physically holding the Option key
        // (hold-to-record). They can release any time, so silence detection
        // would just cut them off mid-thought. Toggle mode (.recordingToggle)
        // is hands-off and still benefits from the timer.
        if rightOptionState == .recording { return }
        sttAutoStopTimer?.invalidate()
        let timeout = sttAutoStopSilenceSeconds
        sttAutoStopTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            guard let self = self, self.audioManager.isRecording else { return }
            print("STT PTT: utterance silence timeout — \(timeout)s without voice, stopping & transcribing")
            self.sttAutoStopTimer = nil
            // Reset the PTT state machine so the post-stop overlay/UI behaves
            // identically to a manual third-tap stop.
            self.resetRightOptionState()
            PTTTonePlayer.shared.playStopTone()
            self.audioManager.toggleRecording()
        }
    }

    func cancelUtteranceSilenceTimer() {
        sttAutoStopTimer?.invalidate()
        sttAutoStopTimer = nil
    }

    private func stopSTTPushToTalk() {
        // Retire this session: any deferred start work still in flight (the Bluetooth
        // warm-up chain in particular, which lands ~2.4s after the press) sees a stale
        // generation and drops out instead of re-showing an overlay for a dead recording.
        sttStartGeneration &+= 1
        audioManager.onMicReady = nil
        bluetoothWarmingUp = false

        if let pending = sttPendingStartWorkItem {
            // Released during the tone-delay window, before the engine
            // started: cancel the deferred start instead of dropping the
            // stop. Nothing was captured yet, so reset cleanly.
            pending.cancel()
            sttPendingStartWorkItem = nil
            print("STT PTT: released before recording started — cancelling start")
            sttPushToTalkActive = false
            sttPushToTalkStartTime = nil
            sttPushToTalkTargetApp = nil
            sttPushToTalkTargetWindow = nil
            sttAutoRecordAfterRecap = false
            bluetoothWarmingUp = false
            audioOverlay?.dismiss()
            cursorAnchoredOverlay?.dismiss()
            drainRecapQueueIfIdle()
            return
        }

        guard audioManager.isRecording else { return }

        print("STT PTT: released — stopping")
        PTTTonePlayer.shared.playStopTone()
        audioManager.toggleRecording()
    }

    @discardableResult
    func ensureAudioOverlay() -> AudioTranscriptionOverlayWindow {
        if audioOverlay == nil {
            let overlay = AudioTranscriptionOverlayWindow()
            // X button on the STT overlay: finalize the recording so the user's
            // audio is still transcribed + pasted, even if the Option key
            // release event got dropped and the PTT state machine is wedged.
            // Transcription continues headless after the overlay dismisses.
            // Also unwedge the right-Option state so the next double-tap works.
            overlay.viewModel.onUserClose = { [weak self] in
                guard let self = self else { return }
                self.resetRightOptionState()
                if self.audioManager.isRecording {
                    print("STT: overlay X pressed — finalizing recording in background")
                    PTTTonePlayer.shared.playStopTone()
                    self.audioManager.toggleRecording()
                }
                self.audioOverlay?.dismiss()
            }
            audioOverlay = overlay
        }
        return audioOverlay!
    }
}
