import Cocoa
import SwiftUI
import SharedModels

extension AppDelegate {
    // MARK: - Call Capture

    /// Hotkey toggle: stop if capturing, otherwise capture the first detected
    /// running known app. If none is running, tell the user.
    func toggleCallCapture() {
        guard let manager = callCaptureManager else { return }
        if manager.isCapturing {
            stopCallCapture()
            return
        }
        guard let target = CallCaptureManager.detectedRunningApps().first else {
            AppNotifier.notify(
                title: "No Call App Running",
                body: "Start Slack, Teams, or Zoom (or add a bundle id in settings), then try again."
            )
            return
        }
        startCallCapture(app: target.alias ?? target.bundleID)
    }

    /// Whether new captures should transcribe on stop (hotkey/menu default).
    var callCaptureAutoTranscribe: Bool {
        UserDefaults.standard.object(forKey: "callCapture.autoTranscribe") as? Bool ?? true
    }

    /// Start a capture session for the given app (alias, bundle id, or "system").
    /// Surfaces precondition failures as alerts/notifications. Returns the
    /// started session info, or nil on failure.
    @discardableResult
    func startCallCapture(app: String, includeMic: Bool = true, transcribeOnStop: Bool? = nil) -> CallCaptureSessionInfo? {
        guard let manager = callCaptureManager else { return nil }
        do {
            let info = try manager.start(app: app, includeMic: includeMic)
            captureTranscribeOnStop = transcribeOnStop ?? callCaptureAutoTranscribe
            callCaptureOverlay?.show()
            return info
        } catch let error as CallCaptureError {
            if case .permissionDenied = error {
                showAudioCapturePermissionAlert()
            } else {
                AppNotifier.notify(title: "Call Capture Failed", body: error.localizedDescription)
            }
            return nil
        } catch {
            NSLog("CallCapture: unexpected error: \(error)")
            return nil
        }
    }

    func stopCallCapture() {
        guard let manager = callCaptureManager, manager.isCapturing else { return }
        // manager.stop() fires callCaptureDidFinish, which handles the overlay
        // and kicks off transcription if enabled.
        _ = manager.stop()
    }

    private func showAudioCapturePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "System Audio Recording Permission Required"
        alert.informativeText = "Murmur needs permission to record system audio. Enable Murmur under System Settings > Privacy & Security > Screen & System Audio Recording, then try again."
        alert.alertStyle = .warning
        if let iconImage = appIconImage() { alert.icon = iconImage }
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc func captureMenuItemSelected(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? String else { return }
        startCallCapture(app: target)
    }

    @objc func stopCaptureMenuItemSelected() {
        stopCallCapture()
    }

    // MARK: CallCaptureManagerDelegate

    func callCaptureStateDidChange(_ state: CallCaptureState) {
        // Keep the status-bar animation in sync so the menu bar reflects capture.
        if state == .recording {
            startWaveformAnimation()
        } else if state == .idle {
            stopTranscriptionIndicator()
        }
    }

    func callCaptureDidFail(_ message: String) {
        AppNotifier.notify(title: "Call Capture Error", body: message)
    }

    func callCaptureDidFinish(_ info: CallCaptureSessionInfo) {
        // Fired synchronously by stop() on the main thread, with the manager in
        // .finalizing. We drive the terminal transition here — either → idle
        // (no transcription) or → transcribing → idle (via the completion) — so
        // the manager never sits in .idle between capture and transcription.
        // These call sites are main-thread, so assumeIsolated reads the
        // @MainActor runner synchronously.
        guard captureTranscribeOnStop else {
            callCaptureManager?.markTranscriptionDone()   // .finalizing → .idle
            callCaptureOverlay?.dismiss()
            return
        }

        // Start first; only enter .transcribing if it actually began.
        let started = MainActor.assumeIsolated {
            CallTranscriptionRunner.shared.transcribeSession(directory: info.directory) { [weak self] in
                self?.callCaptureManager?.markTranscriptionDone()   // → .idle
                self?.callCaptureOverlay?.dismiss()
            }
        }
        if started {
            callCaptureManager?.markTranscribing()   // .finalizing → .transcribing
            callCaptureOverlay?.show()
            return
        }

        // Couldn't start. If OUR session is somehow already transcribing (a
        // spurious re-entry), leave it alone. Otherwise the runner is either
        // idle or busy with a DIFFERENT (e.g. file-input) session that doesn't
        // share this overlay — reset the capture UI so it isn't stranded in
        // .finalizing, and surface it (audio is preserved; transcribe later via
        // POST /api/v1/transcribe).
        let runningOurs = MainActor.assumeIsolated {
            CallTranscriptionRunner.shared.isBusy
                && CallTranscriptionRunner.shared.currentSessionId == info.id
        }
        if runningOurs {
            callCaptureManager?.markTranscribing()
            callCaptureOverlay?.show()
            return
        }
        callCaptureManager?.markTranscriptionDone()   // .finalizing → .idle
        callCaptureOverlay?.dismiss()
        NSLog("[CallCapture] Transcription not started for \(info.id); audio preserved in \(info.directory.path)")
        AppNotifier.notify(
            title: "Call Captured (Not Transcribed)",
            body: "Transcription is unavailable right now. The audio is saved in \(info.directory.lastPathComponent) and can be transcribed later."
        )
    }

    // MARK: NSMenuDelegate (Capture Call submenu)

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === captureSubmenu else { return }
        menu.removeAllItems()

        if callCaptureManager?.isCapturing == true {
            let label = callCaptureManager?.capturingAppLabel ?? "call"
            let stopItem = NSMenuItem(
                title: "Stop Capture (\(label))",
                action: #selector(stopCaptureMenuItemSelected),
                keyEquivalent: ""
            )
            stopItem.target = self
            menu.addItem(stopItem)
            return
        }

        let detected = CallCaptureManager.detectedRunningApps()
        if detected.isEmpty {
            let none = NSMenuItem(title: "No call app running", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for app in detected {
                let item = NSMenuItem(
                    title: "Capture \(app.displayName)",
                    action: #selector(captureMenuItemSelected(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = app.alias ?? app.bundleID
                if let icon = app.icon {
                    let resized = icon.copy() as! NSImage
                    resized.size = NSSize(width: 16, height: 16)
                    item.image = resized
                }
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        let systemItem = NSMenuItem(
            title: "Capture All System Audio",
            action: #selector(captureMenuItemSelected(_:)),
            keyEquivalent: ""
        )
        systemItem.target = self
        systemItem.representedObject = "system"
        menu.addItem(systemItem)
    }
}
