import Cocoa
import UniformTypeIdentifiers

private struct ParsedEntry {
    let question: String?
    let answer: String

    init(text: String) {
        // Parse "Q: ...\nA: ..." format from OpenClaw entries
        if text.hasPrefix("Q: "), let aRange = text.range(of: "\nA: ") {
            question = String(text[text.index(text.startIndex, offsetBy: 3)..<aRange.lowerBound])
            answer = String(text[aRange.upperBound...])
        } else {
            question = nil
            answer = text
        }
    }
}

/// Maximum number of preview lines shown before a "show more" ellipsis.
private let kPreviewLineLimit = 5

class TranscriptionHistoryViewController: NSViewController, NSTableViewDelegate, NSTableViewDataSource {
    private let tableView: NSTableView
    private let scrollView: NSScrollView
    private let clearButton: NSButton
    private let refreshButton: NSButton
    private let titleLabel: NSTextField
    private var entries: [TranscriptionEntry] = []
    private var parsed: [ParsedEntry] = []
    private var copiedRow: Int? = nil
    private var copiedResetTimer: Timer?

    init() {
        self.tableView = NSTableView()
        self.scrollView = NSScrollView()
        self.clearButton = NSButton(title: "Clear History", target: nil, action: #selector(clearHistory))
        self.refreshButton = NSButton(title: "Refresh", target: nil, action: #selector(refreshHistory))
        self.titleLabel = NSTextField(labelWithString: "History")

        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 560))
        setupUI()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadEntries()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        loadEntries()
    }

    private func setupUI() {
        titleLabel.font = .boldSystemFont(ofSize: 14)
        titleLabel.alignment = .left
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .lineBorder
        view.addSubview(scrollView)

        tableView.delegate = self
        tableView.dataSource = self
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.target = nil
        tableView.action = nil

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.title = ""
        tableView.addTableColumn(column)

        scrollView.documentView = tableView

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Copy Text", action: #selector(contextCopy), keyEquivalent: "c"))
        menu.addItem(NSMenuItem(title: "Save Audio…", action: #selector(contextSaveAudio), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Delete", action: #selector(contextDelete), keyEquivalent: ""))
        tableView.menu = menu

        clearButton.target = self
        clearButton.bezelStyle = .rounded
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(clearButton)

        refreshButton.target = self
        refreshButton.bezelStyle = .rounded
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(refreshButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: clearButton.topAnchor, constant: -20),

            clearButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            clearButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            clearButton.widthAnchor.constraint(equalToConstant: 120),

            refreshButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            refreshButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            refreshButton.widthAnchor.constraint(equalToConstant: 100)
        ])
    }

