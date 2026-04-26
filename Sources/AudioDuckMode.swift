import Foundation

/// User-selectable behavior for "ducking" other audio sources during STT and
/// TTS. Persisted under UserDefaults key `audio.duckMode`. Migrates the old
/// `audio.voiceProcessing` Bool transparently on first read.
enum AudioDuckMode: String {
    /// No ducking, no media pausing. Murmur shares the audio stage as-is.
    case off
    /// Master output volume drops while STT is recording (mic-bleed defence).
    /// TTS playback is left alone.
    case recording
    /// Recording behavior plus: while TTS is playing, pause whatever app
    /// currently owns macOS "Now Playing" (Spotify, Music, Podcasts, etc.)
    /// and resume it when playback ends.
    case recordingAndPlayback

    static let userDefaultsKey = "audio.duckMode"
    private static let legacyKey = "audio.voiceProcessing"

    static var current: AudioDuckMode {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: userDefaultsKey),
           let mode = AudioDuckMode(rawValue: raw) {
            return mode
        }
        // Migrate legacy Bool.
        if defaults.object(forKey: legacyKey) != nil {
            let legacy = defaults.bool(forKey: legacyKey)
            let mode: AudioDuckMode = legacy ? .recording : .off
            defaults.set(mode.rawValue, forKey: userDefaultsKey)
            return mode
        }
        return .recording
    }

    var ducksRecording: Bool {
        self == .recording || self == .recordingAndPlayback
    }

    var pausesMediaDuringPlayback: Bool {
        self == .recordingAndPlayback
    }
}
