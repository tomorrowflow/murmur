import Foundation
import AppKit
import WhisperKit
import SharedModels

/// Drives the shared `TranscriptionPipeline` from the app: routes segment
/// transcription through the user's configured engine (reusing
/// ModelStateManager's model loading/state — the same path as PTT, without
/// touching the PTT flow), runs the pipeline off the main actor, and updates
/// metadata.json. One session at a time.
@MainActor
final class CallTranscriptionRunner {
    static let shared = CallTranscriptionRunner()

    private(set) var isBusy = false
    private(set) var currentSessionId: String?
    private var onComplete: (() -> Void)?

    static let callsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Music/Murmur Calls", isDirectory: true)

    private static let sampleRate = 16000.0

    // MARK: - Public API

    /// Transcribe an existing session directory (must contain metadata.json).
    /// `onComplete` fires on the main actor when this session finishes (used by
    /// the capture flow to update the overlay).
    @discardableResult
    func transcribeSession(directory: URL, onComplete: (() -> Void)? = nil) -> Bool {
        guard !isBusy else {
            NSLog("[Transcribe] Busy — ignoring request for \(directory.lastPathComponent)")
            return false
        }
        let metaURL = directory.appendingPathComponent("metadata.json")
        guard let meta = try? CallSessionMetadata.read(from: metaURL) else {
            NSLog("[Transcribe] No readable metadata.json in \(directory.path)")
            return false
        }
        startTranscription(sessionDir: directory, metadata: meta, onComplete: onComplete)
        return true
    }

    /// File-input mode: create a new session directory that references the
    /// provided audio file(s) by absolute path (2 files → mic/app roles, 1 file
    /// → single track — the pipeline reads absolute track paths, so nothing is
    /// copied and the main thread never blocks on large files), write the
    /// initial metadata.json, and kick off transcription. Returns the new
    /// session id + directory immediately (transcription runs async).
    func transcribeFiles(_ paths: [URL]) throws -> (id: String, dir: URL) {
        guard let first = paths.first else {
            throw NSError(domain: "CallTranscribe", code: 1, userInfo: [NSLocalizedDescriptionKey: "No files provided"])
        }
        for p in paths {
            guard FileManager.default.isReadableFile(atPath: p.path) else {
                throw NSError(domain: "CallTranscribe", code: 2, userInfo: [NSLocalizedDescriptionKey: "File not readable: \(p.path)"])
            }
        }

        let stamp = Self.folderStamp.string(from: Date())
        let slug = Self.sanitize(first.deletingPathExtension().lastPathComponent)
        let id = "\(stamp)-\(slug)"
        let dir = Self.callsDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Reference the source files by absolute path (no copy — avoids blocking
        // on multi-hundred-MB files). 2 files = mic + app roles; 1 = single track.
        var tracks: [CallSessionMetadata.Track] = []
        if paths.count >= 2 {
            tracks = [
                .init(role: "mic", file: paths[0].path),
                .init(role: "app-output", file: paths[1].path)
            ]
        } else {
            tracks = [.init(role: "audio", file: first.path)]
        }

        let meta = CallSessionMetadata(
            id: id,
            source: "file",
            startedAt: Self.iso8601.string(from: Date()),
            tracks: tracks
        )
        try meta.write(to: dir.appendingPathComponent("metadata.json"))

        startTranscription(sessionDir: dir, metadata: meta, onComplete: nil)
        return (id, dir)
    }

    // MARK: - Session listing (for HTTP)

    /// Summaries for GET /sessions, newest first.
    func listSessions() -> [[String: Any]] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: Self.callsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [[String: Any]] = []
        for dir in entries {
            let metaURL = dir.appendingPathComponent("metadata.json")
            guard let meta = try? CallSessionMetadata.read(from: metaURL) else { continue }
            out.append([
                "id": meta.id,
                "startedAt": meta.startedAt ?? "",
                "state": derivedState(for: meta)
            ])
        }
        out.sort { ($0["startedAt"] as? String ?? "") > ($1["startedAt"] as? String ?? "") }
        return out
    }

    /// Raw metadata.json bytes for GET /sessions/<id>, or nil if unknown.
    func metadataJSON(forSessionId id: String) -> Data? {
        // Session id is also the directory name.
        let dir = Self.callsDirectory.appendingPathComponent(id, isDirectory: true)
        let metaURL = dir.appendingPathComponent("metadata.json")
        return try? Data(contentsOf: metaURL)
    }

    private func derivedState(for meta: CallSessionMetadata) -> String {
        if isBusy, currentSessionId == meta.id { return "transcribing" }
        if meta.error != nil { return "error" }
        if meta.transcript != nil { return "transcribed" }
        return "captured"
    }

    // MARK: - Core

