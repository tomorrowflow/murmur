import Cocoa
import SwiftUI

// MARK: - Overlay State

enum AudioTranscriptionOverlayState {
    case hidden
    case listening
    case transcribing
    case error
}

// MARK: - ViewModel

class AudioTranscriptionOverlayViewModel: ObservableObject {
    @Published var state: AudioTranscriptionOverlayState = .hidden
    @Published var errorText: String = ""

    var onDismiss: (() -> Void)?

    private var autoDismissTimer: Timer?

    func show(state: AudioTranscriptionOverlayState) {
        cancelAutoDismiss()
        self.state = state
        if state == .listening {
            errorText = ""
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
        state = .hidden
        errorText = ""
        onDismiss?()
    }

    private func cancelAutoDismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
    }
}

// MARK: - SwiftUI View

struct AudioTranscriptionOverlayView: View {
    @ObservedObject var viewModel: AudioTranscriptionOverlayViewModel

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
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .transcribing:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Transcribing...")
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
        case .listening, .transcribing: return 100
        case .error: return 120
        }
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch viewModel.state {
        case .listening:
            Text("Recording")
                .font(.system(size: 10, weight: .medium))
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
            viewModel.show(state: state)
            ensurePanel()
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

        // Position top-centre, just below the menu bar
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = (screenFrame.width - 320) / 2 + screenFrame.minX
            let y = screenFrame.maxY - 100 - 40
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.panel = panel
    }
}
