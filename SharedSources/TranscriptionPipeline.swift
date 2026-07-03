import Foundation
import AVFoundation

// MARK: - Engine serialization

/// Serializes access to the shared STT model instances (Parakeet/WhisperKit),
/// which make no reentrancy guarantees. Every engine `transcribe(...)` call —
/// interactive PTT/OpenClaw and background call transcription alike — runs
/// through `run`, so a background call transcription and a live dictation never
/// touch the same model concurrently. Interactive callers wait at most one
/// in-flight segment (~30s cap) behind a call transcription.
///
/// The critical section is the CHAIN, not the actor: a plain
/// `actor { await op() }` does NOT serialize, because Swift actors are
/// reentrant — awaiting inside the actor releases its executor and lets the
/// next `run` execute its op concurrently. Instead each call links its op to
/// the tail of a Task chain and awaits its predecessor, so ops run strictly
/// one at a time in enqueue order. Reading `tail` and installing the new tail
/// happen synchronously inside the actor (no await between), so ordering is
/// race-free. Errors propagate to the caller but never break the chain — the
/// tail Task swallows them so the next op's `await predecessor` can't throw.
public actor TranscriptionEngineGate {
    public static let shared = TranscriptionEngineGate()
    public init() {}

    private var tail: Task<Void, Never>?

    public func run<T: Sendable>(_ op: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            await previous?.value
            return try await op()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}

// MARK: - Metadata contract (metadata.json sidecar)

/// The generic ingestion contract written per session as `metadata.json`.
/// Shared between the capture stage (which writes the pre-transcription
/// skeleton) and the transcription pipeline (which fills in engine/transcript/
/// durations). Consumers (blackmirror, etc.) poll or watch this file.
public struct CallSessionMetadata: Codable {
    public struct Track: Codable {
        public var role: String        // "mic" | "app-output" | "audio"
        public var file: String
        public var error: String?
        public init(role: String, file: String, error: String? = nil) {
            self.role = role; self.file = file; self.error = error
        }
    }
    public struct WorkflowOutput: Codable {
        public var workflow: String
        public var file: String
        public init(workflow: String, file: String) {
            self.workflow = workflow; self.file = file
        }
    }
    public struct Anchor: Codable {
        public var appOffsetSeconds: Double
        public var micOffsetSeconds: Double
        public init(appOffsetSeconds: Double, micOffsetSeconds: Double) {
            self.appOffsetSeconds = appOffsetSeconds
            self.micOffsetSeconds = micOffsetSeconds
        }
    }

    public var id: String
    public var source: String              // "live-capture" | "file"
    public var app: String?
    public var startedAt: String?          // ISO8601
    public var endedAt: String?
    public var durationSeconds: Int?
    public var tracks: [Track]
    public var engine: String?
    public var transcript: String?         // filename, e.g. "transcript.md"
    public var workflowOutputs: [WorkflowOutput]
    public var anchor: Anchor?
    public var error: String?              // top-level pipeline error

    public init(
        id: String,
        source: String,
        app: String? = nil,
        startedAt: String? = nil,
        endedAt: String? = nil,
        durationSeconds: Int? = nil,
        tracks: [Track] = [],
        engine: String? = nil,
        transcript: String? = nil,
        workflowOutputs: [WorkflowOutput] = [],
        anchor: Anchor? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.source = source
        self.app = app
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.tracks = tracks
        self.engine = engine
        self.transcript = transcript
        self.workflowOutputs = workflowOutputs
        self.anchor = anchor
        self.error = error
    }

    // Stable, human-friendly JSON on disk.
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> CallSessionMetadata {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CallSessionMetadata.self, from: data)
    }
}

// MARK: - Pipeline inputs / outputs

