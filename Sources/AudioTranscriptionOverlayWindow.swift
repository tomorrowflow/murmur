import Cocoa
import SwiftUI

// MARK: - Overlay State

enum AudioTranscriptionOverlayState {
    case hidden
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
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("Audio Transcription")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                stateIndicator

                Button(action: { viewModel.dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .padding(.top, -12)

            Divider()

            // Content
            Group {
                switch viewModel.state {
                case .hidden:
                    EmptyView()

                case .listening:
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 20))
                            .symbolEffect(.pulse)
                        Text("Recording...")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(viewModel.formattedElapsedTime)
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .transcribing:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Transcribing...")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .refining:
                    HStack(spacing: 10) {
                        Image(systemName: "wand.and.stars")
                            .foregroundColor(.purple)
                            .font(.system(size: 20))
                            .symbolEffect(.pulse)
                        Text("Refining prompt...")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .error:
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(viewModel.errorText)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 320, height: dynamicHeight)
    }

    private var dynamicHeight: CGFloat {
        switch viewModel.state {
        case .hidden: return 0
        case .listening, .transcribing, .refining: return 100
        case .error: return 120
        }
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch viewModel.state {
        case .listening:
            HStack(spacing: 3) {
                Text("Recording")
                    .font(.system(size: 10, weight: .medium))
                if promptRefinementEnabled {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 8))
                }
            }
            .foregroundColor(.red)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.red.opacity(0.15))
            .cornerRadius(4)

        case .transcribing:
            Text("Transcribing")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.15))
                .cornerRadius(4)

        case .refining:
            HStack(spacing: 3) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 8))
                Text("Refining")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.purple)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.purple.opacity(0.15))
            .cornerRadius(4)

        case .error:
            Text("Error")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.15))
                .cornerRadius(4)

        case .hidden:
            EmptyView()
        }
    }
}

// MARK: - Overlay Window

class AudioTranscriptionOverlayWindow {
    private var panel: NSPanel?
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

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
            styleMask: [.nonactivatingPanel, .titled, .hudWindow, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false

        self.panel = panel
        repositionPanel()
    }

    private func repositionPanel() {
        guard let panel = panel, let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelHeight = panel.frame.height
        let x = (screenFrame.width - 320) / 2 + screenFrame.minX
        let y = screenFrame.maxY - panelHeight - 40
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
