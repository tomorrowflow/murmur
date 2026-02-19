import Cocoa
import SwiftUI

// MARK: - Overlay State

enum OpenClawOverlayState {
    case hidden
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

    var isHovered: Bool = false
    var onDismiss: (() -> Void)?
    var onCancel: (() -> Void)?

    private var autoDismissTimer: Timer?

    func show(state: OpenClawOverlayState) {
        cancelAutoDismiss()
        self.state = state
        if state == .listening {
            responseText = ""
            errorText = ""
            isPinned = false
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
        state = .hidden
        responseText = ""
        errorText = ""
        isPinned = false
        isHovered = false
        onDismiss?()
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
            HStack {
                WaveformIcon()
                    .frame(width: 14, height: 14)
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
                        Text("Listening...")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .processing:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Processing...")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

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
        .frame(width: 420, height: dynamicHeight)
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
        case .listening, .processing: return 100
        case .error: return 120
        case .streaming, .complete: return min(400, max(120, CGFloat(viewModel.responseText.count / 2) + 80))
        }
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch viewModel.state {
        case .listening:
            Text("Listening")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.15))
                .cornerRadius(4)

        case .processing:
            Text("Processing")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.15))
                .cornerRadius(4)

        case .streaming:
            Text("Streaming")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.blue)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.15))
                .cornerRadius(4)

        case .complete:
            Text("Complete")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.15))
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

class OpenClawOverlayWindow {
    private var panel: NSPanel?
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
            viewModel.show(state: state)
            ensurePanel()
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

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
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
            let x = (screenFrame.width - 420) / 2 + screenFrame.minX
            let y = screenFrame.maxY - 300 - 40
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.panel = panel
    }
}