/// One audio track to transcribe, with the offset (seconds) of its first
/// sample from the session's shared start anchor. `offsetSeconds` aligns
/// multi-track timestamps; it is 0 for single-file / file-input sessions.
public struct TranscriptionTrackInput {
    public let url: URL
    public let role: String        // "mic" | "app-output" | "audio"
    public let offsetSeconds: Double
    public init(url: URL, role: String, offsetSeconds: Double = 0) {
        self.url = url; self.role = role; self.offsetSeconds = offsetSeconds
    }
}

/// A transcribed span, timestamped in absolute session time (offset applied).
public struct TranscriptSegment {
    public let startSeconds: Double
    public let endSeconds: Double
    public let role: String
    public let text: String
}

public struct TranscriptionResult {
    public let sessionDir: URL
    public let transcriptURL: URL
    public let metadataURL: URL
    public let metadata: CallSessionMetadata
    public let transcriptMarkdown: String
}

/// Transcribes one chunk of 16 kHz mono Float samples to text. Injected by the
/// caller so the pipeline stays engine-agnostic (the app routes it through
/// ModelStateManager; tests wire it to a SharedModels engine directly).
public typealias SegmentTranscribe = (_ samples: [Float]) async throws -> String

public enum TranscriptionPipelineError: LocalizedError {
    case audioLoadFailed(String)
    case noReadableTracks

    public var errorDescription: String? {
        switch self {
        case .audioLoadFailed(let detail): return "Could not load audio: \(detail)"
        case .noReadableTracks: return "No readable audio tracks in the session."
        }
    }
}

// MARK: - Pipeline

/// File-based, source-agnostic transcription: load → mono 16 kHz → energy-based
/// segmentation (skipping long silences, capped at ~30 s at silence boundaries)
/// → per-segment transcription via the injected engine → timestamped merge into
/// a markdown transcript, with the metadata.json sidecar updated in place.
public final class TranscriptionPipeline {

    public let sampleRate: Double
    public let maxSegmentSeconds: Double
    public let minSilenceToSplitSeconds: Double
    public let bridgeGapSeconds: Double
    public let minSegmentSeconds: Double
    public let contextPadSeconds: Double

    /// Injected engine. Set before calling `run`.
    public var transcribe: SegmentTranscribe

    public init(
        transcribe: @escaping SegmentTranscribe,
        sampleRate: Double = 16000,
        maxSegmentSeconds: Double = 30,
        minSilenceToSplitSeconds: Double = 0.6,
        bridgeGapSeconds: Double = 0.35,
        minSegmentSeconds: Double = 0.15,
        contextPadSeconds: Double = 0.15
    ) {
        self.transcribe = transcribe
        self.sampleRate = sampleRate
        self.maxSegmentSeconds = maxSegmentSeconds
        self.minSilenceToSplitSeconds = minSilenceToSplitSeconds
        self.bridgeGapSeconds = bridgeGapSeconds
        self.minSegmentSeconds = minSegmentSeconds
        self.contextPadSeconds = contextPadSeconds
    }

    // MARK: Run

