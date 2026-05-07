import Foundation

/// Drops known-bad transcriptions that Whisper / Parakeet emit on
/// near-silence or short zero-padded audio (e.g. "you", "Thanks for
/// watching", "True", "Quick"). Only applied when the source recording
/// was short enough that a real utterance is implausible.
enum STTHallucinationFilter {
    private static let knownHallucinations: Set<String> = [
        "",
        "you",
        "thank you", "thanks", "thanks for watching", "thank you for watching",
        "bye", "bye bye", "goodbye",
        "mm", "hmm", "uh", "um", "uhh", "umm", "ah", "oh",
        "okay", "ok",
        "true", "false",
        "quick",
        "yeah", "yep", "nope",
        "subtitles by the amara org community",
    ]

    /// Returns true if `text` looks like a model hallucination on a short
    /// recording. Only filters when `audioDurationSeconds < shortAudioThreshold`,
    /// so legitimate longer utterances of these words still pass.
    static func isLikelyHallucination(
        _ text: String,
        audioDurationSeconds: Double,
        shortAudioThreshold: Double = 1.5
    ) -> Bool {
        guard audioDurationSeconds < shortAudioThreshold else { return false }
        let normalized = normalize(text)
        return knownHallucinations.contains(normalized)
    }

    private static func normalize(_ text: String) -> String {
        let stripped = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .unicodeScalars
            .filter { !CharacterSet.punctuationCharacters.contains($0) }
        return String(String.UnicodeScalarView(stripped))
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
