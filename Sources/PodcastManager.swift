import Foundation
import AVFoundation

// MARK: - Protocol

protocol PodcastManagerDelegate: AnyObject {
    func podcastDidChangeState(_ state: PodcastState)
    func podcastDidUpdateTranscript(_ lines: [ScriptLine])
    func podcastDidUpdateTitle(_ title: String)
    func podcastDidActivateLine(_ lineId: UUID)
    func podcastDidUpdateProgress(stage: String, percent: Int, message: String?)
    func podcastDidUpdateChunkProgress(current: Int, total: Int)
    func podcastDidError(_ message: String)
}

// MARK: - Models

enum PodcastState: Equatable {
    case idle
    case connecting
    case ingesting
    case buffering
    case playing
    case listening        // user is recording an interrupt question
    case processingInterrupt
    case complete
    case error(String)

    var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .ingesting: return "Generating Script"
        case .buffering: return "Buffering"
        case .playing: return "Playing"
        case .listening: return "Listening"
        case .processingInterrupt: return "Processing"
        case .complete: return "Complete"
        case .error: return "Error"
        }
    }
}

struct ScriptLine: Identifiable, Equatable {
    let id = UUID()
    let speaker: String
    let text: String
    var isInterruptMarker: Bool = false

    static func interruptMarker(question: String) -> ScriptLine {
        ScriptLine(speaker: "", text: question, isInterruptMarker: true)
    }
}

// MARK: - PodcastManager

class PodcastManager: NSObject, AVAudioPlayerDelegate {
    weak var delegate: PodcastManagerDelegate?