    /// Transcribe every track in `metadata`, write transcript.md into
    /// `sessionDir`, update and persist metadata.json, and return the result.
    /// Never throws for a single bad track (records a per-track error and keeps
    /// going); throws only if no track could be read at all.
    @discardableResult
    public func run(
        sessionDir: URL,
        metadata metadataIn: CallSessionMetadata,
        engine: String,
        progress: ((String) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        var metadata = metadataIn
        metadata.engine = engine

        // Resolve track offsets from the anchor (by role) if present.
        func offset(forRole role: String) -> Double {
            guard let anchor = metadata.anchor else { return 0 }
            switch role {
            case "mic": return anchor.micOffsetSeconds
            case "app-output", "app": return anchor.appOffsetSeconds
            default: return 0
            }
        }

        var allSegments: [TranscriptSegment] = []
        var readableTracks = 0
        var maxTrackEnd = 0.0

        for i in metadata.tracks.indices {
            let track = metadata.tracks[i]
            // `file` is normally a filename relative to the session dir; an
            // absolute path (used by file-input callers that don't copy) is
            // honored as-is.
            let url = track.file.hasPrefix("/")
                ? URL(fileURLWithPath: track.file)
                : sessionDir.appendingPathComponent(track.file)
            progress?("Loading \(track.file)…")

            let samples: [Float]
            do {
                samples = try Self.loadMono16k(url: url, targetSampleRate: sampleRate)
            } catch {
                metadata.tracks[i].error = "load failed: \(error.localizedDescription)"
                progress?("\(track.file): load failed — \(error.localizedDescription)")
                continue
            }
            readableTracks += 1

            let regions = segmentRegions(samples: samples)
            progress?("\(track.file): \(regions.count) segment(s)")

            let trackOffset = offset(forRole: track.role)
            for (idx, region) in regions.enumerated() {
                let slice = Array(samples[region.start..<region.end])
                let startSec = trackOffset + Double(region.start) / sampleRate
                let endSec = trackOffset + Double(region.end) / sampleRate
                maxTrackEnd = max(maxTrackEnd, endSec)
                do {
                    let text = try await transcribe(slice)
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        allSegments.append(TranscriptSegment(
                            startSeconds: startSec, endSeconds: endSec,
                            role: track.role, text: trimmed
                        ))
                    }
                    progress?("\(track.file): segment \(idx + 1)/\(regions.count) done")
                } catch {
                    // A single failed segment shouldn't sink the track.
                    progress?("\(track.file): segment \(idx + 1) failed: \(error.localizedDescription)")
                }
            }
        }

        guard readableTracks > 0 else {
            throw TranscriptionPipelineError.noReadableTracks
        }

        // Duration: prefer start/end wall-clock; else the longest track end.
        if metadata.durationSeconds == nil {
            metadata.durationSeconds = Int(maxTrackEnd.rounded())
        }

        // Two-speaker format only when more than one speaker role actually
        // produced speech (a failed/silent app track shouldn't force Me/Them).
        let speakerRoles = Set(allSegments.map(\.role)).intersection(["mic", "app-output", "app"])
        let isMultiTrack = speakerRoles.count > 1
        let markdown = Self.renderMarkdown(
            segments: allSegments,
            metadata: metadata,
            multiTrack: isMultiTrack
        )

        let transcriptURL = sessionDir.appendingPathComponent("transcript.md")
        try markdown.data(using: .utf8)?.write(to: transcriptURL, options: .atomic)
        metadata.transcript = "transcript.md"

        let metadataURL = sessionDir.appendingPathComponent("metadata.json")
        try metadata.write(to: metadataURL)

        return TranscriptionResult(
            sessionDir: sessionDir,
            transcriptURL: transcriptURL,
            metadataURL: metadataURL,
            metadata: metadata,
            transcriptMarkdown: markdown
        )
    }

    // MARK: Audio loading

