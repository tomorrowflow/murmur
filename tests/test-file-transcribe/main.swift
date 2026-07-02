// TestFileTranscribe — standalone end-to-end test for the shared
// TranscriptionPipeline (Phase B2), using Parakeet as the engine.
//
//   swift run TestFileTranscribe <audioFile> [audioFile2]
//
// One file → plain timestamped transcript. Two files → treated as mic + app
// tracks and merged with Me/Them speaker labels. Prints the merged transcript
// and writes a session directory (metadata.json + transcript.md) to a temp dir.
//
// Generate a quick speech file to test with, e.g.:
//   say -o /tmp/hello.aiff "Hello, this is a test of the transcription pipeline."
//   swift run TestFileTranscribe /tmp/hello.aiff

import Foundation
import SharedModels

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: TestFileTranscribe <audioFile> [audioFile2]")
    exit(2)
}

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

        // Build the metadata. Point tracks at the absolute input paths (the
        // pipeline honors absolute paths without copying).
        var tracks: [CallSessionMetadata.Track] = []
        if inputPaths.count >= 2 {
            tracks = [
                .init(role: "mic", file: inputPaths[0].path),
                .init(role: "app-output", file: inputPaths[1].path)
            ]
        } else {
            tracks = [.init(role: "audio", file: inputPaths[0].path)]
        }

        let id = "test-\(Int(Date().timeIntervalSince1970))"
        let sessionDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TestFileTranscribe-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let metadata = CallSessionMetadata(
            id: id,
            source: "file",
            startedAt: ISO8601DateFormatter().string(from: Date()),
            tracks: tracks
        )

        let pipeline = TranscriptionPipeline(transcribe: transcribe)
        print("⏳ Transcribing \(tracks.count) track(s)…")
        let result = try await pipeline.run(
            sessionDir: sessionDir,
            metadata: metadata,
            engine: "parakeet"
        ) { print("   • \($0)") }

        print("\n===== transcript.md =====")
        print(result.transcriptMarkdown)
        print("=========================\n")
        print("📁 Session dir: \(result.sessionDir.path)")
        print("📄 metadata.json:")
        if let data = try? Data(contentsOf: result.metadataURL),
           let s = String(data: data, encoding: .utf8) {
            print(s)
        }

        // Assert we produced a non-empty transcript body.
        let body = result.transcriptMarkdown
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("#") && !$0.hasPrefix("- ") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if body.isEmpty || result.transcriptMarkdown.contains("_(no speech detected)_") {
            print("❌ FAIL: no speech transcribed. Was the audio actually speech?")
            exitCode = 1
        } else {
            print("✅ PASS: transcript produced (\(body.count) content line(s)).")
        }
    } catch {
        print("❌ Error: \(error.localizedDescription)")
        exitCode = 1
    }
}

sem.wait()
exit(exitCode)
