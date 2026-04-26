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

    /// True when the master output volume should drop during STT capture
    /// (mic-bleed defence). Only the `.recording` mode does this — the
    /// pause-mode replaces ducking with a clean pause of other media,
    /// so master volume stays where the user set it.
    var ducksRecording: Bool {
        self == .recording
    }

    /// True when other media apps should be paused during STT capture.
    /// Only `.recordingAndPlayback` does this.
    var pausesMediaDuringRecording: Bool {
        self == .recordingAndPlayback
    }

    /// True when other media apps should be paused during TTS playback.
    /// Only `.recordingAndPlayback` does this.
    var pausesMediaDuringPlayback: Bool {
        self == .recordingAndPlayback
    }
}
