import Cocoa
import SwiftUI

// MARK: - ViewModel

class PodcastOverlayViewModel: ObservableObject {
    @Published var state: PodcastState = .idle
    @Published var title: String = ""
    @Published var transcript: [ScriptLine] = []
    @Published var activeSpeaker: String = ""

    var onDismiss: (() -> Void)?
    var onStop: (() -> Void)?

    func update(state: PodcastState) {
        self.state = state
    }

    func updateTitle(_ title: String) {
        self.title = title
    }

    func updateTranscript(_ lines: [ScriptLine]) {
        self.transcript = lines
        if let last = lines.last {
            self.activeSpeaker = last.speaker
        }
    }

    func dismiss() {
        state = .idle
        transcript = []
        title = ""
        activeSpeaker = ""
        onDismiss?()
    }

    func stop() {
        onStop?()
        dismiss()
    }
}

// MARK: - SwiftUI View

struct PodcastOverlayView: View {
    @ObservedObject var viewModel: PodcastOverlayViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "radio")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text("Podcast")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                stateBadge

                Button(action: { viewModel.stop() }) {
                    Image(systemName: "stop.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("Stop podcast")

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

            // Title
            if !viewModel.title.isEmpty {
                Text(viewModel.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }

            // Content area
            Group {
                switch viewModel.state {
                case .idle:
                    EmptyView()

                case .connecting, .ingesting:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(viewModel.state == .connecting ? "Connecting..." : "Generating script...")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .buffering:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Buffering...")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .playing, .complete:
                    VStack(spacing: 0) {
                        transcriptView
                        if viewModel.state == .playing {
                            pttHint
                        }
                    }

                case .listening:
                    VStack(spacing: 0) {
                        transcriptView
                        Divider()
                        listeningIndicator
                    }

                case .processingInterrupt:
                    VStack(spacing: 0) {
                        transcriptView
                        Divider()
                        processingIndicator
                    }

                case .error(let msg):
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(msg)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 380, height: dynamicHeight)
    }

    // MARK: - Transcript

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    let visibleLines = Array(viewModel.transcript.suffix(6))
                    ForEach(visibleLines) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Text(line.speaker)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(speakerColor(line.speaker))
                                .frame(width: 50, alignment: .trailing)

                            Text(line.text)
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(line.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.transcript.count) { _ in
                if let last = viewModel.transcript.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Listening / Processing indicators

    private var listeningIndicator: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.fill")
                .foregroundColor(.red)
                .font(.system(size: 16))
                .symbolEffect(.pulse)
            Text("Listening...")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.05))
    }

    private var processingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Hosts are thinking...")
                .font(.system(size: 12))
                .foregroundColor(.orange)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.05))
    }

    private var pttHint: some View {
        VStack(spacing: 0) {
            Divider()
            Text("Double-tap Left Option to ask a question")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.7))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
    }

    // MARK: - Helpers

    private func speakerColor(_ name: String) -> Color {
        if name == viewModel.activeSpeaker {
            return .accentColor
        }
        return .secondary
    }

    private var dynamicHeight: CGFloat {
        switch viewModel.state {
        case .idle: return 0
        case .connecting, .ingesting, .buffering: return 100
        case .error: return 120
        case .playing, .complete: return 260
        case .listening, .processingInterrupt: return 290
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        let (text, color) = badgeInfo
        if !text.isEmpty {
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.15))
                .cornerRadius(4)
        }
    }

    private var badgeInfo: (String, Color) {
        switch viewModel.state {
        case .idle: return ("", .clear)
        case .connecting: return ("Connecting", .orange)
        case .ingesting: return ("Scripting", .orange)
        case .buffering: return ("Buffering", .orange)
        case .playing: return ("Playing", .green)
        case .listening: return ("Listening", .red)
        case .processingInterrupt: return ("Processing", .orange)
        case .complete: return ("Complete", .blue)
        case .error: return ("Error", .red)
        }
    }
}

// MARK: - Overlay Window

class PodcastOverlayWindow {
    private var panel: NSPanel?
    let viewModel = PodcastOverlayViewModel()
    var onStop: (() -> Void)?

    init() {
        viewModel.onDismiss = { [weak self] in
            self?.panel?.orderOut(nil)
        }
        viewModel.onStop = { [weak self] in
            self?.onStop?()
        }
    }

    func show(state: PodcastState) {
        DispatchQueue.main.async { [self] in
            let wasHidden = !(panel?.isVisible ?? false)
            viewModel.update(state: state)
            ensurePanel()
            if wasHidden { repositionPanel() }
            panel?.orderFront(nil)
        }
    }

    func updateState(_ state: PodcastState) {
        DispatchQueue.main.async { [self] in
            viewModel.update(state: state)
            if state != .idle {
                ensurePanel()
                panel?.orderFront(nil)
            }
        }
    }

    func updateTitle(_ title: String) {
        DispatchQueue.main.async { [self] in
            viewModel.updateTitle(title)
        }
    }

    func updateTranscript(_ lines: [ScriptLine]) {
        DispatchQueue.main.async { [self] in
            viewModel.updateTranscript(lines)
        }
    }

    func dismiss() {
        DispatchQueue.main.async { [self] in
            viewModel.dismiss()
        }
    }

    private func ensurePanel() {
        if panel != nil { return }

        let hostingView = NSHostingView(rootView: PodcastOverlayView(viewModel: viewModel))

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
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

        self.panel = panel
        repositionPanel()
    }

    private func repositionPanel() {
        guard let panel = panel, let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelHeight = panel.frame.height
        // Position top-right, below menu bar
        let x = screenFrame.maxX - 380 - 20
        let y = screenFrame.maxY - panelHeight - 40
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
