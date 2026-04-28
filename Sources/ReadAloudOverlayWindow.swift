import Cocoa
import SwiftUI

// MARK: - Display Items

enum ReadAloudDisplayItem: Identifiable {
    case sentence(index: Int, text: String)
    case interruptMarker(id: UUID, question: String)
    case answer(id: UUID, text: String)

    var id: String {
        switch self {
        case .sentence(let index, _): return "s-\(index)"
        case .interruptMarker(let id, _): return "q-\(id.uuidString)"
        case .answer(let id, _): return "a-\(id.uuidString)"
        }
    }
}

// MARK: - ViewModel

class ReadAloudOverlayViewModel: ObservableObject {
    @Published var state: ReadAloudState = .idle
    @Published var sentences: [String] = []
    @Published var currentSentenceIndex: Int = 0
    @Published var displayItems: [ReadAloudDisplayItem] = []
    @Published var currentAnswer: String = ""
    @Published var pendingQuestion: String = ""
    @Published var translationStatus: String = "Detecting language..."
    @Published var isPaused: Bool = false
    /// Mirrors `ReadAloudManager.isMuted`. When true, the speaker icon in
    /// the header shows the muted glyph and the underlying TTS player runs
    /// at volume 0 — synthesis and transcript advancement still happen.
    @Published var isMuted: Bool = UserDefaults.standard.bool(forKey: "readAloud.muted")
    @Published var webSearchEnabled: Bool = UserDefaults.standard.bool(forKey: "readAloud.webSearchEnabled")
    @Published var targetAppIcon: NSImage?
    @Published var targetAppName: String?

    var onStop: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onMuteToggled: ((Bool) -> Void)?
    var onWebSearchToggled: ((Bool) -> Void)?
    var onExportAudio: (() -> Void)?
    var onExportMarkdown: (() -> Void)?

    func update(state: ReadAloudState) {
        self.state = state
        // Only clear pause for states where pause doesn't apply
        if state != .reading && state != .speakingAnswer {
            isPaused = false
        }
    }

    func updateSentences(_ newSentences: [String]) {
        self.sentences = newSentences
        rebuildDisplayItems()
    }

    func activateSentence(index: Int) {
        self.currentSentenceIndex = index
    }

    func insertQA(question: String, answer: String, afterSentenceIndex: Int) {
        rebuildDisplayItems(pendingQA: (question: question, answer: answer, after: afterSentenceIndex))
    }

    func updateStreamingAnswer(_ text: String) {
        self.currentAnswer = text
    }

    func dismiss() {
        onStop?()
    }

    // Track Q&A pairs for display item rebuilding
    private var insertedQAs: [(question: String, answer: String, after: Int)] = []

    private func rebuildDisplayItems(pendingQA: (question: String, answer: String, after: Int)? = nil) {
        if let qa = pendingQA {
            insertedQAs.append(qa)
        }

        var items: [ReadAloudDisplayItem] = []
        for (i, sentence) in sentences.enumerated() {
            items.append(.sentence(index: i, text: sentence))

            // Insert any Q&A pairs that belong after this sentence
            for qa in insertedQAs where qa.after == i {
                let id = UUID()
                items.append(.interruptMarker(id: id, question: qa.question))
                items.append(.answer(id: UUID(), text: qa.answer))
            }
        }
        displayItems = items
    }
}

// MARK: - SwiftUI View

