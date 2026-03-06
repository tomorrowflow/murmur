import Foundation
import AVFoundation

// MARK: - Protocol

protocol PodcastManagerDelegate: AnyObject {
    func podcastDidChangeState(_ state: PodcastState)
    func podcastDidUpdateTranscript(_ lines: [ScriptLine])
    func podcastDidUpdateTitle(_ title: String)
    func podcastDidError(_ message: String)
}

// MARK: - Models

enum PodcastState: Equatable {
    case idle
    case connecting
    case ingesting
    case buffering
    case playing
    case interrupted
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
        case .interrupted: return "Interrupted"
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
    private var player: AVAudioPlayer?
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    private var keepaliveTimer: Timer?
    private var isDownloadingPrefetch = false

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
                "content": content
            ]
            if let subject = subject {
                payload["subject"] = subject
            }
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
    }

    func resumePlayback() {
        player?.play()
    }

    func sendInterrupt(question: String) {
        guard let sessionId = sessionId, isSessionActive else { return }

        pausePlayback()
        state = .interrupted

        sendJSON([
            "type": "INTERRUPT",
            "session_id": sessionId,
            "question": question
        ])

        state = .processingInterrupt
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
                    if self.isSessionActive {
                        self.state = .error("Connection lost: \(error.localizedDescription)")
                        self.delegate?.podcastDidError("Connection lost")
                    }
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
            state = .buffering
            NSLog("Podcast: session created (id=\(sessionId ?? "?"), chunks=\(totalChunks))")

            // Request first chunk
            requestNextChunk()

        case "CHUNK_READY":
            let chunkIndex = json["chunk_index"] as? Int ?? 0
            guard let audioURL = json["audio_url"] as? String else { return }

            // Parse transcript lines from the chunk
            if let transcriptData = json["transcript"] as? [[String: Any]] {
                let lines = transcriptData.compactMap { dict -> ScriptLine? in
                    guard let speaker = dict["speaker"] as? String,
                          let text = dict["text"] as? String else { return nil }
                    return ScriptLine(speaker: speaker, text: text)
                }

                if chunkIndex == currentChunkIndex {
                    // This is the chunk we need to play now
                    transcript.append(contentsOf: lines)
                    delegate?.podcastDidUpdateTranscript(transcript)
                    downloadAndPlay(audioURL: audioURL, chunkIndex: chunkIndex)
                } else {
                    // This is a prefetched chunk — store for later
                    prefetchAudio(audioURL: audioURL, lines: lines)
                }
            } else {
                downloadAndPlay(audioURL: audioURL, chunkIndex: chunkIndex)
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
                delegate?.podcastDidUpdateTranscript(transcript)
            }

            downloadAndPlay(audioURL: audioURL, chunkIndex: -1) // -1 = interrupt response

        case "SCRIPT_UPDATED":
            if let remaining = json["remaining_chunks"] as? Int {
                totalChunks = currentChunkIndex + remaining
                NSLog("Podcast: script updated, \(remaining) chunks remaining")
            }

        case "ERROR":
            let code = json["code"] as? String ?? "UNKNOWN"
            let message = json["message"] as? String ?? "Unknown error"
            NSLog("Podcast: server error [\(code)] \(message)")
            state = .error(message)
            delegate?.podcastDidError(message)

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
            player = try AVAudioPlayer(data: data)
            player?.delegate = self
            player?.prepareToPlay()
            player?.play()
            state = .playing

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

        // Check if we have a prefetched chunk ready
        if let prefetchURL = prefetchedAudioURL {
            prefetchedAudioURL = nil
            currentChunkIndex += 1

            do {
                let data = try Data(contentsOf: prefetchURL)
                try? FileManager.default.removeItem(at: prefetchURL)
                playAudioData(data, chunkIndex: currentChunkIndex)
            } catch {
                NSLog("Podcast: failed to play prefetched audio: \(error)")
                state = .buffering
                requestNextChunk()
            }
        } else if currentChunkIndex + 1 >= totalChunks {
            // No more chunks
            state = .complete
        } else {
            // Waiting for prefetch to complete
            state = .buffering
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
        player = nil
        sessionId = nil
        currentChunkIndex = 0
        totalChunks = 0
        title = ""
        transcript = []
        isDownloadingPrefetch = false

        if let prefetchURL = prefetchedAudioURL {
            try? FileManager.default.removeItem(at: prefetchURL)
            prefetchedAudioURL = nil
        }

        state = .idle
    }
}
