// TestFileTranscribe — standalone end-to-end test for the shared
// TranscriptionPipeline (Phase B2), using Parakeet as the engine.
//
//   swift run TestFileTranscribe                 # built-in self-test
//   swift run TestFileTranscribe <audioFile> [audioFile2]
//
// With no arguments it runs a built-in self-test with two fixtures it
// synthesizes via `say`:
//   1. Long-sentence control — the original happy path; must still transcribe.
//   2. Short-utterance fixture — a single word padded with ~1s of silence on
//      both sides. This is the regression guard for the segmentation bug where
//      sub-0.4s speech bursts were discarded ("(no speech detected)"); it must
//      now yield >=1 segment and a non-empty transcript.
//
// With one file arg → plain timestamped transcript. Two files → treated as
// mic + app tracks and merged with Me/Them speaker labels. Prints the merged
// transcript and writes a session directory (metadata.json + transcript.md)
// to a temp dir. Use the file-arg mode to run against a real capture, e.g.:
//   swift run TestFileTranscribe "~/Music/Murmur Calls/…/mic.wav"

import Foundation
import AVFoundation
import SharedModels

// MARK: - Fixture synthesis helpers

/// Render `text` to speech via `/usr/bin/say`, returning the output file URL.
func synthesizeSpeech(_ text: String, to url: URL) throws {
    try? FileManager.default.removeItem(at: url)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    proc.arguments = ["-o", url.path, text]
    try proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
        throw NSError(domain: "TestFileTranscribe", code: 10,
                      userInfo: [NSLocalizedDescriptionKey: "`say` failed to render \"\(text)\""])
    }
}

/// Write mono 16 kHz Float samples to a WAV file.
func writeWav(_ samples: [Float], to url: URL, sampleRate: Double = 16000) throws {
    try? FileManager.default.removeItem(at: url)
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: sampleRate, channels: 1, interleaved: false) else {
        throw NSError(domain: "TestFileTranscribe", code: 11,
                      userInfo: [NSLocalizedDescriptionKey: "could not build output format"])
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    let frames = AVAudioFrameCount(samples.count)
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
        throw NSError(domain: "TestFileTranscribe", code: 12,
                      userInfo: [NSLocalizedDescriptionKey: "empty sample buffer"])
    }
    buffer.frameLength = frames
    samples.withUnsafeBufferPointer { src in
        buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
    }
    try file.write(from: buffer)
}

/// Render `word` to speech, then wrap it in `padSeconds` of silence on each
/// side, writing a 16 kHz mono WAV. Reproduces the short-single-word-in-silence
/// shape that the segmenter previously discarded.
func makeShortUtteranceFixture(word: String, padSeconds: Double, to url: URL) throws {
    let speechURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tft-word-\(UUID().uuidString).aiff")
    try synthesizeSpeech(word, to: speechURL)
    defer { try? FileManager.default.removeItem(at: speechURL) }

    let speech = try TranscriptionPipeline.loadMono16k(url: speechURL)
    let pad = [Float](repeating: 0, count: Int(padSeconds * 16000))
    try writeWav(pad + speech + pad, to: url)
}

// MARK: - Pipeline runner

struct FixtureResult {
    let segmentCount: Int
    let contentLines: Int
    let markdown: String
    let sawNoSpeech: Bool
}