    private func loadEntries() {
        entries = TranscriptionHistory.shared.getEntries()
        parsed = entries.map { ParsedEntry(text: $0.text) }
        tableView.reloadData()

        if entries.isEmpty {
            titleLabel.stringValue = "No history yet"
            clearButton.isEnabled = false
        } else {
            let podcastCount = entries.filter { $0.kind == .podcast }.count
            let transcriptCount = entries.count - podcastCount
            titleLabel.stringValue = "History — \(transcriptCount) transcript\(transcriptCount == 1 ? "" : "s"), \(podcastCount) podcast\(podcastCount == 1 ? "" : "s")"
            clearButton.isEnabled = true
        }
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear History"
        alert.informativeText = "Are you sure you want to clear all history? This also removes saved podcast audio files."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            TranscriptionHistory.shared.clearHistory()
            loadEntries()
        }
    }

    @objc func refreshHistory() {
        loadEntries()
    }

    // MARK: - Copy / Save / Delete actions

    private func previewText(at row: Int) -> String {
        guard row >= 0, row < parsed.count else { return "" }
        let entry = entries[row]
        if entry.kind == .podcast {
            // Strip markdown markers for a cleaner preview while keeping the
            // full markdown in the clipboard copy.
            return cleanedPodcastPreview(text: entry.text)
        }
        return parsed[row].answer
    }

    private func cleanedPodcastPreview(text: String) -> String {
        // Drop the title header, unwrap **speaker:** bold, drop horizontal rules.
        var lines: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            if line.hasPrefix("# ") { continue }
            if line == "---" { continue }
            if line.hasPrefix("**") {
                line = line.replacingOccurrences(of: "**", with: "")
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        return lines.joined(separator: "\n")
    }

    private func copyTextForRow(_ row: Int) {
        guard row >= 0, row < entries.count else { return }
        let entry = entries[row]
        let text = entry.kind == .podcast ? entry.text : parsed[row].answer
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        copiedResetTimer?.invalidate()
        copiedRow = row
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))

        copiedResetTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            let previousRow = self.copiedRow
            self.copiedRow = nil
            if let previousRow = previousRow, previousRow < self.entries.count {
                self.tableView.reloadData(forRowIndexes: IndexSet(integer: previousRow), columnIndexes: IndexSet(integer: 0))
            }
        }
    }

    private func saveAudioForRow(_ row: Int) {
        guard row >= 0, row < entries.count else { return }
        let entry = entries[row]
        guard entry.kind == .podcast,
              let sourceURL = TranscriptionHistory.shared.audioURL(for: entry) else {
            NSSound.beep()
            return
        }

        let savePanel = NSSavePanel()
        savePanel.title = "Save Podcast Audio"
        if #available(macOS 11.0, *) {
            savePanel.allowedContentTypes = [UTType.wav]
        } else {
            savePanel.allowedFileTypes = ["wav"]
        }
        let safeTitle = (entry.title ?? "Podcast")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        savePanel.nameFieldStringValue = "\(safeTitle).wav"

        savePanel.begin { response in
            guard response == .OK, let destURL = savePanel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destURL)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func deleteRow(_ row: Int) {
        guard row >= 0, row < entries.count else { return }
        TranscriptionHistory.shared.deleteEntry(at: row)
        loadEntries()
    }

    @objc private func copyButtonClicked(_ sender: NSButton) {
        copyTextForRow(sender.tag)
    }

    @objc private func saveAudioButtonClicked(_ sender: NSButton) {
        saveAudioForRow(sender.tag)
    }

    @objc private func contextCopy() {
        copyTextForRow(tableView.clickedRow)
    }

    @objc private func contextSaveAudio() {
        saveAudioForRow(tableView.clickedRow)
    }

    @objc private func contextDelete() {
        deleteRow(tableView.clickedRow)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return entries.count
    }

    // MARK: - NSTableViewDelegate

    private let kRowLeadingInset: CGFloat = 10
    private let kRowTrailingInset: CGFloat = 10
    private let kRowTopInset: CGFloat = 8
    private let kRowBottomInset: CGFloat = 8
    private let kButtonColumnWidth: CGFloat = 170
    private let kTimeColumnWidth: CGFloat = 108

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let entry = entries[row]
        let p = parsed[row]
        let isCopied = copiedRow == row
        let isPodcast = entry.kind == .podcast

        let cellView = NSView()

        // --- Header row: time + kind badge + (optional) podcast title ---
        let timeLabel = NSTextField(labelWithString: formatDate(entry.timestamp))
        timeLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(timeLabel)

        let badge = NSTextField(labelWithString: isPodcast ? "Podcast" : "Transcript")
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = isPodcast ? .systemPurple : .systemTeal
        badge.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(badge)

        // --- Action buttons (right side) ---
        let copyButton = NSButton(title: isCopied ? "Copied!" : "Copy Text", target: self, action: #selector(copyButtonClicked(_:)))
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.tag = row
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(copyButton)

        var trailingAnchorForPreview: NSLayoutXAxisAnchor = copyButton.leadingAnchor

        if isPodcast {
            let audioButton = NSButton(title: "Save Audio", target: self, action: #selector(saveAudioButtonClicked(_:)))
            audioButton.bezelStyle = .rounded
            audioButton.controlSize = .small
            audioButton.tag = row
            audioButton.isEnabled = TranscriptionHistory.shared.audioURL(for: entry) != nil
            audioButton.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(audioButton)

            NSLayoutConstraint.activate([
                audioButton.topAnchor.constraint(equalTo: cellView.topAnchor, constant: kRowTopInset),
                audioButton.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -kRowTrailingInset),
                audioButton.widthAnchor.constraint(equalToConstant: 90),
                copyButton.topAnchor.constraint(equalTo: cellView.topAnchor, constant: kRowTopInset),
                copyButton.trailingAnchor.constraint(equalTo: audioButton.leadingAnchor, constant: -6),
                copyButton.widthAnchor.constraint(equalToConstant: 80),
            ])
            trailingAnchorForPreview = copyButton.leadingAnchor
        } else {
            NSLayoutConstraint.activate([
                copyButton.topAnchor.constraint(equalTo: cellView.topAnchor, constant: kRowTopInset),
                copyButton.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -kRowTrailingInset),
                copyButton.widthAnchor.constraint(equalToConstant: 80),
            ])
            trailingAnchorForPreview = copyButton.leadingAnchor
        }

        NSLayoutConstraint.activate([
            timeLabel.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: kRowLeadingInset),
            timeLabel.topAnchor.constraint(equalTo: cellView.topAnchor, constant: kRowTopInset),
            timeLabel.widthAnchor.constraint(lessThanOrEqualToConstant: kTimeColumnWidth),

            badge.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 8),
            badge.centerYAnchor.constraint(equalTo: timeLabel.centerYAnchor),
        ])

        // --- Body: optional title, optional question, then preview text ---
        var previousBottom = timeLabel.bottomAnchor
        let bodyLeading = cellView.leadingAnchor
        let bodyTrailing = trailingAnchorForPreview

        if isPodcast, let title = entry.title, !title.isEmpty {
            let titleLabel = NSTextField(labelWithString: title)
            titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            titleLabel.textColor = .labelColor
            titleLabel.maximumNumberOfLines = 1
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(titleLabel)

            NSLayoutConstraint.activate([
                titleLabel.leadingAnchor.constraint(equalTo: bodyLeading, constant: kRowLeadingInset),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: bodyTrailing, constant: -8),
                titleLabel.topAnchor.constraint(equalTo: previousBottom, constant: 6),
            ])
            previousBottom = titleLabel.bottomAnchor
        }

        if !isPodcast, let question = p.question {
            let questionLabel = NSTextField(wrappingLabelWithString: question)
            questionLabel.font = .systemFont(ofSize: 12)
            questionLabel.textColor = .secondaryLabelColor
            questionLabel.maximumNumberOfLines = 2
            questionLabel.lineBreakMode = .byTruncatingTail
            questionLabel.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(questionLabel)

            NSLayoutConstraint.activate([
                questionLabel.leadingAnchor.constraint(equalTo: bodyLeading, constant: kRowLeadingInset),
                questionLabel.trailingAnchor.constraint(lessThanOrEqualTo: bodyTrailing, constant: -8),
                questionLabel.topAnchor.constraint(equalTo: previousBottom, constant: 4),
            ])
            previousBottom = questionLabel.bottomAnchor
        }

        let preview = previewText(at: row)
        let previewLabel = NSTextField(wrappingLabelWithString: preview)
        previewLabel.font = .systemFont(ofSize: 13)
        previewLabel.textColor = .labelColor
        previewLabel.maximumNumberOfLines = kPreviewLineLimit
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(previewLabel)

        NSLayoutConstraint.activate([
            previewLabel.leadingAnchor.constraint(equalTo: bodyLeading, constant: kRowLeadingInset),
            previewLabel.trailingAnchor.constraint(lessThanOrEqualTo: bodyTrailing, constant: -8),
            previewLabel.topAnchor.constraint(equalTo: previousBottom, constant: 4),
            previewLabel.bottomAnchor.constraint(lessThanOrEqualTo: cellView.bottomAnchor, constant: -kRowBottomInset),
        ])

        return cellView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < entries.count else { return 48 }
        let entry = entries[row]
        let p = parsed[row]
        let isPodcast = entry.kind == .podcast
        let availableWidth = max(tableView.bounds.width - kRowLeadingInset - kButtonColumnWidth - kRowTrailingInset, 200)

        var total: CGFloat = kRowTopInset + kRowBottomInset
        // First row: time + badge (≈ 16pt tall) + 4pt spacer
        total += 16 + 4

        if isPodcast, let title = entry.title, !title.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
            let size = (title as NSString).boundingRect(
                with: NSSize(width: availableWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs
            )
            total += min(size.height, 22) + 4
        }

        if !isPodcast, let question = p.question {
            let qAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
            let qSize = (question as NSString).boundingRect(
                with: NSSize(width: availableWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: qAttrs
            )
            total += min(qSize.height, 32) + 4 // cap at 2 lines
        }

        // Preview: clamp to the 5-line limit regardless of actual text length.
        let preview = isPodcast ? cleanedPodcastPreview(text: entry.text) : p.answer
        let pAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]
        let pSize = (preview as NSString).boundingRect(
            with: NSSize(width: availableWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: pAttrs
        )
        let lineHeight: CGFloat = 17
        let maxPreviewHeight = lineHeight * CGFloat(kPreviewLineLimit) + 2
        total += min(pSize.height, maxPreviewHeight)

        return max(56, total)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "h:mm a"
            return "Yesterday " + formatter.string(from: date)
        } else {
            formatter.dateFormat = "MMM d, h:mm a"
            return formatter.string(from: date)
        }
    }
}
