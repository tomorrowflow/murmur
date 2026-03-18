import Foundation
import AVFoundation
import MediaPlayer

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
    private var prefetchGeneration: Int = 0
    private var isPlayingInterruptResponse = false
    private var downloadGeneration: Int = 0
    private var preInterruptTranscript: [ScriptLine]?
    private var preInterruptActiveLineId: UUID?
    private(set) var isPaused = false
    private var pendingPlayData: (data: Data, chunkIndex: Int)?
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
    var podcastLength: String {
        UserDefaults.standard.string(forKey: "podcast.length") ?? "auto"
    }
    var webSearchEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "podcast.webSearchEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "podcast.webSearchEnabled") }
    }

    /// Called by the app delegate when a remote command (play/pause) is received.
    var onRemotePlayPause: (() -> Void)?

    override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        urlSession = URLSession(configuration: config)
        setupRemoteCommandCenter()
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
                "model": self.selectedModel,
                "target_length": self.podcastLength,
                "host_a_name": self.hostAName,
                "host_b_name": self.hostBName
            ]
            if let subject = subject {
                payload["subject"] = subject
            }
            NSLog("Podcast: INGEST web_search=\(self.webSearchEnabled) model=\(self.selectedModel) length=\(self.podcastLength) hostA=\(self.hostAName) hostB=\(self.hostBName)")
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

    var audioSegmentCount: Int { audioSegments.count }

    func pausePlayback() {
        isPaused = true
        player?.pause()
        cancelLineAdvanceTimers()
        updateNowPlaying(paused: true)
    }

    func resumePlayback() {
        isPaused = false

        if let p = player, !p.isPlaying {
            // Resume current chunk from where it was paused
            p.play()
            updateNowPlaying(paused: false)
            // Re-schedule line advancement for remaining time
            let remaining = p.duration - p.currentTime
            if remaining > 0 {
                scheduleLineAdvancement(duration: p.duration, hasPrependedSilence: false)
            }
        } else if let pending = pendingPlayData {
            // A chunk was queued while the previous chunk had finished during pause
            pendingPlayData = nil
            NSLog("Podcast: resuming with queued chunk \(pending.chunkIndex)")
            playAudioData(pending.data, chunkIndex: pending.chunkIndex, alreadyCollected: true)
        }
        updateNowPlaying(paused: false)
    }

    private var isReplaying = false

    /// Replay the full podcast from the beginning using collected audio segments.
    func replayFromStart() {
        NSLog("Podcast: replaying from start (\(audioSegments.count) segments)")

        // Reset chunk tracking to beginning
        currentChunkIndex = 0
        isReplaying = true
        delegate?.podcastDidUpdateChunkProgress(current: 1, total: totalChunks)

        // Reset line highlighting to the first transcript line
        currentChunkLines = transcript.filter { !$0.isInterruptMarker }
        if let first = transcript.first {
            activeLineId = first.id
            delegate?.podcastDidActivateLine(first.id)
        }

        // Combine and play
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self, let data = self.combinedAudioData() else { return }
            DispatchQueue.main.async {
                do {
                    self.player?.stop()
                    // Prepend silence so audio device wakes up before speech
                    let playData = self.prependSilence(to: data) ?? data
                    self.player = try AVAudioPlayer(data: playData)
                    self.player?.delegate = self
                    self.player?.prepareToPlay()
                    self.player?.play()
                    self.state = .playing
                    self.updateNowPlaying()

                    // Schedule line advancement over full transcript
                    let allLines = self.transcript.filter { !$0.isInterruptMarker }
                    self.currentChunkLines = allLines
                    self.scheduleLineAdvancement(duration: self.player?.duration ?? 0, hasPrependedSilence: true)
                } catch {
                    NSLog("Podcast: replay failed: \(error)")
                }
            }
        }
    }

    /// Cancel an in-progress interrupt and resume podcast flow.
    /// Used when the user's recording fails, is cancelled, or contains no speech.
    func cancelInterrupt() {
        isPlayingInterruptResponse = false

        // Restore transcript to pre-interrupt state
        if let saved = preInterruptTranscript {
            transcript = saved
            delegate?.podcastDidUpdateTranscript(transcript)
            if let lineId = preInterruptActiveLineId {
                activeLineId = lineId
                delegate?.podcastDidActivateLine(lineId)
            }
        }
        preInterruptTranscript = nil
        preInterruptActiveLineId = nil

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
        downloadGeneration += 1  // invalidate any in-flight audio download
        state = .listening

        // Discard stale prefetch — server will invalidate all chunks after current
        if let prefetchURL = prefetchedAudioURL {
            try? FileManager.default.removeItem(at: prefetchURL)
            prefetchedAudioURL = nil
        }
        prefetchedTranscriptLines = []
        isDownloadingPrefetch = false
        prefetchGeneration += 1  // invalidate any in-flight prefetch

        // Save transcript state for restoration if interrupt is cancelled
        preInterruptTranscript = transcript
        preInterruptActiveLineId = activeLineId

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

        // Successful interrupt — discard saved transcript
        preInterruptTranscript = nil
        preInterruptActiveLineId = nil

        // Insert interrupt marker followed by the user's question
        let marker = ScriptLine.interruptMarker(question: question)
        transcript.append(marker)
        let userLine = ScriptLine(speaker: "You", text: question)
        transcript.append(userLine)
        delegate?.podcastDidUpdateTranscript(transcript)
        delegate?.podcastDidActivateLine(userLine.id)

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

            if !isPaused && (state == .buffering || player == nil || !(player?.isPlaying ?? false)) {
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
            // Reset stale progress from previous chunk generation
            delegate?.podcastDidUpdateProgress(stage: "interrupt", percent: -1, message: nil)

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
        delegate?.podcastDidUpdateProgress(stage: "download", percent: -1, message: "Downloading audio...")
        let generation = downloadGeneration

        Task {
            do {
                let (data, _) = try await urlSession.data(from: url)
                await MainActor.run {
                    guard self.downloadGeneration == generation else {
                        NSLog("Podcast: discarding stale audio download (interrupted)")
                        return
                    }
                    self.playAudioData(data, chunkIndex: chunkIndex)
                }
            } catch {
                await MainActor.run {
                    guard self.downloadGeneration == generation else { return }
                    NSLog("Podcast: audio download failed: \(error)")
                    self.state = .error("Audio download failed")
                    self.delegate?.podcastDidError("Failed to download audio")
                }
            }
        }
    }

    private func playAudioData(_ data: Data, chunkIndex: Int, alreadyCollected: Bool = false) {
        // Collect audio segment for full download
        if !alreadyCollected {
            audioSegments.append(data)
        }

        // If paused, queue this chunk to play when resumed
        if isPaused {
            NSLog("Podcast: queuing chunk \(chunkIndex) (paused)")
            pendingPlayData = (data: data, chunkIndex: chunkIndex)
            currentChunkIndex = chunkIndex
            if chunkIndex >= 0 {
                delegate?.podcastDidUpdateChunkProgress(current: chunkIndex + 1, total: totalChunks)
            }
            // Still prefetch the next chunk
            if chunkIndex >= 0 && currentChunkIndex + 1 < totalChunks {
                requestNextChunk()
            }
            return
        }

        do {
            // For the first chunk, prepend silence so the audio device wakes up
            // before speech begins (prevents first words being swallowed)
            let playData: Data
            if chunkIndex == 0, let silenced = prependSilence(to: data) {
                playData = silenced
            } else {
                playData = data
            }

            player = try AVAudioPlayer(data: playData)
            player?.delegate = self
            player?.prepareToPlay()
            player?.play()
            state = .playing
            updateNowPlaying()
            if chunkIndex >= 0 {
                delegate?.podcastDidUpdateChunkProgress(current: chunkIndex + 1, total: totalChunks)
            }

            // Schedule line-by-line advancement through the current chunk
            scheduleLineAdvancement(duration: player?.duration ?? 0, hasPrependedSilence: chunkIndex == 0)

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

    /// The duration of silence prepended to the first chunk / replay audio.
    private let prependedSilenceDuration: TimeInterval = 0.4

    private func scheduleLineAdvancement(duration: TimeInterval, hasPrependedSilence: Bool = false) {
        cancelLineAdvanceTimers()
        let lines = currentChunkLines
        guard !lines.isEmpty, duration > 0 else { return }

        // Estimate each line's spoken duration using character count (more accurate
        // than word count because long words take proportionally longer to speak).
        // Add a fixed pause at each speaker change to model the natural gap between turns.
        let speakerChangePause: TimeInterval = 0.35
        var weights = [Double]()
        for (i, line) in lines.enumerated() {
            // Character-based weight (minimum 10 chars to avoid near-zero weights)
            var w = Double(max(line.text.count, 10))
            // Add pause weight when the speaker changes
            if i > 0 && lines[i].speaker != lines[i - 1].speaker {
                w += speakerChangePause * 15.0 // ~15 chars ≈ 1 second of speech
            }
            weights.append(w)
        }
        let totalWeight = weights.reduce(0, +)

        // If we prepended silence, that time is in the duration but isn't speech.
        // Reserve it as an initial offset so the first line starts after the silence.
        let silenceOffset: TimeInterval = hasPrependedSilence ? prependedSilenceDuration : 0
        let speechDuration = duration - silenceOffset

        // Activate first line immediately
        if let first = lines.first {
            activeLineId = first.id
            delegate?.podcastDidActivateLine(first.id)
        }

        var elapsed: TimeInterval = silenceOffset
        for (i, line) in lines.enumerated() {
            let lineId = line.id
            let delay = elapsed
            if i > 0 { // first line already activated above
                let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                    self?.activeLineId = lineId
                    self?.delegate?.podcastDidActivateLine(lineId)
                }
                lineAdvanceTimers.append(timer)
            }
            elapsed += (weights[i] / totalWeight) * speechDuration
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
        let generation = prefetchGeneration
        Task {
            do {
                let (data, _) = try await urlSession.data(from: url)
                let tempFile = FileManager.default.temporaryDirectory
                    .appendingPathComponent("podcast_prefetch_\(UUID().uuidString).mp3")
                try data.write(to: tempFile)
                await MainActor.run {
                    // Discard if an interrupt happened while downloading
                    guard self.prefetchGeneration == generation else {
                        try? FileManager.default.removeItem(at: tempFile)
                        NSLog("Podcast: discarding stale prefetch (interrupted)")
                        return
                    }
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

    // MARK: - Audio Helpers

    /// Prepend a short silence to audio data so the audio device can wake up
    /// before speech begins. Returns new Data with silence + original audio.
    private func prependSilence(to audioData: Data, seconds: Double = 0.4) -> Data? {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("podcast_silence_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let srcFile = tmpDir.appendingPathComponent("src.mp3")
        try? audioData.write(to: srcFile)

        guard let audioFile = try? AVAudioFile(forReading: srcFile) else { return nil }
        let fmt = audioFile.processingFormat
        let srcFrameCount = AVAudioFrameCount(audioFile.length)

        // Create silence buffer
        let silenceFrames = AVAudioFrameCount(fmt.sampleRate * seconds)
        guard let silenceBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: silenceFrames) else { return nil }
        silenceBuf.frameLength = silenceFrames
        // Buffer is zero-initialized = silence

        // Read source audio
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: srcFrameCount) else { return nil }
        do { try audioFile.read(into: srcBuf) } catch { return nil }

        // Write combined WAV
        let outFile = tmpDir.appendingPathComponent("out.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: fmt.sampleRate,
            AVNumberOfChannelsKey: fmt.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            try autoreleasepool {
                let wavFile = try AVAudioFile(forWriting: outFile, settings: settings)
                try wavFile.write(from: silenceBuf)
                try wavFile.write(from: srcBuf)
            }
            return try Data(contentsOf: outFile)
        } catch {
            NSLog("Podcast: prependSilence failed: \(error)")
            return nil
        }
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Replay finished — return to complete state
        if isReplaying {
            isReplaying = false
            NSLog("Podcast: replay finished")
            state = .complete
            updateNowPlaying(paused: true)
            return
        }

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
            updateNowPlaying(paused: true)
        } else {
            // Waiting for prefetch to complete
            NSLog("Podcast: waiting for next chunk (prefetch not ready)")
            state = .buffering
        }
    }

    // MARK: - Audio Export

    /// Combine all collected audio segments into a single WAV file.
    /// Uses AVAudioFile to decode any format (WAV, FLAC, etc.) to PCM.
    func combinedAudioData() -> Data? {
        guard !audioSegments.isEmpty else { return nil }

        // Single segment — return as-is
        if audioSegments.count == 1 { return audioSegments[0] }

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("podcast_export_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Decode each segment to float32 PCM buffers using AVAudioFile
        var pcmBuffers: [AVAudioPCMBuffer] = []
        var processingFormat: AVAudioFormat?

        for (i, segment) in audioSegments.enumerated() {
            let tmpFile = tmpDir.appendingPathComponent("seg\(i).mp3")
            do {
                try segment.write(to: tmpFile)
                let audioFile = try AVAudioFile(forReading: tmpFile)
                if i == 0 {
                    processingFormat = audioFile.processingFormat
                    NSLog("Podcast: audio format: sr=\(audioFile.processingFormat.sampleRate) ch=\(audioFile.processingFormat.channelCount)")
                }
                let frameCount = AVAudioFrameCount(audioFile.length)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
                    NSLog("Podcast: failed to create buffer for segment \(i)")
                    continue
                }
                try audioFile.read(into: buffer)
                pcmBuffers.append(buffer)
            } catch {
                NSLog("Podcast: failed to decode segment \(i): \(error)")
            }
        }

        guard !pcmBuffers.isEmpty, let fmt = processingFormat else {
            NSLog("Podcast: no decodable audio segments")
            return nil
        }

        // Write all buffers to a single WAV file
        let outputFile = tmpDir.appendingPathComponent("combined.wav")
        do {
            // Use explicit 16-bit PCM interleaved settings for maximum compatibility
            let wavSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: fmt.sampleRate,
                AVNumberOfChannelsKey: fmt.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]

            // Scope the AVAudioFile so it closes and finalizes the WAV header before we read
            try autoreleasepool {
                let wavFile = try AVAudioFile(forWriting: outputFile, settings: wavSettings)
                for buffer in pcmBuffers {
                    try wavFile.write(from: buffer)
                }
            }

            let wavData = try Data(contentsOf: outputFile)
            NSLog("Podcast: combined audio: \(wavData.count) bytes")
            return wavData
        } catch {
            NSLog("Podcast: failed to write combined WAV: \(error)")
            return nil
        }
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
        isReplaying = false
        isPaused = false
        pendingPlayData = nil
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
        clearNowPlaying()
    }

    // MARK: - Now Playing Integration

    private func setupRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.state == .complete {
                self.onRemotePlayPause?()
            } else {
                self.resumePlayback()
                self.updateNowPlaying(paused: false)
            }
            return .success
        }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.pausePlayback()
            self.updateNowPlaying(paused: true)
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.onRemotePlayPause?()
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.seekForwardCommand.isEnabled = false
        center.seekBackwardCommand.isEnabled = false
    }

    func updateNowPlaying(paused: Bool = false) {
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = title.isEmpty ? "Podcast" : title
        info[MPMediaItemPropertyArtist] = "Murmur"
        info[MPNowPlayingInfoPropertyPlaybackRate] = paused ? 0.0 : 1.0

        if let p = player {
            info[MPMediaItemPropertyPlaybackDuration] = p.duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = p.currentTime
        }

        if totalChunks > 0 {
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = currentChunkIndex
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = totalChunks
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = paused ? .paused : .playing
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}

