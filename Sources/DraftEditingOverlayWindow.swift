import Cocoa
import SwiftUI

// MARK: - Display Items

enum DraftEditDisplayItem: Identifiable {
    case paragraphSeparator(id: UUID, kind: ParagraphKind, index: Int, total: Int)
    case paragraphText(index: Int, text: String, kind: ParagraphKind)
    case editMarker(id: UUID, instruction: String)
    case editResult(id: UUID, original: String, replacement: String)

    var id: String {
        switch self {
        case .paragraphSeparator(let id, _, _, _): return "sep-\(id.uuidString)"
        case .paragraphText(let index, _, _): return "p-\(index)"
        case .editMarker(let id, _): return "em-\(id.uuidString)"
        case .editResult(let id, _, _): return "er-\(id.uuidString)"
        }
    }
}

// MARK: - ViewModel

class DraftEditingOverlayViewModel: ObservableObject {
    @Published var state: DraftEditingState = .idle
    @Published var fileName: String = ""
    @Published var currentParagraphIndex: Int = 0
    @Published var totalParagraphs: Int = 0
    @Published var currentParagraphText: String = ""
    @Published var currentParagraphKind: ParagraphKind = .body
    @Published var streamingEditText: String = ""
    @Published var editHistory: [DraftEditEntry] = []
    @Published var isPaused: Bool = false
    @Published var editorConnected: Bool = false

    var onStop: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrev: (() -> Void)?
    var onUndoEdit: ((Int) -> Void)?
    var onExportAudio: (() -> Void)?

    func update(state: DraftEditingState) {
        self.state = state
        if state != .reading {
            isPaused = false
        }
    }

    func loadDocument(_ document: MarkdownDocument) {
        self.fileName = (document.filePath as NSString).lastPathComponent
        self.totalParagraphs = document.paragraphs.filter { $0.kind != .frontmatter }.count
    }

    func activateParagraph(index: Int, paragraph: MarkdownParagraph) {
        self.currentParagraphIndex = index
        self.currentParagraphText = paragraph.text
        self.currentParagraphKind = paragraph.kind
    }

    func completeEdit(paragraphIndex: Int, original: String, replacement: String) {
        self.streamingEditText = ""
    }

    func updateStreamingEdit(_ text: String) {
        self.streamingEditText = text
    }

    func dismiss() {
        onStop?()
    }

    var kindLabel: String {
        switch currentParagraphKind {
        case .heading(let level):
            switch level {
            case 1: return "Section"
            case 2: return "Subsection"
            default: return "Heading"
            }
        case .body: return "Paragraph"
        case .codeBlock: return "Code Block"
        case .list: return "List"
        case .blockquote: return "Quote"
        case .horizontalRule: return "Separator"
        case .table: return "Table"
        case .frontmatter: return "Front Matter"
        case .htmlComment: return "Comment"
        }
    }
}

// MARK: - SwiftUI View

struct DraftEditingOverlayView: View {
    @ObservedObject var viewModel: DraftEditingOverlayViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            headerView

            Divider()

