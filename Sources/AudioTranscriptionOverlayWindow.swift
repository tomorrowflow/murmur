import Cocoa
import SwiftUI

// MARK: - Overlay State

enum AudioTranscriptionOverlayState {
    case hidden
    case connecting   // Bluetooth mic warming up — don't speak yet
    case listening
    case transcribing
    case refining
    case error
}

// MARK: - ViewModel

class AudioTranscriptionOverlayViewModel: ObservableObject {
    @Published var state: AudioTranscriptionOverlayState = .hidden
    @Published var errorText: String = ""
    @Published var elapsedSeconds: Int = 0
    @Published var targetAppIcon: NSImage?
    @Published var targetAppName: String?

    var onDismiss: (() -> Void)?

    private var autoDismissTimer: Timer?
    private var recordingTimer: Timer?

    func show(state: AudioTranscriptionOverlayState) {
        cancelAutoDismiss()
        let wasListening = self.state == .listening
        self.state = state
        if state == .listening {
            errorText = ""
            if !wasListening {
                startRecordingTimer()
            }
        } else if state == .connecting {
            errorText = ""
            stopRecordingTimer()
        } else {
            stopRecordingTimer()
        }
    }

    func showError(_ message: String) {
        errorText = message
        state = .error
        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    func dismiss() {
        cancelAutoDismiss()
        stopRecordingTimer()
        state = .hidden
        errorText = ""
        targetAppIcon = nil
        targetAppName = nil
        onDismiss?()
    }

    var formattedElapsedTime: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, seconds)
        } else {
            return "\(seconds)s"
        }
    }

    private func startRecordingTimer() {
        stopRecordingTimer()
        elapsedSeconds = 0
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.elapsedSeconds += 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        recordingTimer = timer
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    private func cancelAutoDismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
    }
}

// MARK: - SwiftUI View

struct AudioTranscriptionOverlayView: View {
    @ObservedObject var viewModel: AudioTranscriptionOverlayViewModel
    @AppStorage("ptt.stt.promptRefinement") private var promptRefinementEnabled = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                AppIconView(icon: viewModel.targetAppIcon, size: 20)

                Text(viewModel.targetAppName ?? "Audio Transcription")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Spacer()

                stateIndicator

                Button(action: { viewModel.dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 20, height: 20)
                        .background(.secondary.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            // Content
            switch viewModel.state {
            case .hidden:
                EmptyView()

            case .connecting:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Connecting microphone...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            case .listening:
                HStack(spacing: 10) {
                    LiveWaveformView(monitor: AudioLevelMonitor.shared, barCount: 20, color: .red, height: 22)
                        .frame(width: 110, height: 22)
                    Spacer()
                    Text(viewModel.formattedElapsedTime)
                        .font(.system(size: 18, weight: .medium).monospacedDigit())
                        .foregroundColor(.primary.opacity(0.8))
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            case .transcribing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Transcribing...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            case .refining:
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                        .foregroundColor(.purple)
                        .font(.system(size: 14))
                        .symbolEffect(.pulse)
                    Text("Refining prompt...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            case .error:
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 12))
                    Text(viewModel.errorText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 300)
        .glassBackground()
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch viewModel.state {
        case .connecting:
            StateBadge(text: "Connecting", color: .blue)
        case .listening:
            HStack(spacing: 4) {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                Text("Recording")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                if promptRefinementEnabled {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.red.opacity(0.08))
            .cornerRadius(10)
        case .transcribing:
            StateBadge(text: "Transcribing", color: .orange)
        case .refining:
            StateBadge(text: "Refining", color: .purple)
        case .error:
            StateBadge(text: "Error", color: .orange)
        case .hidden:
            EmptyView()
        }
    }
}

// MARK: - Overlay Window

class AudioTranscriptionOverlayWindow {
    private var panel: NSPanel?
    private var panelResizeObserver: NSObjectProtocol?
    let viewModel = AudioTranscriptionOverlayViewModel()

    init() {
        viewModel.onDismiss = { [weak self] in
            self?.panel?.orderOut(nil)
        }
    }

    func show(state: AudioTranscriptionOverlayState) {
        DispatchQueue.main.async { [self] in
            let wasHidden = !(panel?.isVisible ?? false)
            viewModel.show(state: state)
            ensurePanel()
            if wasHidden { repositionPanel() }
            panel?.orderFront(nil)
        }
    }

    func showError(_ message: String) {
        DispatchQueue.main.async { [self] in
            viewModel.showError(message)
            ensurePanel()
            panel?.orderFront(nil)
        }
    }

    func dismiss() {
        DispatchQueue.main.async { [self] in
            viewModel.dismiss()
        }
    }

    private func ensurePanel() {
        if panel != nil { return }

        let hostingView = NSHostingView(rootView: AudioTranscriptionOverlayView(viewModel: viewModel))
        let panel = createGlassPanel(width: 300, height: 100)
        panel.contentView = hostingView
        self.panel = panel
        panel.positionTopCentered()
        panelResizeObserver = observePanelResize(panel) { [weak self] in
            self?.panel?.positionTopCentered()
        }
    }

    private func repositionPanel() {
        panel?.positionTopCentered()
    }
}
