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
    func defaultWaveformImage() -> NSImage {
        return generateWaveformImage(level: 0)
    }

    func generateWaveformImage(level: CGFloat = 0) -> NSImage {
        let width: CGFloat = 18
        let height: CGFloat = 18
        let barCount = 5
        let barWidth: CGFloat = 2.0
        let barSpacing: CGFloat = 1.0
        let cornerRadius: CGFloat = 1.0
        let minBarHeight: CGFloat = 4.0
        let maxBarHeight: CGFloat = 14.0

        // Bar scale factors: outer bars shorter, center tallest
        let scaleFactors: [CGFloat] = [0.55, 0.8, 1.0, 0.8, 0.55]

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        let totalBarsWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
        let startX = (width - totalBarsWidth) / 2

        for i in 0..<barCount {
            let barLevel = level * scaleFactors[i]
            let barHeight = minBarHeight + barLevel * (maxBarHeight - minBarHeight)
            let x = startX + CGFloat(i) * (barWidth + barSpacing)
            let y = (height - barHeight) / 2
            let rect = NSRect(x: x, y: y, width: barWidth, height: barHeight)
            let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            NSColor.black.setFill()
            path.fill()
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    func startWaveformAnimation() {
        // Don't start if already animating or screen recording is active
        if waveformAnimationTimer != nil { return }

        // Show first frame immediately
        if let button = statusItem.button {
            button.title = ""
            button.image = generateWaveformImage(level: AudioLevelMonitor.shared.currentLevel)
        }

        waveformAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if let button = self.statusItem.button {
                button.title = ""
                button.image = self.generateWaveformImage(level: AudioLevelMonitor.shared.currentLevel)
            }
        }
    }

    func stopWaveformAnimation() {
        waveformAnimationTimer?.invalidate()
        waveformAnimationTimer = nil
        AudioLevelMonitor.shared.reset()

        if let button = statusItem.button {
            button.image = defaultWaveformImage()
            button.title = ""
        }
    }

    func updateStatusBarWithLevel(db: Float) {

        startWaveformAnimation()
    }

    func startTranscriptionIndicator() {

        startWaveformAnimation()
    }

    func stopTranscriptionIndicator() {


        // If not currently recording, stop animation and reset.
        // When recording, the live level updates will keep animation going.
        if audioManager?.isRecording != true {
            stopWaveformAnimation()
        }
    }

    /// Update the status bar header items + tooltip to reflect the current
    /// OpenClaw state and the interaction hint that's relevant for that
    /// state. Always safe to call from the main thread.
    func refreshOpenClawStatusHint() {
        guard let statusItem = openClawStatusMenuItem,
              let hintItem = openClawHintMenuItem else { return }
        let stateLabel: String
        let hintLabel: String
        let recording = openClawRecordingManager
        if recording == nil {
            stateLabel = "OpenClaw: not configured"
            hintLabel = "Configure in Settings → OpenClaw"
        } else if openClawAutoMicActive {
            stateLabel = "OpenClaw: listening (auto follow-up)"
            hintLabel = "Speak now — silence stops the mic"
        } else if recording?.isRecording == true {
            stateLabel = "OpenClaw: listening"
            hintLabel = "Release Left Option (or press X) to send"
        } else if recording?.isProcessing == true {
            stateLabel = "OpenClaw: thinking…"
            hintLabel = "Awaiting response"
        } else if recording?.isAnswering == true {
            stateLabel = "OpenClaw: speaking"
            hintLabel = "Double-tap Left Option to interrupt"
        } else if openClawAutoMicFireWorkItem != nil {
            stateLabel = "OpenClaw: opening mic…"
            hintLabel = "Listening will start in a moment"
        } else if openClawManager?.isAuthenticated == true {
            stateLabel = "OpenClaw: idle"
            hintLabel = "Double-tap Left Option to talk"
        } else if openClawManager?.isConnected == true {
            stateLabel = "OpenClaw: connecting…"
            hintLabel = "Authenticating with gateway"
        } else {
            stateLabel = "OpenClaw: offline"
            hintLabel = "Check connection in Settings → OpenClaw"
        }
        statusItem.title = stateLabel
        hintItem.title = hintLabel
        if let button = self.statusItem.button {
            button.toolTip = "\(stateLabel)\n\(hintLabel)"
        }
    }
}
