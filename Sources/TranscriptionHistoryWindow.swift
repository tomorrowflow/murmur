import Cocoa

class TranscriptionHistoryWindow: NSWindowController {
    private var historyViewController: TranscriptionHistoryViewController?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "History"
        window.minSize = NSSize(width: 520, height: 360)

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
