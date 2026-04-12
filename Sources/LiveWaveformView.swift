import SwiftUI

/// Real-time audio waveform visualization driven by AudioLevelMonitor.
/// Renders the level history as animated vertical bars.
struct LiveWaveformView: View {
    @ObservedObject var monitor: AudioLevelMonitor
    var barCount: Int = 20
    var color: Color = .red
    var height: CGFloat = 30

    /// Minimum bar height as fraction of total height (always visible even in silence)
    private let minBarFraction: CGFloat = 0.15

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: barWidth, height: barHeight(for: index))
            }
        }
        .frame(height: height)
        .animation(.linear(duration: 0.05), value: monitor.levelHistory)
    }

    private var barSpacing: CGFloat {
        barCount > 16 ? 1.5 : 2.0
    }

    private var barWidth: CGFloat {
        barCount > 16 ? 2.0 : 3.0
    }

    private func barHeight(for index: Int) -> CGFloat {
        let history = monitor.levelHistory
        guard !history.isEmpty else { return height * minBarFraction }

        // Map bar index to history index
        let historyIndex = Int(Double(index) / Double(barCount) * Double(history.count))
        let clampedIndex = min(historyIndex, history.count - 1)
        let level = history[clampedIndex]

        let minHeight = height * minBarFraction
        return minHeight + level * (height - minHeight)
    }
}

/// Shared listening indicator used across all overlay windows.
/// Replaces the pulsing mic icon with a live waveform.
struct ListeningIndicatorView: View {
    var prompt: String = "Recording..."
    var elapsedTime: String? = nil
    @ObservedObject var monitor: AudioLevelMonitor

    var body: some View {
        HStack(spacing: 8) {
            LiveWaveformView(monitor: monitor, barCount: 16, color: .red, height: 20)
                .frame(width: 100, height: 20)
            Text(prompt)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            if let time = elapsedTime {
                Text(time)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.05))
    }
}
