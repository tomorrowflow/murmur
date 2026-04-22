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
private let kPreviewLineLimit = 2

class TranscriptionHistoryViewController: NSViewController, NSTableViewDelegate, NSTableViewDataSource, NSSearchFieldDelegate {
    private let tableView: NSTableView
    private let scrollView: NSScrollView
    private let clearButton: NSButton
    private let refreshButton: NSButton
    private let titleLabel: NSTextField
    private let filterControl: NSSegmentedControl
    private let searchField: NSSearchField
    private var allEntries: [TranscriptionEntry] = []
    private var allParsed: [ParsedEntry] = []
    private var entries: [TranscriptionEntry] = []
    private var parsed: [ParsedEntry] = []
    private var copiedRow: Int? = nil
    private var copiedResetTimer: Timer?
    private var activeFilter: HistoryEntryKind? = nil
    private var searchQuery: String = ""

    init() {
        self.tableView = NSTableView()
        self.scrollView = NSScrollView()
        self.clearButton = NSButton(title: "Clear History", target: nil, action: #selector(clearHistory))
        self.refreshButton = NSButton(title: "Refresh", target: nil, action: #selector(refreshHistory))
        self.titleLabel = NSTextField(labelWithString: "History")
        self.filterControl = NSSegmentedControl(labels: ["All", "Transcripts", "Recaps", "Podcasts", "Approvals"], trackingMode: .selectOne, target: nil, action: #selector(filterChanged))
        self.searchField = NSSearchField()

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

        filterControl.target = self
        filterControl.action = #selector(filterChanged)
        filterControl.selectedSegment = 0
        filterControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(filterControl)

        searchField.placeholderString = "Search text…"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        searchField.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchField)

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

            filterControl.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            filterControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            searchField.centerYAnchor.constraint(equalTo: filterControl.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: filterControl.trailingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: filterControl.bottomAnchor, constant: 10),
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
        allEntries = TranscriptionHistory.shared.getEntries()
        allParsed = allEntries.map { ParsedEntry(text: $0.text) }
        applyFilter()

        if allEntries.isEmpty {
            titleLabel.stringValue = "No history yet"
            clearButton.isEnabled = false
        } else {
            let podcastCount = allEntries.filter { $0.kind == .podcast }.count
            let recapCount = allEntries.filter { $0.kind == .recap }.count
            let permissionCount = allEntries.filter { $0.kind == .permission }.count
            let transcriptCount = allEntries.count - podcastCount - recapCount - permissionCount
            var parts: [String] = []
            parts.append("\(transcriptCount) transcript\(transcriptCount == 1 ? "" : "s")")
            parts.append("\(recapCount) recap\(recapCount == 1 ? "" : "s")")
            parts.append("\(podcastCount) podcast\(podcastCount == 1 ? "" : "s")")
            if permissionCount > 0 {
                parts.append("\(permissionCount) approval\(permissionCount == 1 ? "" : "s")")
            }
            titleLabel.stringValue = "History — " + parts.joined(separator: ", ")
            clearButton.isEnabled = true
        }
    }

    private func applyFilter() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var filtered: [(TranscriptionEntry, ParsedEntry)] = []
        for (entry, p) in zip(allEntries, allParsed) {
            if let kind = activeFilter, entry.kind != kind { continue }
            if !query.isEmpty {
                let haystack = [entry.text, entry.title ?? "", entry.spokenText ?? ""]
                    .joined(separator: " ")
                    .lowercased()
                if !haystack.contains(query) { continue }
            }
            filtered.append((entry, p))
        }
        entries = filtered.map { $0.0 }
        parsed = filtered.map { $0.1 }
        tableView.reloadData()
    }

    @objc private func filterChanged() {
        switch filterControl.selectedSegment {
        case 1: activeFilter = .transcript
        case 2: activeFilter = .recap
        case 3: activeFilter = .podcast
        case 4: activeFilter = .permission
        default: activeFilter = nil
        }
        applyFilter()
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField, field === searchField else { return }
        searchQuery = field.stringValue
        applyFilter()
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
        let targetID = entries[row].id
        if let storageIndex = allEntries.firstIndex(where: { $0.id == targetID }) {
            TranscriptionHistory.shared.deleteEntry(at: storageIndex)
        }
        loadEntries()
    }

    @objc private func copyButtonClicked(_ sender: NSButton) {
        copyTextForRow(sender.tag)
    }

    @objc private func saveAudioButtonClicked(_ sender: NSButton) {
        saveAudioForRow(sender.tag)
    }

    @objc private func copySpokenButtonClicked(_ sender: NSButton) {
        copySpokenForRow(sender.tag)
    }

    private func copySpokenForRow(_ row: Int) {
        guard row >= 0, row < entries.count,
              let spoken = entries[row].spokenText else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(spoken, forType: .string)
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

    private let kRowLeadingInset: CGFloat = 12
    private let kRowTrailingInset: CGFloat = 10
    private let kRowTopInset: CGFloat = 6
    private let kRowBottomInset: CGFloat = 6
    private let kButtonColumnWidth: CGFloat = 170
    private let kTimeColumnWidth: CGFloat = 108

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let entry = entries[row]
        let p = parsed[row]
        let isCopied = copiedRow == row
        let isPodcast = entry.kind == .podcast
        let isRecap = entry.kind == .recap

        let cellView = NSView()

        // --- Header row: time + kind badge + (optional) podcast title ---
        let timeLabel = NSTextField(labelWithString: formatDate(entry.timestamp))
        timeLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(timeLabel)

        let badgeText: String
        let badgeColor: NSColor
        if isPodcast {
            badgeText = "Podcast"
            badgeColor = .systemPurple
        } else if isRecap {
            badgeText = "Claude Recap"
            badgeColor = .systemOrange
        } else if entry.kind == .permission {
            badgeText = "Tool Approval — \(entry.title ?? "?")"
            badgeColor = .systemYellow
        } else {
            badgeText = "Transcript"
            badgeColor = .systemTeal
        }
        let badge = NSTextField(labelWithString: badgeText)
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = badgeColor
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
        } else if isRecap, entry.spokenText != nil {
            let spokenButton = NSButton(title: "Copy Spoken", target: self, action: #selector(copySpokenButtonClicked(_:)))
            spokenButton.bezelStyle = .rounded
            spokenButton.controlSize = .small
            spokenButton.tag = row
            spokenButton.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(spokenButton)

            NSLayoutConstraint.activate([
                spokenButton.topAnchor.constraint(equalTo: cellView.topAnchor, constant: kRowTopInset),
                spokenButton.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -kRowTrailingInset),
                spokenButton.widthAnchor.constraint(equalToConstant: 100),
                copyButton.topAnchor.constraint(equalTo: cellView.topAnchor, constant: kRowTopInset),
                copyButton.trailingAnchor.constraint(equalTo: spokenButton.leadingAnchor, constant: -6),
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
        previewLabel.font = .systemFont(ofSize: 14)
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

        // Preview: always reserve 2 lines of space so short and long entries
        // render at a consistent height (longer ones tail-truncate).
        _ = isPodcast ? cleanedPodcastPreview(text: entry.text) : p.answer
        let lineHeight: CGFloat = 18
        let previewHeight = lineHeight * CGFloat(kPreviewLineLimit) + 2
        total += previewHeight

        return total
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
