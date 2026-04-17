import Foundation
import AppKit
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
    func podcastDidUpdateCacheStatus(canExport: Bool, hasAny: Bool)
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
    case disconnected     // transient network failure; local chunks still available
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
        case .disconnected: return "Disconnected"
        case .error: return "Error"
        }
    }

    var isError: Bool {
        if case .error = self { return true }
        return false
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
        case .idle, .complete, .error, .disconnected: return false
        default: return true
        }
    }

    private var sessionId: String?
    private var currentChunkIndex: Int = 0
    private var totalChunks: Int = 0
    private var title: String = ""
    private var transcript: [ScriptLine] = []
    // Eagerly-downloaded chunks, keyed by chunk_index. The canonical store —
    // populated on CHUNK_READY regardless of playback state so the user can
    // export/replay even if the connection drops or playback stalls.
    private var chunkAudioByIndex: [Int: Data] = [:]
    private var chunkTranscriptByIndex: [Int: [ScriptLine]] = [:]
    private var lastReceivedChunkIndex: Int = -1
    private var chunkDownloadGeneration: Int = 0
    private var player: AVAudioPlayer?
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession!
    private var keepaliveTimer: Timer?
    private var isPlayingInterruptResponse = false
    private var downloadGeneration: Int = 0
    private var preInterruptTranscript: [ScriptLine]?
    private var preInterruptActiveLineId: UUID?
    private(set) var isPaused = false
    private var pendingPlayData: (data: Data, chunkIndex: Int)?
    private var lineAdvanceTimers: [Timer] = []
    private var currentChunkLines: [ScriptLine] = []
    private(set) var activeLineId: UUID?
    // Audio in playback order — preserves interleaved interrupt responses for export.
    private var audioSegments: [Data] = []

    // Reconnect bookkeeping
    private var reconnectAttempt: Int = 0
    private var reconnectTimer: DispatchSourceTimer?
    private var isAttemptingReconnect = false

    // Escape key monitors
    private var escapeGlobalMonitor: Any?
    private var escapeLocalMonitor: Any?

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
        installEscapeMonitor()
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
        removeEscapeMonitor()
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

    // MARK: - Escape Key

    private func installEscapeMonitor() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            if event.keyCode == 53 {
                NSLog("Podcast: Escape key pressed — stopping session")
                DispatchQueue.main.async { self?.stopSession() }
            }
        }
        escapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event)
            return event.keyCode == 53 ? nil : event
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            escapeGlobalMonitor = nil
        }
        if let monitor = escapeLocalMonitor {
            NSEvent.removeMonitor(monitor)
            escapeLocalMonitor = nil
        }
    }

    var audioSegmentCount: Int { audioSegments.count }

    /// Number of chunks whose audio has been fully downloaded to local cache.
    var cachedChunkCount: Int { chunkAudioByIndex.count }

    /// True when every chunk of the currently-known script is cached locally.
    /// Export/replay work offline in this state.
    var hasAllChunksCached: Bool {
        totalChunks > 0 && chunkAudioByIndex.count >= totalChunks
    }

    /// True when at least one chunk of audio is cached locally.
    var hasAnyChunkCached: Bool {
        !chunkAudioByIndex.isEmpty || !audioSegments.isEmpty
    }

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
            if pending.chunkIndex >= 0 {
                startPlayingChunk(pending.chunkIndex)
            } else {
                playInterruptResponse(data: pending.data)
            }
        } else if state == .buffering {
            // Maybe a chunk arrived while paused — try advancing now.
            advanceAfterPlayback()
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
        // Resume eager streaming from the next chunk — server dropped its stream
        // when the interrupt arrived, so we have to re-trigger it.
        requestStreamChunks(from: currentChunkIndex + 1)
    }

    /// Called when the user starts recording an interrupt (double-tap).
    /// Stops playback, freezes transcript, and discards stale prefetch.
    func beginInterrupt() {
        // Stop (not pause) — we never resume this audio
        player?.stop()
        player = nil
        cancelLineAdvanceTimers()
        downloadGeneration += 1  // invalidate any in-flight audio download
        chunkDownloadGeneration += 1  // invalidate eager-download tasks for stale chunks
        state = .listening

        // Server invalidates all chunks past current_chunk_index; drop our cache
        // of those too so the rewritten chunks replace them cleanly.
        let keepUpTo = currentChunkIndex
        chunkAudioByIndex = chunkAudioByIndex.filter { $0.key <= keepUpTo }
        chunkTranscriptByIndex = chunkTranscriptByIndex.filter { $0.key <= keepUpTo }
        if lastReceivedChunkIndex > keepUpTo {
            lastReceivedChunkIndex = keepUpTo
        }
        delegate?.podcastDidUpdateCacheStatus(canExport: hasAllChunksCached, hasAny: hasAnyChunkCached)

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
            "question": question,
            "at_chunk_index": currentChunkIndex,
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
                    self.handleWebSocketDrop(reason: error.localizedDescription)
                }
            }
        }
    }

    /// Called when the WebSocket unexpectedly drops while a session was active.
    /// Switches to .disconnected (preserving cached audio + UI) and schedules
    /// auto-reconnect with exponential backoff.
    private func handleWebSocketDrop(reason: String) {
        // Intentional disconnect (reset/stop) — nothing to do.
        guard sessionId != nil else { return }
        // Already handled another drop or never connected.
        guard !isAttemptingReconnect, state != .idle, state != .error(reason) else { return }

        NSLog("Podcast: connection dropped — \(reason). Switching to .disconnected and scheduling reconnect.")
        disconnect()

        // Preserve the user-facing session: if we have audio cached they can still
        // export/replay locally; reconnect will try to fetch anything still missing.
        state = .disconnected
        delegate?.podcastDidError("Connection lost — reconnecting")
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        cancelReconnect()
        isAttemptingReconnect = true
        reconnectAttempt += 1
        // Exponential backoff capped at 60s. Attempts: 1s, 2s, 4s, 8s, 16s, 32s, 60s…
        let rawDelay = pow(2.0, Double(min(reconnectAttempt - 1, 6)))
        let delay = min(rawDelay, 60.0)
        NSLog("Podcast: reconnect attempt \(reconnectAttempt) in \(delay)s")

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.attemptReconnect()
        }
        timer.resume()
        reconnectTimer = timer
    }

    private func cancelReconnect() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
        isAttemptingReconnect = false
    }

    private func attemptReconnect() {
        guard let sid = sessionId else {
            cancelReconnect()
            return
        }
        guard let url = URL(string: podcastdURL) else {
            cancelReconnect()
            return
        }

        NSLog("Podcast: attempting reconnect (session=\(sid), lastReceived=\(lastReceivedChunkIndex))")
        let task = urlSession.webSocketTask(with: url)
        task.resume()
        webSocketTask = task
        startListening()
        startKeepalive()

        // Ask server to re-associate this websocket with the existing session
        // and resume streaming from where we left off.
        sendJSON([
            "type": "RESUME_SESSION",
            "session_id": sid,
            "last_received_chunk_index": lastReceivedChunkIndex,
        ])

        // If RESUME fails the server will reply NO_SESSION → ERROR; if it succeeds
        // SESSION_RESUMED lands in handleServerMessage. Either way we've used our
        // backoff slot.
        isAttemptingReconnect = false
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
            // Server auto-streams remaining chunks; no explicit request needed.

        case "SESSION_RESUMED":
            let total = json["total_chunks"] as? Int ?? totalChunks
            if total > 0 { totalChunks = total }
            reconnectAttempt = 0
            cancelReconnect()
            NSLog("Podcast: session resumed (total=\(totalChunks), cached=\(chunkAudioByIndex.count))")
            // Server will re-stream from lastReceivedChunkIndex+1 automatically.
            // Restore UI state based on what's locally available.
            if isPaused {
                updateNowPlaying(paused: true)
            } else if player?.isPlaying == true {
                state = .playing
            } else if hasAllChunksCached {
                state = .complete
                updateNowPlaying(paused: true)
            } else {
                state = .buffering
            }

        case "CHUNK_READY":
            let chunkIndex = json["chunk_index"] as? Int ?? 0
            guard let audioURL = json["audio_url"] as? String else { return }

            // End-of-stream sentinel: audio_url is empty string.
            if audioURL.isEmpty {
                NSLog("Podcast: end-of-stream sentinel received at chunk \(chunkIndex)")
                return
            }

            NSLog("Podcast: CHUNK_READY chunk_index=\(chunkIndex), state=\(state.displayName), cached=\(chunkAudioByIndex.count)/\(totalChunks)")

            // Ignore stale chunks that arrive during/after interrupt processing
            if state == .processingInterrupt || state == .listening {
                NSLog("Podcast: ignoring CHUNK_READY during interrupt (state=\(state.displayName))")
                return
            }

            // Already cached? Skip download (e.g. server re-sent on RESUME).
            if chunkAudioByIndex[chunkIndex] != nil {
                NSLog("Podcast: chunk \(chunkIndex) already cached, skipping download")
                return
            }

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
            chunkTranscriptByIndex[chunkIndex] = lines
            downloadChunkAudio(audioURL: audioURL, chunkIndex: chunkIndex)

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
            downloadAndPlayInterruptResponse(audioURL: audioURL)

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

            // Session expired past the server's reconnect grace period. If we
            // have everything cached the user can still export/replay, so
            // settle into .complete instead of blowing the overlay away.
            if code == "NO_SESSION" && hasAllChunksCached {
                NSLog("Podcast: server dropped session but audio is complete locally")
                cancelReconnect()
                state = .complete
                updateNowPlaying(paused: true)
                return
            }
            if code == "NO_SESSION" && hasAnyChunkCached {
                cancelReconnect()
                // Partial audio — keep UI usable for export.
                state = .disconnected
                delegate?.podcastDidError("Session expired — \(chunkAudioByIndex.count)/\(totalChunks) chunks cached")
                return
            }

            cancelReconnect()
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

    /// Resolve a server-relative or absolute audio URL to a full URL.
    private func resolveAudioURL(_ audioURL: String) -> URL? {
        let fullURL: String
        if audioURL.hasPrefix("http") {
            fullURL = audioURL
        } else {
            let base = audioBaseURL.isEmpty
                ? podcastdURL.replacingOccurrences(of: "ws://", with: "http://").replacingOccurrences(of: "wss://", with: "https://")
                : audioBaseURL
            fullURL = "\(base)/audio/\(audioURL)"
        }
        return URL(string: fullURL)
    }

    /// Download a chunk's audio bytes and store them in chunkAudioByIndex.
    /// If the chunk is the one we're currently waiting to play, kick playback.
    /// Playback state (paused, active) is not a factor — we always download.
    /// Retries up to `maxAttempts` times on network failure before giving up.
    private func downloadChunkAudio(audioURL: String, chunkIndex: Int, attempt: Int = 1) {
        guard let url = resolveAudioURL(audioURL) else {
            NSLog("Podcast: invalid audio URL: \(audioURL)")
            return
        }

        let generation = chunkDownloadGeneration
        let maxAttempts = 4
        Task {
            do {
                let (data, _) = try await urlSession.data(from: url)
                await MainActor.run {
                    guard self.chunkDownloadGeneration == generation else {
                        NSLog("Podcast: discarding stale chunk download (interrupt/reset)")
                        return
                    }
                    self.storeDownloadedChunk(data: data, chunkIndex: chunkIndex)
                }
            } catch {
                await MainActor.run {
                    guard self.chunkDownloadGeneration == generation else { return }
                    if attempt < maxAttempts {
                        let delay = pow(2.0, Double(attempt))
                        NSLog("Podcast: chunk \(chunkIndex) download failed (attempt \(attempt)/\(maxAttempts)): \(error) — retrying in \(delay)s")
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            self?.downloadChunkAudio(audioURL: audioURL, chunkIndex: chunkIndex, attempt: attempt + 1)
                        }
                    } else {
                        NSLog("Podcast: chunk \(chunkIndex) download permanently failed: \(error)")
                        // Stay in session; user can export partial or reconnect later.
                    }
                }
            }
        }
    }

    private func storeDownloadedChunk(data: Data, chunkIndex: Int) {
        chunkAudioByIndex[chunkIndex] = data
        if chunkIndex > lastReceivedChunkIndex {
            lastReceivedChunkIndex = chunkIndex
        }
        NSLog("Podcast: cached chunk \(chunkIndex) (\(chunkAudioByIndex.count)/\(totalChunks))")
        delegate?.podcastDidUpdateCacheStatus(canExport: hasAllChunksCached, hasAny: hasAnyChunkCached)

        // If we're buffering for this chunk, play it now.
        if !isPaused && !isPlayingInterruptResponse && (state == .buffering || (player?.isPlaying != true && state != .listening && state != .processingInterrupt && state != .idle)) {
            let needed = nextChunkToPlay()
            if chunkIndex == needed {
                startPlayingChunk(chunkIndex)
            }
        }
    }

    /// Index of the chunk that should play next based on currentChunkIndex
    /// and whether a player is currently active.
    private func nextChunkToPlay() -> Int {
        if player != nil {
            return currentChunkIndex + 1
        }
        // No player yet — either session just started or resumed after drain.
        return currentChunkIndex
    }

    /// Begin playback of an already-downloaded chunk. Updates state, transcript,
    /// line-advancement timers, and appends to audioSegments for export.
    private func startPlayingChunk(_ chunkIndex: Int) {
        guard let data = chunkAudioByIndex[chunkIndex] else {
            NSLog("Podcast: startPlayingChunk called for uncached chunk \(chunkIndex)")
            state = .buffering
            return
        }

        audioSegments.append(data)
        let lines = chunkTranscriptByIndex[chunkIndex] ?? []

        if !lines.isEmpty {
            transcript.append(contentsOf: lines)
            currentChunkLines = lines
            delegate?.podcastDidUpdateTranscript(transcript)
        }

        if isPaused {
            NSLog("Podcast: queuing chunk \(chunkIndex) (paused)")
            pendingPlayData = (data: data, chunkIndex: chunkIndex)
            currentChunkIndex = chunkIndex
            delegate?.podcastDidUpdateChunkProgress(current: chunkIndex + 1, total: totalChunks)
            return
        }

        do {
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

            currentChunkIndex = chunkIndex
            delegate?.podcastDidUpdateChunkProgress(current: chunkIndex + 1, total: totalChunks)
            sendChunkPlayed(chunkIndex)

            scheduleLineAdvancement(duration: player?.duration ?? 0, hasPrependedSilence: chunkIndex == 0)
        } catch {
            NSLog("Podcast: playback error for chunk \(chunkIndex): \(error)")
            state = .error("Playback failed")
            delegate?.podcastDidError("Audio playback failed")
        }
    }

    /// Play an ad-hoc data blob that isn't a numbered chunk — used for interrupt
    /// responses. Still appended to audioSegments so export preserves order.
    private func playInterruptResponse(data: Data) {
        audioSegments.append(data)

        if isPaused {
            NSLog("Podcast: queuing interrupt response (paused)")
            pendingPlayData = (data: data, chunkIndex: -1)
            return
        }

        do {
            player = try AVAudioPlayer(data: data)
            player?.delegate = self
            player?.prepareToPlay()
            player?.play()
            state = .playing
            updateNowPlaying()
            scheduleLineAdvancement(duration: player?.duration ?? 0, hasPrependedSilence: false)
        } catch {
            NSLog("Podcast: interrupt playback error: \(error)")
            state = .error("Playback failed")
            delegate?.podcastDidError("Audio playback failed")
        }
    }

    private func sendChunkPlayed(_ chunkIndex: Int) {
        guard let sessionId = sessionId else { return }
        sendJSON([
            "type": "CHUNK_PLAYED",
            "session_id": sessionId,
            "chunk_index": chunkIndex,
        ])
    }

    /// Download the interrupt-response audio (not part of the numbered chunk
    /// stream) and play it inline. On failure, drops back to buffering so the
    /// eager streamer can deliver the revised next chunk.
    private func downloadAndPlayInterruptResponse(audioURL: String) {
        guard let url = resolveAudioURL(audioURL) else {
            NSLog("Podcast: invalid interrupt audio URL: \(audioURL)")
            return
        }
        state = .buffering
        delegate?.podcastDidUpdateProgress(stage: "download", percent: -1, message: "Downloading response...")
        let generation = downloadGeneration

        Task {
            do {
                let (data, _) = try await urlSession.data(from: url)
                await MainActor.run {
                    guard self.downloadGeneration == generation else {
                        NSLog("Podcast: discarding stale interrupt download")
                        return
                    }
                    self.playInterruptResponse(data: data)
                }
            } catch {
                await MainActor.run {
                    guard self.downloadGeneration == generation else { return }
                    NSLog("Podcast: interrupt response download failed: \(error)")
                    self.isPlayingInterruptResponse = false
                    self.state = .buffering
                }
            }
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

    /// Request the server eagerly stream all chunks from `fromIndex` onward.
    /// The server will push CHUNK_READY for each chunk as audio is generated.
    private func requestStreamChunks(from fromIndex: Int) {
        guard let sessionId = sessionId else { return }
        sendJSON([
            "type": "STREAM_CHUNKS",
            "session_id": sessionId,
            "from_index": fromIndex,
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

        // Interrupt response finished — resume the podcast from the chunk
        // after the interrupt point. If the server has already re-streamed
        // the revised chunks they're in our cache; otherwise buffer.
        if isPlayingInterruptResponse {
            isPlayingInterruptResponse = false
            NSLog("Podcast: interrupt response finished, advancing to next chunk")
            advanceAfterPlayback()
            return
        }

        guard isSessionActive || state == .disconnected else { return }

        NSLog("Podcast: chunk \(currentChunkIndex) finished playing")
        advanceAfterPlayback()
    }

    /// Shared "a chunk/interrupt just finished" handler — picks the next chunk
    /// from cache, buffers if missing, or completes if at end of script.
    private func advanceAfterPlayback() {
        let next = currentChunkIndex + 1

        if next >= totalChunks {
            NSLog("Podcast: all chunks played, session complete")
            state = .complete
            updateNowPlaying(paused: true)
            return
        }

        if chunkAudioByIndex[next] != nil {
            startPlayingChunk(next)
            return
        }

        // Cache miss — could be a slow network / still-generating on server
        // or a disconnected state. If disconnected, stay that way; otherwise
        // fall through to buffering.
        if state == .disconnected {
            NSLog("Podcast: chunk \(next) not cached and disconnected — staying in .disconnected")
        } else {
            NSLog("Podcast: chunk \(next) not yet cached — buffering")
            state = .buffering
        }
    }

    // MARK: - Audio Export

    /// Combine all collected audio segments into a single WAV file.
    /// Uses AVAudioFile to decode any format (WAV, FLAC, etc.) to PCM.
    ///
    /// Selection logic:
    ///  - If playback-order audio (`audioSegments`) has at least as many
    ///    entries as `totalChunks`, use it — preserves inline interrupt responses.
    ///  - Otherwise fall back to `chunkAudioByIndex` in chunk order. This is
    ///    the path taken when the user exports a podcast they downloaded but
    ///    never fully played through (e.g. cached offline on disconnect).
    func combinedAudioData() -> Data? {
        let segments: [Data]
        if totalChunks > 0 && audioSegments.count >= totalChunks {
            segments = audioSegments
        } else if !chunkAudioByIndex.isEmpty {
            segments = chunkAudioByIndex.keys.sorted().compactMap { chunkAudioByIndex[$0] }
        } else {
            segments = audioSegments
        }
        guard !segments.isEmpty else { return nil }

        // Single segment — return as-is
        if segments.count == 1 { return segments[0] }

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("podcast_export_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Decode each segment to float32 PCM buffers using AVAudioFile
        var pcmBuffers: [AVAudioPCMBuffer] = []
        var processingFormat: AVAudioFormat?

        for (i, segment) in segments.enumerated() {
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
        removeEscapeMonitor()
        cancelReconnect()
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
        chunkAudioByIndex = [:]
        chunkTranscriptByIndex = [:]
        lastReceivedChunkIndex = -1
        chunkDownloadGeneration &+= 1

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

