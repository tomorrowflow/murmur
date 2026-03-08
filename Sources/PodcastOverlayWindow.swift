import Cocoa
import SwiftUI

// MARK: - ViewModel

class PodcastOverlayViewModel: ObservableObject {
    @Published var state: PodcastState = .idle
    @Published var title: String = ""
    @Published var transcript: [ScriptLine] = []
    @Published var activeSpeaker: String = ""
    @Published var activeLineId: UUID?
    @Published var webSearchEnabled: Bool = UserDefaults.standard.bool(forKey: "podcast.webSearchEnabled")
    @Published var progressMessage: String = ""
    @Published var progressPercent: Int = -1
    @Published var chunkProgress: String = ""

    @Published var isPaused: Bool = false

    var onDismiss: (() -> Void)?
    var onStop: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onWebSearchToggled: ((Bool) -> Void)?
    var onExportMarkdown: (() -> Void)?
    var onExportAudio: (() -> Void)?

    func update(state: PodcastState) {
        self.state = state
        // Reset pause when state changes away from playing (e.g. interrupt, buffering)
        if state != .playing {
            isPaused = false
        }
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

    func activateLine(_ lineId: UUID) {
        self.activeLineId = lineId
        if let line = transcript.first(where: { $0.id == lineId }) {
            self.activeSpeaker = line.speaker
        }
    }

    func updateProgress(message: String, percent: Int) {
        self.progressMessage = message
        self.progressPercent = percent
    }

    func updateChunkProgress(current: Int, total: Int) {
        if total > 0 {
            self.chunkProgress = "\(current)/\(total)"
        } else {
            self.chunkProgress = ""
        }
    }

    func dismiss() {
        onStop?()
        state = .idle
        transcript = []
        title = ""
        activeSpeaker = ""
        activeLineId = nil
        progressMessage = ""
        progressPercent = -1
        chunkProgress = ""
        onDismiss?()
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

                if viewModel.state == .playing || viewModel.state == .complete {
                    Button(action: {
                        if viewModel.state == .complete {
                            // Replay from start
                            viewModel.onPlayPause?()
                        } else {
                            viewModel.isPaused.toggle()
                            viewModel.onPlayPause?()
                        }
                    }) {
                        Image(systemName: viewModel.state == .complete || viewModel.isPaused ? "play.fill" : "pause.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .help(viewModel.state == .complete ? "Replay" : (viewModel.isPaused ? "Resume" : "Pause"))
                }

                // Export buttons — always visible once playing, audio greyed out until complete
                if viewModel.state == .playing || viewModel.state == .complete
                    || viewModel.state == .buffering || viewModel.state == .listening
                    || viewModel.state == .processingInterrupt {
                    Button(action: { viewModel.onExportAudio?() }) {
                        Image(systemName: "arrow.down.doc.fill")
                            .foregroundColor(viewModel.state == .complete ? .secondary : .secondary.opacity(0.3))
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.state != .complete)
                    .help("Download full audio")

                    Button(action: { viewModel.onExportMarkdown?() }) {
                        Image(systemName: "arrow.down.doc")
                            .foregroundColor(.secondary)
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .help("Export transcript as Markdown")
                }

                Button(action: { viewModel.dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("Stop and close")
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
                    progressContent(defaultMessage: viewModel.state == .connecting ? "Connecting..." : "Generating script...")

                case .buffering:
                    if !viewModel.transcript.isEmpty {
                        // Mid-session buffering — show transcript with progress at bottom
                        VStack(spacing: 0) {
                            transcriptView
                            Divider()
                            HStack(spacing: 8) {
                                if viewModel.progressPercent >= 0 {
                                    ProgressView(value: Double(viewModel.progressPercent), total: 100)
                                        .controlSize(.small)
                                        .tint(.blue)
                                        .frame(width: 100)
                                } else {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(viewModel.progressMessage.isEmpty ? "Buffering..." : viewModel.progressMessage)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                    } else {
                        progressContent(defaultMessage: "Buffering...")
                    }

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
                        interruptProgressIndicator
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
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.transcript) { line in
                        if line.isInterruptMarker {
                            // Interrupt marker
                            HStack(spacing: 6) {
                                Rectangle()
                                    .fill(Color.orange.opacity(0.5))
                                    .frame(height: 1)
                                HStack(spacing: 4) {
                                    Image(systemName: "hand.raised.fill")
                                        .font(.system(size: 9))
                                    Text(line.text)
                                        .font(.system(size: 10, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                .foregroundColor(.orange)
                                .layoutPriority(1)
                                Rectangle()
                                    .fill(Color.orange.opacity(0.5))
                                    .frame(height: 1)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 4)
                            .id(line.id)
                        } else {
                            let isActive = line.id == viewModel.activeLineId
                            let isPast = isPastLine(line)
                            HStack(alignment: .top, spacing: 6) {
                                Text(line.speaker)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(isActive ? speakerColor(line.speaker) : (isPast ? .secondary.opacity(0.4) : .secondary.opacity(0.6)))
                                    .frame(width: 50, alignment: .trailing)

                                Text(line.text)
                                    .font(.system(size: 12))
                                    .foregroundColor(isActive ? .primary : (isPast ? .secondary.opacity(0.45) : .primary.opacity(0.7)))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 2)
                            .padding(.horizontal, 4)
                            .background(isActive ? Color.accentColor.opacity(0.1) : Color.clear)
                            .cornerRadius(4)
                            .id(line.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.activeLineId) { lineId in
                if let lineId = lineId {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(lineId, anchor: .top)
                    }
                }
            }
            .onChange(of: viewModel.transcript.count) { _ in
                // When transcript changes (e.g. interrupt marker added),
                // scroll to the last interrupt marker so it sits at the top
                if let lastMarker = viewModel.transcript.last(where: { $0.isInterruptMarker }),
                   viewModel.state == .processingInterrupt || viewModel.state == .listening {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastMarker.id, anchor: .top)
                    }
                }
            }
        }
    }

    private func isPastLine(_ line: ScriptLine) -> Bool {
        guard let activeId = viewModel.activeLineId,
              let activeIndex = viewModel.transcript.firstIndex(where: { $0.id == activeId }),
              let lineIndex = viewModel.transcript.firstIndex(where: { $0.id == line.id }) else {
            return false
        }
        return lineIndex < activeIndex
    }

    // MARK: - Progress Content

    private func progressContent(defaultMessage: String) -> some View {
        VStack(spacing: 8) {
            if viewModel.progressPercent >= 0 {
                ProgressView(value: Double(viewModel.progressPercent), total: 100)
                    .controlSize(.small)
                    .tint(.blue)
                    .frame(width: 200)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(viewModel.progressMessage.isEmpty ? defaultMessage : viewModel.progressMessage)
                .foregroundColor(.secondary)
                .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var interruptProgressIndicator: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                if viewModel.progressPercent >= 0 {
                    ProgressView(value: Double(viewModel.progressPercent), total: 100)
                        .controlSize(.small)
                        .tint(.orange)
                        .frame(width: 100)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(viewModel.progressMessage.isEmpty ? "Hosts are thinking..." : viewModel.progressMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.05))
    }

    private var pttHint: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text("Double-tap Left Option to ask a question")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
                Spacer()
                Toggle(isOn: Binding(
                    get: { viewModel.webSearchEnabled },
                    set: { newValue in
                        viewModel.webSearchEnabled = newValue
                        viewModel.onWebSearchToggled?(newValue)
                    }
                )) {
                    Image(systemName: "globe")
                        .font(.system(size: 10))
                        .foregroundColor(viewModel.webSearchEnabled ? .accentColor : .secondary.opacity(0.5))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Web search on interrupt")
            }
            .padding(.horizontal, 12)
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
        case .connecting, .ingesting: return 100
        case .buffering: return viewModel.transcript.isEmpty ? 100 : 330
        case .error: return 120
        case .playing, .complete: return 300
        case .listening, .processingInterrupt: return 330
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
        case .playing:
            if viewModel.isPaused {
                return ("Paused", .yellow)
            }
            let label = viewModel.chunkProgress.isEmpty ? "Playing" : "Playing \(viewModel.chunkProgress)"
            return (label, .green)
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
    var onPlayPause: (() -> Void)?
    var onExportAudio: (() -> Void)?

    init() {
        viewModel.onDismiss = { [weak self] in
            self?.panel?.orderOut(nil)
        }
        viewModel.onStop = { [weak self] in
            self?.onStop?()
        }
        viewModel.onPlayPause = { [weak self] in
            self?.onPlayPause?()
        }
        viewModel.onExportMarkdown = { [weak self] in
            self?.exportMarkdown()
        }
        viewModel.onExportAudio = { [weak self] in
            self?.onExportAudio?()
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

    func activateLine(_ lineId: UUID) {
        DispatchQueue.main.async { [self] in
            viewModel.activateLine(lineId)
        }
    }

    func updateProgress(message: String, percent: Int) {
        DispatchQueue.main.async { [self] in
            viewModel.updateProgress(message: message, percent: percent)
        }
    }

    func updateChunkProgress(current: Int, total: Int) {
        DispatchQueue.main.async { [self] in
            viewModel.updateChunkProgress(current: current, total: total)
        }
    }

    func exportMarkdown() {
        DispatchQueue.main.async { [self] in
            var md = "# Podcast: \(viewModel.title)\n\n"
            for line in viewModel.transcript {
                if line.isInterruptMarker {
                    md += "\n---\n*Interrupt: \(line.text)*\n---\n\n"
                } else {
                    md += "**\(line.speaker):** \(line.text)\n\n"
                }
            }

            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.init(filenameExtension: "md")!]
            savePanel.nameFieldStringValue = "\(viewModel.title).md"
            savePanel.level = .floating + 1
            // Center on screen
            if let screen = NSScreen.main {
                let screenFrame = screen.frame
                let panelSize = NSSize(width: 500, height: 300)
                let x = screenFrame.midX - panelSize.width / 2
                let y = screenFrame.midY - panelSize.height / 2
                savePanel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: panelSize), display: true)
            }
            savePanel.begin { response in
                if response == .OK, let url = savePanel.url {
                    try? md.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    func dismiss() {
        DispatchQueue.main.async { [self] in
            viewModel.dismiss()
        }
    }

    func hidePanel() {
        DispatchQueue.main.async { [self] in
            panel?.orderOut(nil)
        }
    }

    func showPanel() {
        DispatchQueue.main.async { [self] in
            panel?.orderFront(nil)
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
        // Center horizontally, top of screen (same position as OpenClaw overlay)
        let x = (screenFrame.width - 380) / 2 + screenFrame.minX
        let y = screenFrame.maxY - panelHeight - 40
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
