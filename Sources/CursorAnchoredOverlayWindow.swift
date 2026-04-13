import Cocoa
import SwiftUI

// MARK: - ViewModel

class CursorAnchoredOverlayViewModel: ObservableObject {
    @Published var isVisible: Bool = false
    @Published var formattedElapsedTime: String = "0s"

    private var elapsedTimer: Timer?
    private var startTime: Date?

    func startTimer() {
        startTime = Date()
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.startTime else { return }
            let elapsed = Int(Date().timeIntervalSince(start))
            if elapsed < 60 {
                self.formattedElapsedTime = "\(elapsed)s"
            } else {
                self.formattedElapsedTime = "\(elapsed / 60):\(String(format: "%02d", elapsed % 60))"
            }
        }
    }

    func stopTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        startTime = nil
        formattedElapsedTime = "0s"
    }
}

// MARK: - SwiftUI View

struct CursorAnchoredOverlayView: View {
    @ObservedObject var viewModel: CursorAnchoredOverlayViewModel

    var body: some View {
        HStack(spacing: 8) {
            LiveWaveformView(monitor: AudioLevelMonitor.shared, barCount: 12, color: .red, height: 18)
                .frame(width: 72, height: 18)
            Text(viewModel.formattedElapsedTime)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(.secondary)
            Spacer()
            Text("esc")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary.opacity(0.5))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 180, height: 36)
        .glassBackground(cornerRadius: 12)
    }
}

// MARK: - Overlay Window

class CursorAnchoredOverlayWindow {
    private var panel: NSPanel?
    let viewModel = CursorAnchoredOverlayViewModel()

    func show() {
        DispatchQueue.main.async { [self] in
            let wasVisible = viewModel.isVisible
            viewModel.isVisible = true
            ensurePanel()

            if !wasVisible {
                viewModel.startTimer()
                // Position once when first shown — don't reposition on every audio level update
                if let position = Self.getCursorScreenPosition() {
                    positionNearCursor(position)
                } else {
                    positionCenterBottom()
                }
            }
            panel?.orderFront(nil)
        }
    }

    func dismiss() {
        DispatchQueue.main.async { [self] in
            viewModel.isVisible = false
            viewModel.stopTimer()
            panel?.orderOut(nil)
        }
    }

    // MARK: - Cursor Position Detection

    /// Get the screen position of the text cursor in the focused app via Accessibility API.
    /// Returns the point just below the cursor, or nil if not available.
    static func getCursorScreenPosition() -> NSPoint? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else {
            return nil
        }
        let element = focusedElement as! AXUIElement

        // Try to get cursor bounds via text range
        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success else {
            return nil
        }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else {
            return nil
        }

        // Query bounds for a 1-char range at cursor position
        var queryRange = CFRange(location: range.location, length: max(range.length, 1))
        guard let queryRangeValue = AXValueCreate(.cfRange, &queryRange) else {
            return nil
        }

        var boundsValue: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            queryRangeValue,
            &boundsValue
        ) == .success else {
            return nil
        }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) else {
            return nil
        }

        // AX uses top-left origin; convert to bottom-left for NSPoint
        guard let screen = NSScreen.main else { return nil }
        let screenHeight = screen.frame.height
        let bottomY = screenHeight - rect.maxY - 8  // 8px below the cursor line
        return NSPoint(x: rect.midX, y: bottomY)
    }

    // MARK: - Positioning

    private func positionNearCursor(_ point: NSPoint) {
        guard let panel = panel, let screen = NSScreen.main else { return }
        let panelWidth = panel.frame.width
        let panelHeight = panel.frame.height
        let screenFrame = screen.visibleFrame

        // Center horizontally on cursor, but keep within screen bounds
        var x = point.x - panelWidth / 2
        x = max(screenFrame.minX + 4, min(x, screenFrame.maxX - panelWidth - 4))

        // Position below cursor
        var y = point.y - panelHeight
        // If it would go below screen, put it above the cursor instead
        if y < screenFrame.minY {
            y = point.y + panelHeight + 16
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func positionCenterBottom() {
        guard let panel = panel, let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = (screenFrame.width - panel.frame.width) / 2 + screenFrame.minX
        let y = screenFrame.minY + 80
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func ensurePanel() {
        if panel != nil { return }

        let hostingView = NSHostingView(rootView: CursorAnchoredOverlayView(viewModel: viewModel))

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 36),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false

        self.panel = panel
    }
}
