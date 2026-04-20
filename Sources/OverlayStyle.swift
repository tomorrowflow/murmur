import Cocoa
import SwiftUI

// MARK: - Consistent top-anchored positioning

/// Distance between the top of the menu bar and the top of any floating
/// overlay panel. Keep this shared so every overlay (Podcast, Read Aloud,
/// STT, OpenClaw, Draft Editing) lands at the same Y regardless of its
/// current content height.
let kOverlayTopInset: CGFloat = 40

extension NSPanel {
    /// Center horizontally and pin the top edge `kOverlayTopInset` below the
    /// menu bar. Call after the panel's content view is set AND whenever the
    /// panel resizes (SwiftUI content changes cause NSHostingView to request a
    /// new intrinsic size, which NSPanel honours — but it keeps the bottom-left
    /// origin fixed, so the TOP edge drifts unless we re-anchor).
    func positionTopCentered(topInset: CGFloat = kOverlayTopInset) {
        guard let screen = self.screen ?? NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = (screenFrame.width - self.frame.width) / 2 + screenFrame.minX
        let y = screenFrame.maxY - self.frame.height - topInset
        self.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Observes the panel's resize events so the given reposition closure fires
/// every time SwiftUI content resizes the window. Returns the observer token
/// so callers can retain it (NotificationCenter holds a weak reference when
/// using the block API — keeping the token ensures the observer stays alive
/// for the lifetime of the overlay).
@discardableResult
func observePanelResize(_ panel: NSPanel, reposition: @escaping () -> Void) -> NSObjectProtocol {
    return NotificationCenter.default.addObserver(
        forName: NSWindow.didResizeNotification,
        object: panel,
        queue: .main
    ) { _ in
        reposition()
    }
}

// MARK: - Glass Panel Factory

/// Creates a modern translucent floating panel, replacing the old HUD window style.
/// Uses borderless + material background for a clean glass look.
func createGlassPanel(width: CGFloat, height: CGFloat) -> NSPanel {
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height),
        styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
        backing: .buffered,
        defer: false
    )

    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isMovableByWindowBackground = true
    panel.isReleasedWhenClosed = false

    return panel
}

// MARK: - Glass Background Modifier

/// Applies a modern translucent background with subtle border.
/// Uses .glassEffect() on macOS 26+, falls back to .ultraThinMaterial + gradient border.
struct GlassBackground: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            content
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.25), .white.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                )
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        }
    }
}

extension View {
    func glassBackground(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassBackground(cornerRadius: cornerRadius))
    }
}

// MARK: - State Badge

/// Compact, modern state badge without heavy colored backgrounds.
struct StateBadge: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.08))
        .cornerRadius(10)
    }
}

// MARK: - App Icon View

/// Displays an app icon from NSImage in SwiftUI.
struct AppIconView: View {
    let icon: NSImage?
    var size: CGFloat = 20

    var body: some View {
        if let icon = icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .cornerRadius(size * 0.22)  // macOS icon corner ratio
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: size * 0.7))
                .foregroundColor(.secondary)
                .frame(width: size, height: size)
        }
    }
}
