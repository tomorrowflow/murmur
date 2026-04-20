import Cocoa
import SwiftUI

// MARK: - Overlay State

enum OpenClawOverlayState {
    case hidden
    case connecting   // Bluetooth mic warming up — don't speak yet
    case listening
    case processing
    case streaming
    case complete
    case error
}

// MARK: - ViewModel

class OpenClawOverlayViewModel: ObservableObject {
    @Published var state: OpenClawOverlayState = .hidden
    @Published var responseText: String = ""
    @Published var errorText: String = ""
    @Published var isPinned: Bool = false
    @Published var isTTSPlaying: Bool = false
    @Published var showCopied: Bool = false
    @Published var elapsedSeconds: Int = 0

    var isHovered: Bool = false
    var onDismiss: (() -> Void)?
    var onCancel: (() -> Void)?

    private var autoDismissTimer: Timer?
    private var recordingTimer: Timer?

    func show(state: OpenClawOverlayState) {
        cancelAutoDismiss()
        let wasListening = self.state == .listening
        self.state = state
        if state == .listening {
            if !wasListening {
                responseText = ""
                errorText = ""
                isPinned = false
                startRecordingTimer()
            }
        } else if state == .connecting {
            responseText = ""
            errorText = ""
            isPinned = false
            stopRecordingTimer()
        } else {
            stopRecordingTimer()
        }
    }

    func updateResponse(_ text: String) {
        responseText = text
        state = .streaming
    }

    func complete() {
        state = .complete
        scheduleAutoDismissIfNeeded()
    }

    func showError(_ message: String) {
        errorText = message
        state = .error
        scheduleAutoDismissIfNeeded()
    }

    func dismiss() {
        cancelAutoDismiss()
        stopRecordingTimer()
        state = .hidden
        responseText = ""
        errorText = ""
        isPinned = false
        isHovered = false
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

    func pin() {
        isPinned = true
        cancelAutoDismiss()
    }

    func ttsStarted() {
        isTTSPlaying = true
        cancelAutoDismiss()
    }

    func ttsFinished() {
        isTTSPlaying = false
        if state == .complete || state == .error {
            scheduleAutoDismissIfNeeded()
        }
    }

    func copyResponse() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(responseText, forType: .string)
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.showCopied = false
        }
    }

    func mouseEntered() {
        isHovered = true
        cancelAutoDismiss()
    }

    func mouseExited() {
        isHovered = false
        if !isPinned && (state == .complete || state == .error) {
            scheduleAutoDismissIfNeeded()
        }
    }

    private func scheduleAutoDismissIfNeeded() {
        if isPinned || isHovered || isTTSPlaying { return }
        cancelAutoDismiss()
        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if !self.isPinned && !self.isHovered && !self.isTTSPlaying {
                self.dismiss()
            }
        }
    }

    private func cancelAutoDismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
    }
}

// MARK: - Waveform Icon

struct WaveformIcon: View {
    var body: some View {
        GeometryReader { geo in
            let barWidth = geo.size.width * 0.22
            let spacing = geo.size.width * 0.11
            let totalWidth = 3 * barWidth + 2 * spacing
            let startX = (geo.size.width - totalWidth) / 2
            let heights: [CGFloat] = [0.55, 0.85, 0.55]

            ForEach(0..<3, id: \.self) { i in
                let h = geo.size.height * heights[i]
                let x = startX + CGFloat(i) * (barWidth + spacing)
                let y = (geo.size.height - h) / 2
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .frame(width: barWidth, height: h)
                    .offset(x: x, y: y)
            }
        }
        .foregroundColor(.secondary)
    }
}

// MARK: - SwiftUI View

struct OpenClawOverlayView: View {
    @ObservedObject var viewModel: OpenClawOverlayViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("OpenClaw")
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                stateIndicator