            // Content
            Group {
                switch viewModel.state {
                case .idle:
                    EmptyView()

                case .loading:
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading document...")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .reading, .paused, .complete:
                    VStack(spacing: 0) {
                        contentView
                        if viewModel.state != .complete {
                            pttHint
                        }
                    }

                case .listening:
                    VStack(spacing: 0) {
                        contentView
                        Divider()
                        listeningIndicator
                    }

                case .processingEdit:
                    VStack(spacing: 0) {
                        editPreviewView
                        Divider()
                        processingIndicator
                    }

                case .applyingEdit:
                    VStack(spacing: 0) {
                        editPreviewView
                        Divider()
                        applyingIndicator
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

            // Edit history footer
            if !viewModel.editHistory.isEmpty {
                Divider()
                editHistoryView
            }
        }
        .frame(width: 420, height: dynamicHeight)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: "pencil.and.outline")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text("Draft Editing")
                .font(.system(size: 13, weight: .semibold))

            if !viewModel.fileName.isEmpty {
                Text(viewModel.fileName)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            stateBadge

            // Navigation buttons
            if viewModel.state == .reading || viewModel.state == .paused {
                HStack(spacing: 4) {
                    Button(action: { viewModel.onPrev?() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Previous paragraph")

                    Button(action: { viewModel.onNext?() }) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 28, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Next paragraph")
                }
            }

            // Play/Pause
            if viewModel.state == .reading || viewModel.state == .paused {
                Button(action: { viewModel.onPlayPause?() }) {
                    Image(systemName: viewModel.isPaused ? "play.fill" : "pause.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(viewModel.isPaused ? "Resume" : "Pause")
            }

            // Export audio button
            if viewModel.state == .reading || viewModel.state == .paused || viewModel.state == .complete {
                Button(action: { viewModel.onExportAudio?() }) {
                    Image(systemName: "arrow.down.doc.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Download full audio")
            }

            Button(action: { viewModel.dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14))
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Stop and close")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .padding(.top, -12)
    }

    // MARK: - Content View

    private var contentView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Paragraph position + optional preview
            HStack(spacing: 6) {
                Text(viewModel.kindLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12))
                    .cornerRadius(3)

                Text("\(viewModel.currentParagraphIndex + 1) / \(viewModel.totalParagraphs)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)

                if viewModel.editorConnected {
                    Text(viewModel.currentParagraphText)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()
            }

            // Full paragraph text only when no editor is connected
            if !viewModel.editorConnected {
                ScrollView(.vertical, showsIndicators: false) {
                    Text(viewModel.currentParagraphText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
    }

    // MARK: - Edit Preview

    private var editPreviewView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Rewritten")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.green.opacity(0.8))
            if viewModel.streamingEditText.isEmpty {
                Text("Generating...")
                    .font(.system(size: 11, weight: .light))
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    Text(viewModel.streamingEditText)
                        .font(.system(size: 11))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
        .background(Color.green.opacity(0.05))
        .cornerRadius(6)
        .padding(12)
    }

    // MARK: - Edit History

    private var editHistoryView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Edits (\(viewModel.editHistory.count))")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(viewModel.editHistory.enumerated()), id: \.offset) { index, entry in
                        Button(action: { viewModel.onUndoEdit?(index) }) {
                            HStack(spacing: 3) {
                                Text("P\(entry.paragraphIndex + 1)")
                                    .font(.system(size: 9, weight: .bold))
                                Text(entry.instruction.prefix(20))
                                    .font(.system(size: 9))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                        .help("Undo: \(entry.instruction)")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Bottom Indicators

    private var pttHint: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text("Double-tap Left \u{2325} to edit this paragraph")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    private var listeningIndicator: some View {
        ListeningIndicatorView(
            prompt: "Describe how to edit this paragraph...",
            monitor: AudioLevelMonitor.shared
        )
    }

    private var processingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Rewriting paragraph...")
                .font(.system(size: 12))
                .foregroundColor(.orange)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.05))
    }

    private var applyingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Applying edit to file...")
                .font(.system(size: 12))
                .foregroundColor(.accentColor)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.05))
    }

    // MARK: - Helpers

    private var dynamicHeight: CGFloat {
        let historyHeight: CGFloat = viewModel.editHistory.isEmpty ? 0 : 50
        let compact = viewModel.editorConnected
        switch viewModel.state {
        case .idle: return 0
        case .loading: return 100
        case .error: return 120
        case .reading, .paused, .complete: return (compact ? 120 : 300) + historyHeight
        case .listening: return (compact ? 150 : 330) + historyHeight
        case .processingEdit, .applyingEdit: return 250 + historyHeight
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
        case .loading: return ("Loading", .orange)
        case .reading:
            return viewModel.isPaused ? ("Paused", .yellow) : ("Reading", .green)
        case .paused: return ("Paused", .yellow)
        case .listening: return ("Listening", .red)
        case .processingEdit: return ("Rewriting", .orange)
        case .applyingEdit: return ("Applying", .accentColor)
        case .complete: return ("Complete", .blue)
        case .error: return ("Error", .red)
        }
    }
}

// MARK: - Overlay Window

class DraftEditingOverlayWindow {
    private var panel: NSPanel?
    let viewModel = DraftEditingOverlayViewModel()
    var onStop: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrev: (() -> Void)?
    var onUndoEdit: ((Int) -> Void)?
    var onExportAudio: (() -> Void)?
    private var autoDismissTimer: Timer?

    init() {
        viewModel.onStop = { [weak self] in self?.onStop?() }
        viewModel.onPlayPause = { [weak self] in self?.onPlayPause?() }
        viewModel.onNext = { [weak self] in self?.onNext?() }
        viewModel.onPrev = { [weak self] in self?.onPrev?() }
        viewModel.onUndoEdit = { [weak self] index in self?.onUndoEdit?(index) }
        viewModel.onExportAudio = { [weak self] in self?.onExportAudio?() }
    }

    func show(state: DraftEditingState) {
        DispatchQueue.main.async { [self] in
            let wasHidden = !(panel?.isVisible ?? false)
            viewModel.update(state: state)
            ensurePanel()
            if wasHidden { repositionPanel() }
            panel?.orderFront(nil)
        }
    }

    func updateState(_ state: DraftEditingState) {
        DispatchQueue.main.async { [self] in
            viewModel.update(state: state)
            if state != .idle {
                ensurePanel()
                panel?.orderFront(nil)
            }

            autoDismissTimer?.invalidate()
            if state == .complete {
                autoDismissTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                    self?.dismiss()
                }
            }
        }
    }

    func loadDocument(_ document: MarkdownDocument) {
        DispatchQueue.main.async { [self] in
            viewModel.loadDocument(document)
        }
    }

    func activateParagraph(index: Int, paragraph: MarkdownParagraph) {
        DispatchQueue.main.async { [self] in
            viewModel.activateParagraph(index: index, paragraph: paragraph)
        }
    }

    func completeEdit(paragraphIndex: Int, original: String, replacement: String) {
        DispatchQueue.main.async { [self] in
            viewModel.completeEdit(paragraphIndex: paragraphIndex, original: original, replacement: replacement)
        }
    }

    func updateStreamingEdit(_ text: String) {
        DispatchQueue.main.async { [self] in
            viewModel.updateStreamingEdit(text)
        }
    }

    func updateEditHistory(_ history: [DraftEditEntry]) {
        DispatchQueue.main.async { [self] in
            viewModel.editHistory = history
        }
    }

    func updatePaused(_ paused: Bool) {
        DispatchQueue.main.async { [self] in
            viewModel.isPaused = paused
        }
    }

    func dismiss() {
        DispatchQueue.main.async { [self] in
            autoDismissTimer?.invalidate()
            panel?.orderOut(nil)
        }
    }

    private func ensurePanel() {
        if panel != nil { return }

        let hostingView = NSHostingView(rootView: DraftEditingOverlayView(viewModel: viewModel))

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
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
        let x = (screenFrame.width - 420) / 2 + screenFrame.minX
        let y = screenFrame.maxY - panelHeight - 40
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