    private(set) var state: PodcastState = .idle {
        didSet {
            if state != oldValue {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.podcastDidChangeState(self.state)
                }
            }
        }
    }

    var isSessionActive: Bool {
        switch state {
        case .idle, .complete, .error: return false
        default: return true
        }
    }

    private var sessionId: String?
    private var currentChunkIndex: Int = 0
    private var totalChunks: Int = 0
    private var title: String = ""
    private var transcript: [ScriptLine] = []
    private var prefetchedAudioURL: URL?
    private var prefetchedTranscriptLines: [ScriptLine] = []
    private var player: AVAudioPlayer?
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    private var keepaliveTimer: Timer?
    private var isDownloadingPrefetch = false
    private var isPlayingInterruptResponse = false
    private var lineAdvanceTimers: [Timer] = []
    private var currentChunkLines: [ScriptLine] = []
    private(set) var activeLineId: UUID?
    private var audioSegments: [Data] = []  // collected audio for full download

    // Settings (from UserDefaults)
    private var podcastdURL: String {
        UserDefaults.standard.string(forKey: "podcast.wsURL") ?? ""
    }
    private var audioBaseURL: String {
        UserDefaults.standard.string(forKey: "podcast.audioBaseURL") ?? ""
    }
    var hostAName: String {
        let name = UserDefaults.standard.string(forKey: "podcast.hostAName")
        return (name?.isEmpty ?? true) ? "Alex" : name!
    }
    var hostBName: String {
        let name = UserDefaults.standard.string(forKey: "podcast.hostBName")
        return (name?.isEmpty ?? true) ? "Jordan" : name!
    }
    var selectedModel: String {
        UserDefaults.standard.string(forKey: "podcast.model") ?? "large-q4"
    }
    var webSearchEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "podcast.webSearchEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "podcast.webSearchEnabled") }
    }

    override init() {
        super.init()
        urlSession = URLSession(configuration: .default)
    }

    deinit {
        disconnect()
    }

    // MARK: - Public API

    func startSession(contentType: String, content: String, subject: String? = nil) {
        guard !isSessionActive else {
            NSLog("Podcast: session already active")
            return
        }

        guard !podcastdURL.isEmpty else {
            state = .error("podcastd URL not configured")
            delegate?.podcastDidError("Configure podcastd URL in Settings > Podcast")
            return
        }

        reset()
        state = .connecting
        connect()

        // Send INGEST after connection is established
        // (the WebSocket will be ready synchronously after connect() since we start listening immediately)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            var payload: [String: Any] = [
                "type": "INGEST",
                "content_type": contentType,
                "content": content,
                "web_search": self.webSearchEnabled,
                "model": self.selectedModel
            ]
            if let subject = subject {
                payload["subject"] = subject
            }
            NSLog("Podcast: INGEST web_search=\(self.webSearchEnabled) model=\(self.selectedModel)")
            self.sendJSON(payload)
            self.state = .ingesting
        }
    }

    func stopSession() {
        guard let sessionId = sessionId else {
            reset()
            return
        }

        sendJSON([
            "type": "STOP",
            "session_id": sessionId
        ])
        reset()
    }

    func pausePlayback() {
        player?.pause()
        cancelLineAdvanceTimers()
    }

    func resumePlayback() {
        player?.play()
    }

    /// Cancel an in-progress interrupt and resume podcast flow.
    /// Used when the user's recording fails or is cancelled.
    func cancelInterrupt() {
        isPlayingInterruptResponse = false
        state = .buffering
        requestNextChunk()
    }

    /// Called when the user starts recording an interrupt (double-tap).
    /// Stops playback, freezes transcript, and discards stale prefetch.
    func beginInterrupt() {
        // Stop (not pause) — we never resume this audio
        player?.stop()
        player = nil
        cancelLineAdvanceTimers()
        state = .listening

        // Discard stale prefetch — server will invalidate all chunks after current
        if let prefetchURL = prefetchedAudioURL {
            try? FileManager.default.removeItem(at: prefetchURL)
            prefetchedAudioURL = nil
        }
        prefetchedTranscriptLines = []
        isDownloadingPrefetch = false

        // Truncate transcript: keep up to the active line, drop the rest
        if let currentActiveId = activeLineId,
           let activeIndex = transcript.firstIndex(where: { $0.id == currentActiveId }) {
            transcript = Array(transcript.prefix(through: activeIndex))
            delegate?.podcastDidUpdateTranscript(transcript)
        }
    }

    /// Called after the user's question has been transcribed.
    func sendInterrupt(question: String) {
        guard let sessionId = sessionId, isSessionActive else {
            NSLog("Podcast: sendInterrupt blocked — sessionId=\(sessionId ?? "nil"), isActive=\(isSessionActive)")
            return
        }

        NSLog("Podcast: sending INTERRUPT question=\"\(question)\" session=\(sessionId)")

        // Insert interrupt marker
        let marker = ScriptLine.interruptMarker(question: question)
        transcript.append(marker)
        delegate?.podcastDidUpdateTranscript(transcript)
        delegate?.podcastDidActivateLine(marker.id)

        state = .processingInterrupt

        sendJSON([
            "type": "INTERRUPT",
            "session_id": sessionId,
            "question": question
        ])
    }

    // MARK: - WebSocket Connection

    private func connect() {
        guard let url = URL(string: podcastdURL) else {
            state = .error("Invalid podcastd URL")
            return
        }

        let task = urlSession.webSocketTask(with: url)
        task.resume()
        webSocketTask = task
        startListening()
        startKeepalive()
        NSLog("Podcast: connecting to \(podcastdURL)")
    }

    private func disconnect() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    private func startListening() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.startListening() // continue receiving
            case .failure(let error):
                NSLog("Podcast: WebSocket error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    // Ignore errors from intentional disconnects (state already .idle after reset)
                    guard self.isSessionActive else { return }
                    self.delegate?.podcastDidError("Connection lost")
                    self.disconnect()
                    self.state = .error("Connection lost: \(error.localizedDescription)")
                }
            }
        }
    }

    private func startKeepalive() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.sendJSON(["type": "PING"])
        }
    }

    // MARK: - Message Handling

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.handleServerMessage(type: type, json: json)
        }
    }

    private func handleServerMessage(type: String, json: [String: Any]) {
        switch type {
        case "SESSION_CREATED":
            sessionId = json["session_id"] as? String
            title = json["title"] as? String ?? "Podcast"
            totalChunks = json["total_chunks"] as? Int ?? 0
            currentChunkIndex = 0
            delegate?.podcastDidUpdateTitle(title)
            delegate?.podcastDidUpdateChunkProgress(current: 0, total: totalChunks)
            state = .buffering
            NSLog("Podcast: session created (id=\(sessionId ?? "?"), chunks=\(totalChunks))")

            // Request first chunk
            requestNextChunk()

        case "CHUNK_READY":
            let chunkIndex = json["chunk_index"] as? Int ?? 0
            guard let audioURL = json["audio_url"] as? String else { return }
            NSLog("Podcast: CHUNK_READY chunk_index=\(chunkIndex), currentChunkIndex=\(currentChunkIndex), state=\(state.displayName)")

            // Ignore stale chunks that arrive during/after interrupt processing
            if state == .processingInterrupt || state == .listening {
                NSLog("Podcast: ignoring CHUNK_READY during interrupt (state=\(state.displayName))")
                return
            }

            // Parse transcript lines from the chunk
            let lines: [ScriptLine]
            if let transcriptData = json["transcript"] as? [[String: Any]] {
                lines = transcriptData.compactMap { dict -> ScriptLine? in
                    guard let speaker = dict["speaker"] as? String,
                          let text = dict["text"] as? String else { return nil }
                    return ScriptLine(speaker: speaker, text: text)
                }
            } else {
                lines = []
            }

            if state == .buffering || player == nil || !(player?.isPlaying ?? false) {
                // We need audio now — play immediately
                if !lines.isEmpty {
                    transcript.append(contentsOf: lines)
                    currentChunkLines = lines
                    delegate?.podcastDidUpdateTranscript(transcript)
                }
                downloadAndPlay(audioURL: audioURL, chunkIndex: chunkIndex)
            } else {
                // Currently playing — prefetch for later
                prefetchAudio(audioURL: audioURL, lines: lines)
            }

        case "INTERRUPT_PROCESSING":
            state = .processingInterrupt

        case "INTERRUPT_READY":
            guard let audioURL = json["audio_url"] as? String else { return }

            if let transcriptData = json["transcript"] as? [[String: Any]] {
                let lines = transcriptData.compactMap { dict -> ScriptLine? in
                    guard let speaker = dict["speaker"] as? String,
                          let text = dict["text"] as? String else { return nil }
                    return ScriptLine(speaker: speaker, text: text)
                }
                transcript.append(contentsOf: lines)
                currentChunkLines = lines
                delegate?.podcastDidUpdateTranscript(transcript)
            }

            isPlayingInterruptResponse = true
            downloadAndPlay(audioURL: audioURL, chunkIndex: -1) // -1 = interrupt response

        case "SCRIPT_UPDATED":
            if let remaining = json["remaining_chunks"] as? Int {
                totalChunks = currentChunkIndex + 1 + remaining
                NSLog("Podcast: script updated, \(remaining) chunks remaining, totalChunks=\(totalChunks)")
                delegate?.podcastDidUpdateChunkProgress(current: currentChunkIndex + 1, total: totalChunks)
            }

        case "ERROR":
            let code = json["code"] as? String ?? "UNKNOWN"
            let message = json["message"] as? String ?? "Unknown error"
            NSLog("Podcast: server error [\(code)] \(message)")
            state = .error(message)
            delegate?.podcastDidError(message)

        case "PROGRESS":
            let stage = json["stage"] as? String ?? ""
            let percent = json["percent"] as? Int ?? -1
            let message = json["message"] as? String
            delegate?.podcastDidUpdateProgress(stage: stage, percent: percent, message: message)

        case "PONG":
            break

        default:
            NSLog("Podcast: unknown message type: \(type)")
        }
    }

    // MARK: - Audio Playback

    private func downloadAndPlay(audioURL: String, chunkIndex: Int) {
        let fullURL: String
        if audioURL.hasPrefix("http") {
            fullURL = audioURL
        } else {
            let base = audioBaseURL.isEmpty ? podcastdURL.replacingOccurrences(of: "ws://", with: "http://").replacingOccurrences(of: "wss://", with: "https://") : audioBaseURL
            fullURL = "\(base)/audio/\(audioURL)"
        }

        guard let url = URL(string: fullURL) else {
            NSLog("Podcast: invalid audio URL: \(fullURL)")
            return
        }

        state = .buffering

        Task {
            do {
                let (data, _) = try await urlSession.data(from: url)
                await MainActor.run {
                    self.playAudioData(data, chunkIndex: chunkIndex)
                }
            } catch {
                await MainActor.run {
                    NSLog("Podcast: audio download failed: \(error)")
                    self.state = .error("Audio download failed")
                    self.delegate?.podcastDidError("Failed to download audio")
                }
            }
        }
    }

    private func playAudioData(_ data: Data, chunkIndex: Int) {
        do {
            // Collect audio segment for full download
            audioSegments.append(data)

            player = try AVAudioPlayer(data: data)
            player?.delegate = self
            player?.prepareToPlay()
            player?.play()
            state = .playing
            if chunkIndex >= 0 {
                delegate?.podcastDidUpdateChunkProgress(current: chunkIndex + 1, total: totalChunks)
            }

            // Schedule line-by-line advancement through the current chunk
            scheduleLineAdvancement(duration: player?.duration ?? 0)

            // Request next chunk while playing (prefetch)
            if chunkIndex >= 0 {
                currentChunkIndex = chunkIndex
                if currentChunkIndex + 1 < totalChunks {
                    requestNextChunk()
                }
            }
        } catch {
            NSLog("Podcast: playback error: \(error)")
            state = .error("Playback failed")
            delegate?.podcastDidError("Audio playback failed")
        }
    }

    private func scheduleLineAdvancement(duration: TimeInterval) {
        cancelLineAdvanceTimers()
        let lines = currentChunkLines
        guard !lines.isEmpty, duration > 0 else { return }

        // Distribute time proportionally by word count
        let wordCounts = lines.map { max(Double($0.text.split(separator: " ").count), 1.0) }
        let totalWords = wordCounts.reduce(0, +)

        var elapsed: TimeInterval = 0
        for (i, line) in lines.enumerated() {
            let lineId = line.id
            let delay = elapsed
            let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                self?.activeLineId = lineId
                self?.delegate?.podcastDidActivateLine(lineId)
            }
            lineAdvanceTimers.append(timer)
            elapsed += (wordCounts[i] / totalWords) * duration
        }

        // Activate first line immediately
        if let first = lines.first {
            activeLineId = first.id
            delegate?.podcastDidActivateLine(first.id)
        }
    }

    private func cancelLineAdvanceTimers() {
        lineAdvanceTimers.forEach { $0.invalidate() }
        lineAdvanceTimers.removeAll()
    }

    private func prefetchAudio(audioURL: String, lines: [ScriptLine]) {
        let fullURL: String
        if audioURL.hasPrefix("http") {
            fullURL = audioURL
        } else {
            let base = audioBaseURL.isEmpty ? podcastdURL.replacingOccurrences(of: "ws://", with: "http://").replacingOccurrences(of: "wss://", with: "https://") : audioBaseURL
            fullURL = "\(base)/audio/\(audioURL)"
        }

        guard let url = URL(string: fullURL) else { return }

        isDownloadingPrefetch = true
        Task {
            do {
                let (data, _) = try await urlSession.data(from: url)
                let tempFile = FileManager.default.temporaryDirectory
                    .appendingPathComponent("podcast_prefetch_\(UUID().uuidString).wav")
                try data.write(to: tempFile)
                await MainActor.run {
                    self.prefetchedAudioURL = tempFile
                    self.prefetchedTranscriptLines = lines
                    self.isDownloadingPrefetch = false
                    NSLog("Podcast: prefetched next chunk")
                }
            } catch {
                await MainActor.run {
                    self.isDownloadingPrefetch = false
                    NSLog("Podcast: prefetch failed: \(error)")
                }
            }
        }
    }

    private func requestNextChunk() {
        guard let sessionId = sessionId else { return }
        sendJSON([
            "type": "NEXT_CHUNK",
            "session_id": sessionId
        ])
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard isSessionActive else { return }

        // After interrupt response finishes, request next chunk from revised script
        if isPlayingInterruptResponse {
            isPlayingInterruptResponse = false
            NSLog("Podcast: interrupt response finished, requesting next chunk from revised script")
            state = .buffering
            requestNextChunk()
            return
        }

        NSLog("Podcast: chunk \(currentChunkIndex) finished playing")

        // Check if we have a prefetched chunk ready
        if let prefetchURL = prefetchedAudioURL {
            prefetchedAudioURL = nil
            currentChunkIndex += 1

            // Add prefetched transcript lines
            if !prefetchedTranscriptLines.isEmpty {
                transcript.append(contentsOf: prefetchedTranscriptLines)
                currentChunkLines = prefetchedTranscriptLines
                delegate?.podcastDidUpdateTranscript(transcript)
                prefetchedTranscriptLines = []
            }

            do {
                let data = try Data(contentsOf: prefetchURL)
                try? FileManager.default.removeItem(at: prefetchURL)
                NSLog("Podcast: playing prefetched chunk \(currentChunkIndex)")
                playAudioData(data, chunkIndex: currentChunkIndex)
            } catch {
                NSLog("Podcast: failed to play prefetched audio: \(error)")
                state = .buffering
                requestNextChunk()
            }
        } else if currentChunkIndex + 1 >= totalChunks {
            // No more chunks
            NSLog("Podcast: all chunks played, session complete")
            state = .complete
        } else {
            // Waiting for prefetch to complete
            NSLog("Podcast: waiting for next chunk (prefetch not ready)")
            state = .buffering
        }
    }

    // MARK: - Audio Export

    /// Combine all collected audio segments into a single WAV file.
    func combinedAudioData() -> Data? {
        guard !audioSegments.isEmpty else { return nil }

        // Single segment — return as-is
        if audioSegments.count == 1 { return audioSegments[0] }

        // Extract PCM data from each WAV segment, skipping headers.
        var pcmChunks: [Data] = []
        var sampleRate: UInt32 = 0
        var numChannels: UInt16 = 0
        var bitsPerSample: UInt16 = 0

        for (i, segment) in audioSegments.enumerated() {
            let bytes = [UInt8](segment)
            guard bytes.count > 44 else { continue }

            if i == 0 {
                // Read format from first segment using safe byte reads
                numChannels = readUInt16LE(bytes, offset: 22)
                sampleRate = readUInt32LE(bytes, offset: 24)
                bitsPerSample = readUInt16LE(bytes, offset: 34)
            }

            // Find "data" marker to locate PCM start
            if let dataOffset = findDataChunkOffset(in: bytes) {
                let pcmStart = dataOffset + 8 // skip "data" + 4-byte size
                if pcmStart < bytes.count {
                    pcmChunks.append(Data(bytes[pcmStart...]))
                }
            } else {
                // Fallback: assume 44-byte header
                pcmChunks.append(Data(bytes[44...]))
            }
        }

        guard !pcmChunks.isEmpty, sampleRate > 0 else { return nil }

        let totalPCMSize = pcmChunks.reduce(0) { $0 + $1.count }
        let byteRate = UInt32(numChannels) * sampleRate * UInt32(bitsPerSample) / 8
        let blockAlign = UInt16(numChannels) * bitsPerSample / 8

        // Build WAV header
        var wav = Data()
        wav.reserveCapacity(44 + totalPCMSize)
        wav.append(contentsOf: "RIFF".utf8)
        wav.append(UInt32(36 + totalPCMSize).littleEndianBytes)
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8)
        wav.append(UInt32(16).littleEndianBytes)          // fmt chunk size
        wav.append(UInt16(1).littleEndianBytes)           // PCM format
        wav.append(numChannels.littleEndianBytes)
        wav.append(sampleRate.littleEndianBytes)
        wav.append(byteRate.littleEndianBytes)
        wav.append(blockAlign.littleEndianBytes)
        wav.append(bitsPerSample.littleEndianBytes)
        wav.append(contentsOf: "data".utf8)
        wav.append(UInt32(totalPCMSize).littleEndianBytes)

        for chunk in pcmChunks {
            wav.append(chunk)
        }

        return wav
    }

    private func findDataChunkOffset(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        let d: UInt8 = 0x64, a: UInt8 = 0x61, t: UInt8 = 0x74  // "data"
        for i in 0..<(bytes.count - 3) {
            if bytes[i] == d && bytes[i+1] == a && bytes[i+2] == t && bytes[i+3] == a {
                return i
            }
        }
        return nil
    }

    /// Safe little-endian UInt32 read from byte array.
    private func readUInt32LE(_ bytes: [UInt8], offset: Int) -> UInt32 {
        guard offset + 3 < bytes.count else { return 0 }
        return UInt32(bytes[offset])
             | UInt32(bytes[offset+1]) << 8
             | UInt32(bytes[offset+2]) << 16
             | UInt32(bytes[offset+3]) << 24
    }

    /// Safe little-endian UInt16 read from byte array.
    private func readUInt16LE(_ bytes: [UInt8], offset: Int) -> UInt16 {
        guard offset + 1 < bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset+1]) << 8
    }

    // MARK: - Helpers

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            NSLog("Podcast: failed to serialize JSON")
            return
        }

        webSocketTask?.send(.string(string)) { error in
            if let error = error {
                NSLog("Podcast: send error: \(error.localizedDescription)")
            }
        }
    }

    private func reset() {
        disconnect()
        player?.stop()
        cancelLineAdvanceTimers()
        currentChunkLines = []
        isPlayingInterruptResponse = false
        player = nil
        sessionId = nil
        currentChunkIndex = 0
        totalChunks = 0
        title = ""
        transcript = []
        audioSegments = []
        isDownloadingPrefetch = false

        if let prefetchURL = prefetchedAudioURL {
            try? FileManager.default.removeItem(at: prefetchURL)
            prefetchedAudioURL = nil
        }
        prefetchedTranscriptLines = []

        state = .idle
    }
}

// MARK: - WAV Helpers

private extension UInt32 {
    var littleEndianBytes: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: 4)
    }
}

private extension UInt16 {
    var littleEndianBytes: Data {
        var value = self.littleEndian
        return Data(bytes: &value, count: 2)
    }
}
