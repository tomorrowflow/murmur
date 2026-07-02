import Cocoa
import SwiftUI

// MARK: - Level meter

/// A single labelled horizontal level meter, matching the overlay glass style.
private struct CaptureLevelMeter: View {
    let label: String
    let systemImage: String
    let level: CGFloat        // 0...1
    let tint: Color
    let enabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundColor(enabled ? tint : .secondary.opacity(0.5))
                .frame(width: 16)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 34, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(enabled ? tint : .secondary.opacity(0.3))
                        .frame(width: max(2, geo.size.width * (enabled ? level : 0)))
                        .animation(.linear(duration: 0.05), value: level)
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - SwiftUI View

struct CallCaptureOverlayView: View {
    @ObservedObject var manager: CallCaptureManager
    var onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                RecordingDot()
                Text("Capturing Call")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(formattedElapsed)
                    .font(.system(size: 14, weight: .medium).monospacedDigit())
                    .foregroundColor(.primary.opacity(0.85))
            }

            // Target app + state
            HStack(spacing: 6) {
                Text(manager.capturingAppLabel.isEmpty ? "—" : manager.capturingAppLabel)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
                stateBadge
            }

            // Level meters
            VStack(spacing: 6) {
                CaptureLevelMeter(label: "App", systemImage: "speaker.wave.2.fill",
                                  level: manager.appLevel, tint: .blue, enabled: true)
                CaptureLevelMeter(label: "Mic", systemImage: "mic.fill",
                                  level: manager.micLevel, tint: .red, enabled: manager.micEnabled)
            }

            // Stop button
            Button(action: onStop) {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                    Text("Stop Capture")
                        .font(.system(size: 12, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.15))
                .foregroundColor(.red)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 300)
        .glassBackground()
    }

    private var formattedElapsed: String {
        let s = manager.elapsedSeconds
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch manager.state {
        case .idle: StateBadge(text: "Idle", color: .secondary)
        case .recording: StateBadge(text: "Recording", color: .red)
        case .finalizing: StateBadge(text: "Finalizing", color: .orange)
        }
    }
}

// MARK: - Recording indicator

/// Pulsing red dot — the always-visible recording indicator.
private struct RecordingDot: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 9, height: 9)
            .opacity(on ? 1.0 : 0.35)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

// MARK: - Overlay Window

final class CallCaptureOverlayWindow {
    private var panel: NSPanel?
    private var panelResizeObserver: NSObjectProtocol?
    private let manager: CallCaptureManager
    var onStop: (() -> Void)?

    init(manager: CallCaptureManager) {
        self.manager = manager
    }

    func show() {
        DispatchQueue.main.async { [self] in
            let wasHidden = !(panel?.isVisible ?? false)
            ensurePanel()
            if wasHidden { panel?.positionTopCentered() }
            panel?.orderFront(nil)
        }
    }

    func dismiss() {
        DispatchQueue.main.async { [self] in
            panel?.orderOut(nil)
        }
    }

    private func ensurePanel() {
        if panel != nil { return }
        let view = CallCaptureOverlayView(manager: manager) { [weak self] in
            self?.onStop?()
        }
        let hostingView = NSHostingView(rootView: view)
        let panel = createGlassPanel(width: 300, height: 200)
        panel.contentView = hostingView
        self.panel = panel
        panel.positionTopCentered()
        panelResizeObserver = observePanelResize(panel) { [weak self] in
            self?.panel?.positionTopCentered()
        }
    }
}
