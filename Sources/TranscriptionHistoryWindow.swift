import Cocoa

class TranscriptionHistoryWindow: NSWindowController {
    private var historyViewController: TranscriptionHistoryViewController?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Transcription History"
        window.minSize = NSSize(width: 400, height: 300)

        super.init(window: window)

        let vc = TranscriptionHistoryViewController()
        historyViewController = vc
        window.contentViewController = vc
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWindow() {
        historyViewController?.refreshHistory()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