    private func startTranscription(sessionDir: URL, metadata: CallSessionMetadata, onComplete: (() -> Void)?) {
        isBusy = true
        currentSessionId = metadata.id
        self.onComplete = onComplete

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            guard let made = await self.makeTranscriber() else {
                var failed = metadata
                failed.error = "No transcription engine available. Select and download a model in Settings."
                Self.writeMetadata(failed, to: sessionDir)
                NSLog("[Transcribe] No engine available for \(metadata.id)")
                await self.finish()
                return
            }

            let pipeline = TranscriptionPipeline(transcribe: made.transcribe)
            do {
                let result = try await pipeline.run(
                    sessionDir: sessionDir,
                    metadata: metadata,
                    engine: made.engine
                ) { NSLog("[Transcribe] \($0)") }
                NSLog("[Transcribe] Completed \(result.metadata.id) → \(result.transcriptURL.path)")
            } catch {
                var failed = metadata
                failed.engine = made.engine
                failed.error = error.localizedDescription
                Self.writeMetadata(failed, to: sessionDir)
                NSLog("[Transcribe] Failed \(metadata.id): \(error.localizedDescription)")
            }
            await self.finish()
        }
    }

    @MainActor
    private func finish() {
        isBusy = false
        currentSessionId = nil
        let completion = onComplete
        onComplete = nil
        completion?()
    }

    /// Build a segment transcriber bound to the selected engine, loading the
    /// model first if needed. The returned closure runs off the main actor.
    private func makeTranscriber() async -> (engine: String, transcribe: SegmentTranscribe)? {
        switch ModelStateManager.shared.selectedEngine {
        case .parakeet:
            if ModelStateManager.shared.loadedParakeetTranscriber == nil ||
               ModelStateManager.shared.parakeetLoadingState != .loaded {
                await ModelStateManager.shared.loadParakeetModel()
            }
            guard let transcriber = ModelStateManager.shared.loadedParakeetTranscriber,
                  transcriber.isReady else { return nil }
            let closure: SegmentTranscribe = { samples in
                // Serialize with interactive PTT/OpenClaw on the shared model.
                let raw = try await TranscriptionEngineGate.shared.run {
                    try await transcriber.transcribe(audioSamples: Self.pad(samples))
                }
                return Self.postProcess(raw, sampleCount: samples.count)
            }
            return ("parakeet", closure)

        case .whisperKit:
            if ModelStateManager.shared.loadedWhisperKit == nil,
               let model = ModelStateManager.shared.selectedModel {
                _ = await ModelStateManager.shared.loadModel(model)
            }
            guard let whisperKit = ModelStateManager.shared.loadedWhisperKit else { return nil }
            let closure: SegmentTranscribe = { samples in
                // Serialize with interactive PTT/OpenClaw on the shared model.
                let results = try await TranscriptionEngineGate.shared.run {
                    try await whisperKit.transcribe(
                        audioArray: Self.pad(samples),
                        decodeOptions: DecodingOptions(
                            verbose: false,
                            task: .transcribe,
                            language: "en",
                            temperature: 0.0,
                            temperatureFallbackCount: 3,
                            sampleLength: 224,
                            topK: 5,
                            usePrefillPrompt: true,
                            usePrefillCache: true,
                            skipSpecialTokens: true,
                            withoutTimestamps: true,
                            clipTimestamps: [],
                            suppressBlank: true,
                            supressTokens: nil
                        )
                    )
                }
                let raw = results.first?.text ?? ""
                return Self.postProcess(raw, sampleCount: samples.count)
            }
            return ("whisperKit", closure)
        }
    }

    // MARK: - Segment post-processing (matches the PTT path)

    /// Pad sub-1.5s clips with 1s of silence, like AudioTranscriptionManager —
    /// short zero-padded audio makes both engines more reliable.
    nonisolated private static func pad(_ samples: [Float]) -> [Float] {
        let minSamples = Int(1.5 * sampleRate)
        guard samples.count < minSamples else { return samples }
        return samples + [Float](repeating: 0, count: Int(sampleRate))
    }

    /// Trim, drop likely hallucinations on short audio, apply text replacements.
    nonisolated private static func postProcess(_ raw: String, sampleCount: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let duration = Double(sampleCount) / sampleRate
        if STTHallucinationFilter.isLikelyHallucination(trimmed, audioDurationSeconds: duration) {
            return ""
        }
        return TextReplacements.shared.processText(trimmed)
    }

    // MARK: - Helpers

    /// Persist metadata.json, logging (not swallowing) any write failure so a
    /// failed session doesn't silently appear as plain "captured".
    nonisolated private static func writeMetadata(_ meta: CallSessionMetadata, to sessionDir: URL) {
        do {
            try meta.write(to: sessionDir.appendingPathComponent("metadata.json"))
        } catch {
            NSLog("[Transcribe] Failed to write metadata.json for \(meta.id): \(error.localizedDescription)")
        }
    }

    nonisolated private static func sanitize(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "audio" : String(trimmed.prefix(40))
    }

    // Main-actor-isolated (the class is @MainActor); only used from
    // transcribeFiles. Not `nonisolated`, since DateFormatter isn't Sendable.
    static let folderStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
