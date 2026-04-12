import Foundation
import Combine

/// Shared singleton that receives raw dB values from any recording manager
/// and exposes normalized audio levels + rolling history for waveform visualization.
class AudioLevelMonitor: ObservableObject {
    static let shared = AudioLevelMonitor()

    /// Current smoothed level (0.0...1.0)
    @Published var currentLevel: CGFloat = 0

    /// Rolling buffer of recent levels for waveform drawing
    @Published var levelHistory: [CGFloat] = []

    private let historySize = 40
    private let smoothingFactor: CGFloat = 0.3
    private let minDb: Float = -60
    private let maxDb: Float = 0

    /// Throttle: minimum interval between published updates
    private let updateInterval: TimeInterval = 1.0 / 20.0 // 20 Hz
    private var lastUpdateTime: TimeInterval = 0

    private init() {
        levelHistory = Array(repeating: 0, count: historySize)
    }

    /// Called from recording delegate callbacks with raw dB value (typically -60...0).
    func update(db: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastUpdateTime >= updateInterval else { return }
        lastUpdateTime = now

        let normalized = CGFloat((db - minDb) / (maxDb - minDb)).clamped(to: 0...1)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Exponential moving average for smoothing
            self.currentLevel = self.currentLevel * (1 - self.smoothingFactor) + normalized * self.smoothingFactor

            // Append to ring buffer
            self.levelHistory.append(self.currentLevel)
            if self.levelHistory.count > self.historySize {
                self.levelHistory.removeFirst(self.levelHistory.count - self.historySize)
            }
        }
    }

    /// Reset levels when recording stops.
    func reset() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentLevel = 0
            self.levelHistory = Array(repeating: 0, count: self.historySize)
        }
    }
}

// MARK: - CGFloat Clamping

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