/// Run `paths` through the pipeline and report what came back. `segmentCount`
/// is summed from the pipeline's per-track progress ("N segment(s)").
/// `trackOffsets`, when given, sets each track's explicit offsetSeconds.
func runFixture(paths: [URL], trackOffsets: [Double?]? = nil,
                transcribe: @escaping SegmentTranscribe) async throws -> FixtureResult {
    func offsetAt(_ i: Int) -> Double? {
        guard let trackOffsets, i < trackOffsets.count else { return nil }
        return trackOffsets[i]
    }
    var tracks: [CallSessionMetadata.Track] = []
    if paths.count >= 2 {
        tracks = [.init(role: "mic", file: paths[0].path, offsetSeconds: offsetAt(0)),
                  .init(role: "app-output", file: paths[1].path, offsetSeconds: offsetAt(1))]
    } else {
        tracks = [.init(role: "audio", file: paths[0].path, offsetSeconds: offsetAt(0))]
    }

    let id = "test-\(Int(Date().timeIntervalSince1970 * 1000))"
    let sessionDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("TestFileTranscribe-\(id)", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

    let metadata = CallSessionMetadata(
        id: id,
        source: "file",
        startedAt: ISO8601DateFormatter().string(from: Date()),
        tracks: tracks
    )

    var segmentCount = 0
    let pipeline = TranscriptionPipeline(transcribe: transcribe)
    let result = try await pipeline.run(sessionDir: sessionDir, metadata: metadata, engine: "parakeet") { line in
        print("   • \(line)")
        // Progress reports "<file>: <N> segment(s)" once per track.
        if let range = line.range(of: " segment(s)") {
            let head = line[..<range.lowerBound]
            if let n = head.split(separator: " ").last.flatMap({ Int($0) }) {
                segmentCount += n
            }
        }
    }

    let body = result.transcriptMarkdown
        .components(separatedBy: "\n")
        .filter { !$0.hasPrefix("#") && !$0.hasPrefix("- ") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    return FixtureResult(
        segmentCount: segmentCount,
        contentLines: body.count,
        markdown: result.transcriptMarkdown,
        sawNoSpeech: result.transcriptMarkdown.contains("_(no speech detected)_")
    )
}

// MARK: - Main

let args = CommandLine.arguments
let inputPaths = Array(args.dropFirst()).map { URL(fileURLWithPath: $0) }
for p in inputPaths where !FileManager.default.isReadableFile(atPath: p.path) {
    print("❌ File not readable: \(p.path)")
    exit(2)
}

let sem = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

Task {
    defer { sem.signal() }
    do {
        // Load Parakeet (downloads on first use ~600MB). Prefer whichever
        // version is already cached to avoid a fresh download in CI/tests.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let v3Present = FileManager.default.fileExists(
            atPath: docs.appendingPathComponent("FluidAudio/parakeet-tdt-0.6b-v3").path)
        let version: ParakeetVersion = v3Present ? .v3 : .v2
        print("⏳ Loading Parakeet \(version.displayName) (downloads on first run)…")
        let transcriber = ParakeetTranscriber()
        try await transcriber.loadModel(version: version)
        guard transcriber.isReady else {
            print("❌ Parakeet model failed to load.")
            exitCode = 1
            return
        }
        print("✅ Model ready.")

        let transcribe: SegmentTranscribe = { samples in
            // Pad very short clips with 1s of silence for reliability.
            let padded = samples.count < Int(1.5 * 16000)
                ? samples + [Float](repeating: 0, count: 16000)
                : samples
            return try await transcriber.transcribe(audioSamples: padded)
        }

        if !inputPaths.isEmpty {
            // File-input mode (used for real captures): transcribe as-is, assert
            // a non-empty transcript.
            print("⏳ Transcribing \(inputPaths.count) provided track(s)…")
            let result = try await runFixture(paths: inputPaths, transcribe: transcribe)
            print("\n===== transcript.md =====")
            print(result.markdown)
            print("=========================")
            if result.contentLines == 0 || result.sawNoSpeech {
                print("❌ FAIL: no speech transcribed. Was the audio actually speech?")
                exitCode = 1
            } else {
                print("✅ PASS: transcript produced (\(result.segmentCount) segment(s), \(result.contentLines) content line(s)).")
            }
            return
        }

        // Built-in self-test: long-sentence control + short-utterance fixture.
        var failures: [String] = []

        // 1. Long-sentence control — the original happy path.
        let controlURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tft-control-\(UUID().uuidString).aiff")
        try synthesizeSpeech(
            "Hello, this is a test of the transcription pipeline with a full sentence of speech.",
            to: controlURL)
        defer { try? FileManager.default.removeItem(at: controlURL) }
        print("\n▶︎ Fixture 1: long-sentence control")
        let control = try await runFixture(paths: [controlURL], transcribe: transcribe)
        print("   → \(control.segmentCount) segment(s), \(control.contentLines) content line(s)")
        if control.segmentCount < 1 || control.contentLines == 0 || control.sawNoSpeech {
            failures.append("long-sentence control produced no transcript")
        }

        // 2. Short-utterance fixture — single word in ~1s of silence each side.
        let shortURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tft-short-\(UUID().uuidString).wav")
        try makeShortUtteranceFixture(word: "yes", padSeconds: 1.0, to: shortURL)
        defer { try? FileManager.default.removeItem(at: shortURL) }
        print("\n▶︎ Fixture 2: short-utterance (single word + 1s silence pad)")
        let short = try await runFixture(paths: [shortURL], transcribe: transcribe)
        print("   transcript: \(short.markdown.replacingOccurrences(of: "\n", with: " ⏎ "))")
        print("   → \(short.segmentCount) segment(s), \(short.contentLines) content line(s)")
        if short.segmentCount < 1 {
            failures.append("short-utterance fixture produced 0 segments (segmentation regression)")
        }
        if short.contentLines == 0 || short.sawNoSpeech {
            failures.append("short-utterance fixture produced an empty transcript")
        }

        // 3. Two-track per-track-offset fixture — the app track starts 5s into
        // the session, so the merged transcript must order mic (Me) before app
        // (Them) and stamp the app turn at ~00:05, not 00:00. This guards the
        // per-track offsetSeconds path that fixes far-end roll timeline drift.
        let micTrackURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tft-2t-mic-\(UUID().uuidString).aiff")
        let appTrackURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tft-2t-app-\(UUID().uuidString).aiff")
        try synthesizeSpeech("This is the first speaker on the microphone.", to: micTrackURL)
        try synthesizeSpeech("And this is the second speaker answering back.", to: appTrackURL)
        defer {
            try? FileManager.default.removeItem(at: micTrackURL)
            try? FileManager.default.removeItem(at: appTrackURL)
        }
        print("\n▶︎ Fixture 3: two-track with per-track offsets (app track offset 5.0s)")
        let twoTrack = try await runFixture(
            paths: [micTrackURL, appTrackURL],
            trackOffsets: [0.0, 5.0],
            transcribe: transcribe)
        print("   transcript: \(twoTrack.markdown.replacingOccurrences(of: "\n", with: " ⏎ "))")
        let meIdx = twoTrack.markdown.range(of: "**Me ")?.lowerBound
        let themIdx = twoTrack.markdown.range(of: "**Them ")?.lowerBound
        if meIdx == nil || themIdx == nil {
            failures.append("two-track fixture didn't produce both Me and Them turns")
        } else if meIdx! >= themIdx! {
            failures.append("two-track fixture ordered Them before Me (offset merge broken)")
        }
        // The Them turn header is "**Them [mm:ss]:**"; parse and check it reflects
        // the 5s offset rather than 00:00.
        if let r = twoTrack.markdown.range(of: "**Them ["),
           let close = twoTrack.markdown[r.upperBound...].firstIndex(of: "]") {
            let stamp = String(twoTrack.markdown[r.upperBound..<close])   // "mm:ss"
            let parts = stamp.split(separator: ":").compactMap { Int($0) }
            let seconds = parts.count == 2 ? parts[0] * 60 + parts[1] : -1
            print("   Them turn timestamp: \(stamp) (\(seconds)s)")
            if seconds < 4 {
                failures.append("two-track fixture: Them timestamp \(stamp) doesn't reflect the 5s offset")
            }
        } else {
            failures.append("two-track fixture: couldn't find a Them turn timestamp")
        }

        if failures.isEmpty {
            print("\n✅ PASS: all fixtures transcribed (control + short utterance + two-track offsets).")
        } else {
            print("\n❌ FAIL:")
            for f in failures { print("   • \(f)") }
            exitCode = 1
        }
    } catch {
        print("❌ Error: \(error.localizedDescription)")
        exitCode = 1
    }
}

sem.wait()
exit(exitCode)