                if viewModel.isPinned {
                    Image(systemName: "pin.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 10))
                }

                Button(action: {
                    viewModel.onCancel?()
                    viewModel.dismiss()
                }) {
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
            Group {
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
                        Text("Listening...")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(viewModel.formattedElapsedTime)
                            .font(.system(size: 18, weight: .medium).monospacedDigit())
                            .foregroundColor(.primary.opacity(0.8))
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)

                case .processing:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Processing...")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)

                case .streaming, .complete:
                    ZStack(alignment: .topTrailing) {
                        ScrollViewReader { proxy in
                            ScrollView {
                                Text(viewModel.responseText)
                                    .font(.system(size: 13))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                                    .padding(.trailing, 28)
                                    .id("responseBottom")
                            }
                            .onChange(of: viewModel.responseText) { _ in
                                withAnimation {
                                    proxy.scrollTo("responseBottom", anchor: .bottom)
                                }
                            }
                        }

                        Button(action: { viewModel.copyResponse() }) {
                            Image(systemName: viewModel.showCopied ? "checkmark" : "doc.on.doc")
                                .foregroundColor(viewModel.showCopied ? .green : .secondary)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                    }

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
        .frame(width: 400, height: dynamicHeight)
        .glassBackground()
        .onTapGesture {
            viewModel.pin()
        }
        .onHover { hovering in
            if hovering {
                viewModel.mouseEntered()
            } else {
                viewModel.mouseExited()
            }
        }
    }

    private var dynamicHeight: CGFloat {
        switch viewModel.state {
        case .hidden: return 0
        case .connecting, .listening, .processing: return 100
        case .error: return 120
        case .streaming, .complete: return min(400, max(120, CGFloat(viewModel.responseText.count / 2) + 80))
        }
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch viewModel.state {
        case .connecting: StateBadge(text: "Connecting", color: .blue)
        case .listening: StateBadge(text: "Listening", color: .red)
        case .processing: StateBadge(text: "Processing", color: .orange)
        case .streaming: StateBadge(text: "Streaming", color: .blue)
        case .complete: StateBadge(text: "Complete", color: .green)
        case .error: StateBadge(text: "Error", color: .orange)
        case .hidden: EmptyView()
        }
    }
}

// MARK: - Overlay Window

class OpenClawOverlayWindow {
    private var panel: NSPanel?
    private var panelResizeObserver: NSObjectProtocol?
    let viewModel = OpenClawOverlayViewModel()
    var onCancel: (() -> Void)?

    init() {
        viewModel.onDismiss = { [weak self] in
            self?.panel?.orderOut(nil)
        }
        viewModel.onCancel = { [weak self] in
            self?.onCancel?()
        }
    }

    func show(state: OpenClawOverlayState) {
        DispatchQueue.main.async { [self] in
            let wasHidden = !(panel?.isVisible ?? false)
            viewModel.show(state: state)
            ensurePanel()
            if wasHidden { repositionPanel() }
            panel?.orderFront(nil)
        }
    }

    func updateResponse(_ text: String) {
        DispatchQueue.main.async { [self] in
            viewModel.updateResponse(text)
            ensurePanel()
            panel?.orderFront(nil)
        }
    }

    func complete() {
        DispatchQueue.main.async { [self] in
            viewModel.complete()
        }
    }

    func showError(_ message: String) {
        DispatchQueue.main.async { [self] in
            viewModel.showError(message)
            ensurePanel()
            panel?.orderFront(nil)
        }
    }

    func ttsStarted() {
        DispatchQueue.main.async { [self] in
            viewModel.ttsStarted()
        }
    }

    func ttsFinished() {
        DispatchQueue.main.async { [self] in
            viewModel.ttsFinished()
        }
    }

    func dismiss() {
        DispatchQueue.main.async { [self] in
            viewModel.dismiss()
        }
    }

    private func ensurePanel() {
        if panel != nil { return }

        let hostingView = NSHostingView(rootView: OpenClawOverlayView(viewModel: viewModel))
        let panel = createGlassPanel(width: 400, height: 300)
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
