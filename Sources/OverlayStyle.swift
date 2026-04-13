import Cocoa
import SwiftUI

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
