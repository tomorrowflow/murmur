import Cocoa

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
        self.titleLabel = NSTextField(labelWithString: "Transcription History")

        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
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
        tableView.target = self
        tableView.action = #selector(tableRowClicked)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.title = ""
        tableView.addTableColumn(column)

        scrollView.documentView = tableView

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(contextCopy), keyEquivalent: "c"))
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
            titleLabel.stringValue = "No transcription history"
            clearButton.isEnabled = false
        } else {
            titleLabel.stringValue = "Transcription History (\(entries.count) entries)"
            clearButton.isEnabled = true
        }
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear History"
        alert.informativeText = "Are you sure you want to clear all transcription history?"
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

    @objc private func tableRowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < entries.count else { return }
        copyAnswerAtRow(row)
    }

    private func copyAnswerAtRow(_ row: Int) {
        let text = parsed[row].answer
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

    @objc private func contextCopy() {
        let row = tableView.clickedRow
        guard row >= 0, row < entries.count else { return }
        copyAnswerAtRow(row)
    }

    @objc private func contextDelete() {
        let row = tableView.clickedRow
        guard row >= 0, row < entries.count else { return }
        TranscriptionHistory.shared.deleteEntry(at: row)
        loadEntries()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return entries.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let entry = entries[row]
        let p = parsed[row]
        let isCopied = copiedRow == row

        let cellView = NSView()

        // Timestamp
        let timeLabel = NSTextField(labelWithString: formatDate(entry.timestamp))
        timeLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        cellView.addSubview(timeLabel)

        NSLayoutConstraint.activate([
            timeLabel.leadingAnchor.constraint(equalTo: cellView.leadingAnchor, constant: 8),
            timeLabel.topAnchor.constraint(equalTo: cellView.topAnchor, constant: 6),
        ])

        if let question = p.question {
            // Q&A entry: show question (dimmed) then answer below it
            let questionLabel = NSTextField(wrappingLabelWithString: question)
            questionLabel.font = .systemFont(ofSize: 12)
            questionLabel.textColor = .secondaryLabelColor
            questionLabel.maximumNumberOfLines = 0
            questionLabel.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(questionLabel)

            let answerLabel = NSTextField(wrappingLabelWithString: isCopied ? "Copied!" : p.answer)
            answerLabel.font = .systemFont(ofSize: 13)
            answerLabel.textColor = isCopied ? .systemGreen : .labelColor
            answerLabel.maximumNumberOfLines = 0
            answerLabel.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(answerLabel)

            NSLayoutConstraint.activate([
                questionLabel.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 12),
                questionLabel.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -8),
                questionLabel.topAnchor.constraint(equalTo: cellView.topAnchor, constant: 6),

                answerLabel.leadingAnchor.constraint(equalTo: questionLabel.leadingAnchor),
                answerLabel.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -8),
                answerLabel.topAnchor.constraint(equalTo: questionLabel.bottomAnchor, constant: 4),
                answerLabel.bottomAnchor.constraint(lessThanOrEqualTo: cellView.bottomAnchor, constant: -6)
            ])
        } else {
            // Plain transcription entry
            let textLabel = NSTextField(wrappingLabelWithString: isCopied ? "Copied!" : p.answer)
            textLabel.font = .systemFont(ofSize: 13)
            textLabel.textColor = isCopied ? .systemGreen : .labelColor
            textLabel.maximumNumberOfLines = 0
            textLabel.translatesAutoresizingMaskIntoConstraints = false
            cellView.addSubview(textLabel)

            NSLayoutConstraint.activate([
                textLabel.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 12),
                textLabel.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -8),
                textLabel.topAnchor.constraint(equalTo: cellView.topAnchor, constant: 6),
                textLabel.bottomAnchor.constraint(lessThanOrEqualTo: cellView.bottomAnchor, constant: -6)
            ])
        }

        return cellView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < entries.count else { return 30 }
        let p = parsed[row]
        let availableWidth = max(tableView.bounds.width - 150, 200)
        let textAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13)]

        if let question = p.question {
            let qAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
            let qSize = (question as NSString).boundingRect(
                with: NSSize(width: availableWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: qAttrs
            )
            let aSize = (p.answer as NSString).boundingRect(
                with: NSSize(width: availableWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: textAttrs
            )
            return max(40, qSize.height + aSize.height + 20) // 6 top + 4 gap + 6 bottom + 4 extra
        } else {
            let textSize = (p.answer as NSString).boundingRect(
                with: NSSize(width: availableWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: textAttrs
            )
            return max(30, textSize.height + 16)
        }
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