    /// Decode any AVFoundation-readable file (wav/m4a/mp3/…) to mono Float
    /// samples at `targetSampleRate`. Conversion is chunked, but the full
    /// decoded track is accumulated into the returned array — peak memory is
    /// roughly one track's samples (~230 MB for a 1-hour 16 kHz mono track),
    /// and only one track is held at a time by the caller.
    public static func loadMono16k(url: URL, targetSampleRate: Double = 16000) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw TranscriptionPipelineError.audioLoadFailed(error.localizedDescription)
        }
        let inFormat = file.processingFormat
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw TranscriptionPipelineError.audioLoadFailed("unsupported format \(inFormat)")
        }

        // Pull-based conversion: the converter calls the input block whenever it
        // needs more source data, and we hand it the next file chunk. The outer
        // loop drains output until end-of-stream. This is the pattern that
        // handles sample-rate conversion correctly.
        let inChunkFrames: AVAudioFrameCount = 16384
        let outChunkFrames: AVAudioFrameCount = 16384
        var out: [Float] = []
        var readError: Error?

        loop: while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outChunkFrames) else { break }
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, inStatus in
                guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inChunkFrames) else {
                    inStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inBuf)
                } catch {
                    // AVAudioFile.read throws (rather than returning 0 frames)
                    // once the last frame has been consumed — that's normal EOF.
                    // But a throw with frames still unread is a genuine I/O error
                    // (e.g. corrupt-after-header); record it so we surface an
                    // error instead of silently truncating to "(no speech)".
                    if file.framePosition < file.length {
                        readError = error
                    }
                    inStatus.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 {
                    inStatus.pointee = .endOfStream
                    return nil
                }
                inStatus.pointee = .haveData
                return inBuf
            }

            if outBuf.frameLength > 0, let ch = outBuf.floatChannelData {
                out.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
            }

            if let readError {
                throw TranscriptionPipelineError.audioLoadFailed(readError.localizedDescription)
            }

            switch status {
            case .haveData:
                continue
            case .inputRanDry:
                // The block only ever returns .haveData or .endOfStream, so this
                // shouldn't recur; break if it yields nothing to avoid spinning.
                if outBuf.frameLength == 0 { break loop } else { continue }
            case .endOfStream:
                break loop
            case .error:
                throw TranscriptionPipelineError.audioLoadFailed(convError?.localizedDescription ?? "conversion error")
            @unknown default:
                break loop
            }
        }
        return out
    }

    // MARK: Segmentation

    private struct Region { let start: Int; let end: Int }

    /// Energy-based segmentation. Detects speech frames against a peak-relative
    /// threshold (adapts to per-track level — a call's app track is silent when
    /// the far end isn't talking), bridges short internal gaps so sentences stay
    /// whole, drops sub-`minSegment` blips, pads each region with
    /// `contextPadSeconds` of surrounding audio (so a short single-word burst
    /// keeps its onset/tail rather than being clipped to unintelligibility),
    /// merges regions that overlap once padded, and caps each segment at
    /// `maxSegment` by splitting at the quietest nearby frame.
    private func segmentRegions(samples: [Float]) -> [Region] {
        let frameLen = Int(0.03 * sampleRate)       // 30 ms
        guard frameLen > 0, samples.count >= frameLen else {
            return samples.isEmpty ? [] : [Region(start: 0, end: samples.count)]
        }

        let frameCount = samples.count / frameLen
        var rms = [Float](repeating: 0, count: frameCount)
        var peak: Float = 0
        for f in 0..<frameCount {
            let base = f * frameLen
            var sum: Float = 0
            for i in base..<(base + frameLen) { sum += samples[i] * samples[i] }
            let r = (sum / Float(frameLen)).squareRoot()
            rms[f] = r
            peak = max(peak, r)
        }

        let threshold = max(peak * 0.05, 0.003)
        let bridgeFrames = max(1, Int(bridgeGapSeconds * sampleRate) / frameLen)
        let minFrames = max(1, Int(minSegmentSeconds * sampleRate) / frameLen)

        // Build speech regions, bridging short silences.
        var regions: [Region] = []
        var f = 0
        while f < frameCount {
            guard rms[f] > threshold else { f += 1; continue }
            let startFrame = f
            var lastSpeech = f
            var g = f + 1
            while g < frameCount {
                if rms[g] > threshold {
                    lastSpeech = g
                    g += 1
                } else {
                    // count silence run
                    var s = g
                    while s < frameCount && rms[s] <= threshold { s += 1 }
                    if (s - g) >= bridgeFrames || s >= frameCount {
                        break   // real gap → close region at lastSpeech
                    } else {
                        g = s   // short gap → bridge
                    }
                }
            }
            if (lastSpeech - startFrame + 1) >= minFrames {
                let startSample = startFrame * frameLen
                let endSample = min(samples.count, (lastSpeech + 1) * frameLen)
                regions.append(Region(start: startSample, end: endSample))
            }
            f = max(lastSpeech + 1, g)
        }

        // Pad each region with context on both sides (clamped to the track) and
        // merge any that now overlap or touch. Short bursts otherwise get cut
        // flush against their first/last loud frame, which strips the quiet
        // onset/tail the recognizer needs to resolve the word.
        let padSamples = Int(contextPadSeconds * sampleRate)
        var padded: [Region] = []
        for region in regions {
            let start = max(0, region.start - padSamples)
            let end = min(samples.count, region.end + padSamples)
            if let last = padded.last, start <= last.end {
                padded[padded.count - 1] = Region(start: last.start, end: max(last.end, end))
            } else {
                padded.append(Region(start: start, end: end))
            }
        }

        // Cap long regions at silence points near the max length.
        let maxSamples = Int(maxSegmentSeconds * sampleRate)
        var capped: [Region] = []
        for region in padded {
            var start = region.start
            while region.end - start > maxSamples {
                let hardCut = start + maxSamples
                let cut = quietestCut(samples: samples, from: hardCut - Int(2 * sampleRate), to: hardCut, frameLen: frameLen) ?? hardCut
                capped.append(Region(start: start, end: cut))
                start = cut
            }
            if region.end > start {
                capped.append(Region(start: start, end: region.end))
            }
        }
        return capped
    }

    /// Sample index of the lowest-energy frame within [from, to], for a natural
    /// split point when a segment must be force-cut at the length cap.
    private func quietestCut(samples: [Float], from: Int, to: Int, frameLen: Int) -> Int? {
        let lo = max(0, from)
        let hi = min(samples.count, to)
        guard hi - lo >= frameLen else { return nil }
        var bestIdx = lo
        var bestRms = Float.greatestFiniteMagnitude
        var base = lo
        while base + frameLen <= hi {
            var sum: Float = 0
            for i in base..<(base + frameLen) { sum += samples[i] * samples[i] }
            let r = sum / Float(frameLen)
            if r < bestRms { bestRms = r; bestIdx = base + frameLen / 2 }
            base += frameLen
        }
        return bestIdx
    }

    // MARK: Markdown rendering

    static func renderMarkdown(
        segments: [TranscriptSegment],
        metadata: CallSessionMetadata,
        multiTrack: Bool
    ) -> String {
        var lines: [String] = []
        lines.append("# Call Transcript")
        lines.append("")
        if let app = metadata.app { lines.append("- App: \(app)") }
        if let started = metadata.startedAt { lines.append("- Date: \(started)") }
        if let dur = metadata.durationSeconds { lines.append("- Duration: \(formatTimestamp(Double(dur)))") }
        lines.append("- Source: \(metadata.source)")
        lines.append("")

        // Stable sort by start time (Swift's sort isn't stable, so tie-break on
        // original index to keep equal-timestamp turns deterministic).
        let sorted = segments.enumerated()
            .sorted { ($0.element.startSeconds, $0.offset) < ($1.element.startSeconds, $1.offset) }
            .map { $0.element }

        if sorted.isEmpty {
            lines.append("_(no speech detected)_")
            return lines.joined(separator: "\n") + "\n"
        }

        if multiTrack {
            // Group consecutive same-speaker segments into conversational turns.
            var i = 0
            while i < sorted.count {
                let role = sorted[i].role
                let turnStart = sorted[i].startSeconds
                var texts: [String] = []
                var j = i
                while j < sorted.count && sorted[j].role == role {
                    texts.append(sorted[j].text)
                    j += 1
                }
                let speaker = label(forRole: role)
                lines.append("**\(speaker) [\(formatTimestamp(turnStart))]:** \(texts.joined(separator: " "))")
                lines.append("")
                i = j
            }
        } else {
            for seg in sorted {
                lines.append("[\(formatTimestamp(seg.startSeconds))] \(seg.text)")
                lines.append("")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    static func label(forRole role: String) -> String {
        switch role {
        case "mic": return "Me"
        case "app-output", "app": return "Them"
        default: return "Speaker"
        }
    }

    static func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