struct ReadAloudOverlayView: View {
    @ObservedObject var viewModel: ReadAloudOverlayViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 8) {
                AppIconView(icon: viewModel.targetAppIcon, size: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Read Aloud")
                        .font(.system(size: 13, weight: .semibold))
                    if let name = viewModel.targetAppName {
                        Text(name)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                stateBadge

                // Play/Pause button — always visible in active states
                if viewModel.state != .idle && viewModel.state != .translating {
                    Button(action: {
                        viewModel.onPlayPause?()
                    }) {
                        Image(systemName: playPauseIcon)
                            .foregroundColor(.secondary)
                            .font(.system(size: 13))
                            .frame(width: 28, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(playPauseHelp)

                    // Mute button — silences TTS while leaving sentence
                    // pacing and transcript display unchanged.
                    Button(action: {
                        viewModel.isMuted.toggle()
                        viewModel.onMuteToggled?(viewModel.isMuted)
                    }) {
                        Image(systemName: viewModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundColor(viewModel.isMuted ? .orange : .secondary)
                            .font(.system(size: 13))
                            .frame(width: 28, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(viewModel.isMuted ? "Unmute spoken audio" : "Mute spoken audio (transcript continues)")
                }

                // Export buttons — visible once reading has started
                if viewModel.state == .reading || viewModel.state == .complete
                    || viewModel.state == .listening || viewModel.state == .processingQuestion
                    || viewModel.state == .speakingAnswer || viewModel.state == .awaitingResume {
                    Button(action: { viewModel.onExportAudio?() }) {
                        Image(systemName: "arrow.down.doc.fill")
                            .foregroundColor(viewModel.state == .complete ? .secondary : .secondary.opacity(0.3))
                            .font(.system(size: 13))
                            .frame(width: 28, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.state != .complete)
                    .help("Download full audio")

                    Button(action: { viewModel.onExportMarkdown?() }) {
                        Image(systemName: "arrow.down.doc")
                            .foregroundColor(.secondary)
                            .font(.system(size: 13))
                            .frame(width: 28, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Export transcript as Markdown")
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
            .padding(.vertical, 10)

            Divider()

            // Content
            Group {
                switch viewModel.state {
                case .idle:
                    EmptyView()

                case .translating:
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(viewModel.translationStatus)
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                case .reading, .complete:
                    VStack(spacing: 0) {
                        contentScrollView
                        if viewModel.state == .reading {
                            pttHint
                        }
                    }

                case .listening:
                    VStack(spacing: 0) {
                        contentScrollView
                        Divider()
                        listeningIndicator
                    }

                case .processingQuestion:
                    VStack(spacing: 0) {
                        contentScrollView
                        Divider()
                        processingIndicator
                    }

                case .speakingAnswer:
                    VStack(spacing: 0) {
                        contentScrollView
                        Divider()
                        answerIndicator
                    }

                case .awaitingResume:
                    VStack(spacing: 0) {
                        contentScrollView
                        Divider()
                        resumeHint
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
        .glassBackground()
    }

    // MARK: - Content Scroll View

    private var contentScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(viewModel.displayItems) { item in
                        switch item {
                        case .sentence(let index, let text):
                            let isActive = index == viewModel.currentSentenceIndex
                            let isPast = index < viewModel.currentSentenceIndex
                            Text(text)
                                .font(.system(size: 12))
                                .foregroundColor(isActive ? .primary : (isPast ? .secondary.opacity(0.45) : .primary.opacity(0.7)))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 2)
                                .padding(.horizontal, 4)
                                .background(isActive ? Color.accentColor.opacity(0.1) : Color.clear)
                                .cornerRadius(4)
                                .id(item.id)

                        case .interruptMarker(_, let question):
                            HStack(spacing: 6) {
                                Rectangle()
                                    .fill(Color.orange.opacity(0.5))
                                    .frame(height: 1)
                                HStack(spacing: 4) {
                                    Image(systemName: "hand.raised.fill")
                                        .font(.system(size: 9))
                                    Text(question)
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
                            .id(item.id)

                        case .answer(_, let text):
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "brain.head.profile")
                                    .font(.system(size: 11))
                                    .foregroundColor(.accentColor)
                                Text(text)
                                    .font(.system(size: 12))
                                    .foregroundColor(.primary.opacity(0.85))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 2)
                            .padding(.horizontal, 4)
                            .background(Color.accentColor.opacity(0.05))
                            .cornerRadius(4)
                            .id(item.id)
                        }
                    }

                    // Show pending question immediately when user asks
                    if !viewModel.pendingQuestion.isEmpty && (viewModel.state == .processingQuestion || viewModel.state == .speakingAnswer) {
                        HStack(spacing: 6) {
                            Rectangle()
                                .fill(Color.orange.opacity(0.5))
                                .frame(height: 1)
                            HStack(spacing: 4) {
                                Image(systemName: "hand.raised.fill")
                                    .font(.system(size: 9))
                                Text(viewModel.pendingQuestion)
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
                        .id("pending-question")
                    }

                    // Show streaming answer if in progress
                    if (viewModel.state == .processingQuestion || viewModel.state == .speakingAnswer) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "brain.head.profile")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                            if viewModel.currentAnswer.isEmpty {
                                Text("Thinking...")
                                    .font(.system(size: 12, weight: .light))
                                    .foregroundColor(.secondary)
                                    .italic()
                            } else {
                                Text(viewModel.currentAnswer)
                                    .font(.system(size: 12))
                                    .foregroundColor(.primary.opacity(0.85))
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 2)
                        .padding(.horizontal, 4)
                        .background(Color.orange.opacity(0.05))
                        .cornerRadius(4)
                        .id("streaming-answer")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.currentSentenceIndex) { _ in
                let targetId = "s-\(viewModel.currentSentenceIndex)"
                withAnimation(.easeOut(duration: 0.3)) {
                    proxy.scrollTo(targetId, anchor: .center)
                }
            }
            .onChange(of: viewModel.currentAnswer) { _ in
                if viewModel.state == .processingQuestion || viewModel.state == .speakingAnswer {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("streaming-answer", anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Bottom Indicators

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

    private var listeningIndicator: some View {
        ListeningIndicatorView(
            prompt: "Listening...",
            monitor: AudioLevelMonitor.shared
        )
    }

    private var processingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Thinking...")
                .font(.system(size: 12))
                .foregroundColor(.orange)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.05))
    }

    private var answerIndicator: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundColor(.accentColor)
                .font(.system(size: 14))
                .symbolEffect(.variableColor.iterative)
            Text("Speaking answer...")
                .font(.system(size: 12))
                .foregroundColor(.accentColor)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.05))
    }

    private var resumeHint: some View {
        HStack(spacing: 8) {
            Button(action: { viewModel.onPlayPause?() }) {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                    Text("Continue reading")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(5)
            }
            .buttonStyle(.plain)

            Text("or double-tap Left ⌥ to ask a question")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.7))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.05))
    }

    // MARK: - Play/Pause Helpers

    private var playPauseIcon: String {
        switch viewModel.state {
        case .reading where !viewModel.isPaused:
            return "pause.fill"
        case .speakingAnswer where !viewModel.isPaused:
            return "pause.fill"
        default:
            return "play.fill"
        }
    }

    private var playPauseHelp: String {
        switch viewModel.state {
        case .awaitingResume: return "Continue reading"
        case .complete: return "Replay"
        case .reading where viewModel.isPaused: return "Resume"
        case .reading: return "Pause"
        case .speakingAnswer where viewModel.isPaused: return "Resume answer"
        case .speakingAnswer: return "Pause answer"
        case .listening, .processingQuestion: return "Skip and continue reading"
        default: return "Play"
        }
    }

    // MARK: - Helpers

    private var dynamicHeight: CGFloat {
        switch viewModel.state {
        case .idle: return 0
        case .translating: return 100
        case .error: return 120
        case .reading, .complete: return 300
        case .listening, .processingQuestion, .speakingAnswer, .awaitingResume: return 330
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
        case .translating: return ("Translating", .orange)
        case .reading:
            if viewModel.isPaused {
                return ("Paused", .yellow)
            }
            return ("Reading", .green)
        case .listening: return ("Listening", .red)
        case .processingQuestion: return ("Thinking", .orange)
        case .speakingAnswer:
            if viewModel.isPaused {
                return ("Paused", .yellow)
            }
            return ("Answering", .accentColor)
        case .awaitingResume: return ("Continue?", .accentColor)
        case .complete: return ("Complete", .blue)
        case .error: return ("Error", .red)
        }
    }
}

// MARK: - Overlay Window

class ReadAloudOverlayWindow {
    private var panel: NSPanel?
    private var panelResizeObserver: NSObjectProtocol?
    let viewModel = ReadAloudOverlayViewModel()
    var onStop: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onMuteToggled: ((Bool) -> Void)?
    var onWebSearchToggled: ((Bool) -> Void)?
    var onExportAudio: (() -> Void)?
    var onExportMarkdown: (() -> Void)?
    private var autoDismissTimer: Timer?
    private var escapeGlobalMonitor: Any?
    private var escapeLocalMonitor: Any?

    init() {
        viewModel.onStop = { [weak self] in
            self?.onStop?()
            // Always hide the panel ourselves so the X button can't be orphaned
            // if the external onStop handler's references are stale.
            self?.dismissNow()
        }
        viewModel.onPlayPause = { [weak self] in
            self?.onPlayPause?()
        }
        viewModel.onMuteToggled = { [weak self] muted in
            self?.onMuteToggled?(muted)
        }
        viewModel.onWebSearchToggled = { [weak self] enabled in
            self?.onWebSearchToggled?(enabled)
        }
        viewModel.onExportAudio = { [weak self] in
            self?.onExportAudio?()
        }
        viewModel.onExportMarkdown = { [weak self] in
            self?.exportMarkdown()
        }
    }

    func show(state: ReadAloudState) {
        DispatchQueue.main.async { [self] in
            let wasHidden = !(panel?.isVisible ?? false)
            viewModel.update(state: state)
            ensurePanel()
            if wasHidden { repositionPanel() }
            panel?.orderFront(nil)
            installEscapeMonitor()
        }
    }

    private func installEscapeMonitor() {
        if escapeLocalMonitor != nil || escapeGlobalMonitor != nil { return }
        let fire: () -> Void = { [weak self] in
            NSLog("ReadAloudOverlay: Escape monitor fired — dismissing")
            DispatchQueue.main.async { self?.viewModel.dismiss() }
        }
        escapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { fire() }
        }
        escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                fire()
                return nil
            }
            return event
        }
        NSLog("ReadAloudOverlay: Escape monitors installed (global: \(escapeGlobalMonitor != nil), local: \(escapeLocalMonitor != nil))")
    }

    private func removeEscapeMonitor() {
        if let m = escapeGlobalMonitor {
            NSEvent.removeMonitor(m)
            escapeGlobalMonitor = nil
        }
        if let m = escapeLocalMonitor {
            NSEvent.removeMonitor(m)
            escapeLocalMonitor = nil
        }
    }

    func updateState(_ state: ReadAloudState) {
        DispatchQueue.main.async { [self] in
            viewModel.update(state: state)
            if state != .idle {
                ensurePanel()
                panel?.orderFront(nil)
            }

            // Auto-dismiss after completion
            autoDismissTimer?.invalidate()
            if state == .complete {
                autoDismissTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                    self?.dismiss()
                }
            }
        }
    }

    func updateSentences(_ sentences: [String]) {
        DispatchQueue.main.async { [self] in
            viewModel.updateSentences(sentences)
        }
    }

    func activateSentence(index: Int) {
        DispatchQueue.main.async { [self] in
            viewModel.activateSentence(index: index)
        }
    }

    func insertQA(question: String, answer: String, afterSentenceIndex: Int) {
        DispatchQueue.main.async { [self] in
            viewModel.pendingQuestion = ""
            viewModel.currentAnswer = ""
            viewModel.insertQA(question: question, answer: answer, afterSentenceIndex: afterSentenceIndex)
        }
    }

    func showPendingQuestion(_ question: String) {
        DispatchQueue.main.async { [self] in
            viewModel.pendingQuestion = question
        }
    }

    func updateStreamingAnswer(_ text: String) {
        DispatchQueue.main.async { [self] in
            viewModel.updateStreamingAnswer(text)
        }
    }

    func updateTranslationStatus(_ status: String) {
        DispatchQueue.main.async { [self] in
            viewModel.translationStatus = status
        }
    }

    func updatePaused(_ paused: Bool) {
        DispatchQueue.main.async { [self] in
            viewModel.isPaused = paused
        }
    }

    func exportMarkdown() {
        DispatchQueue.main.async { [self] in
            var md = "# Read Aloud\n\n"
            for item in viewModel.displayItems {
                switch item {
                case .sentence(_, let text):
                    md += "\(text)\n\n"
                case .interruptMarker(_, let question):
                    md += "\n---\n*Question: \(question)*\n---\n\n"
                case .answer(_, let text):
                    md += "**Answer:** \(text)\n\n"
                }
            }

            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.init(filenameExtension: "md")!]
            savePanel.nameFieldStringValue = "Read Aloud.md"
            savePanel.level = .floating + 1
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
            autoDismissTimer?.invalidate()
            removeEscapeMonitor()
            panel?.orderOut(nil)
        }
    }

    func dismissNow() {
        autoDismissTimer?.invalidate()
        removeEscapeMonitor()
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        if panel != nil { return }

        let hostingView = NSHostingView(rootView: ReadAloudOverlayView(viewModel: viewModel))
        let panel = createGlassPanel(width: 380, height: 300)
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
