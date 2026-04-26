import Foundation

/// Pauses / resumes whichever app currently owns macOS "Now Playing" — Spotify,
/// Music, Podcasts, browser media, anything that registers with the system.
/// Uses Apple's private MediaRemote framework via dlsym so we don't ship an
/// AppleScript per supported app. The framework is private but de-facto stable
/// across macOS versions for years (Apple's own Now Playing widget uses it,
/// and it's relied on by many third-party menu bar apps).
final class MediaRemoteController {
    static let shared = MediaRemoteController()

    private typealias SendCommandFn = @convention(c) (Int, AnyObject?) -> Bool
    /// MRMediaRemoteGetNowPlayingApplicationIsPlaying signature:
    /// (DispatchQueue, completion(Bool)) — completion fires asynchronously
    /// with the current "is playing" state from the Now Playing system.
    private typealias IsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void

    /// Command IDs used by MRMediaRemoteSendCommand.
    private enum Command: Int {
        case play = 0
        case pause = 1
    }

    private let sendCommand: SendCommandFn?
    private let isPlaying: IsPlayingFn?
    /// Tracks whether *we* paused playback so we don't resume something the
    /// user paused themselves.
    private var didPause = false
    /// Pending resume work item — held briefly so a fresh `pause()` call
    /// during the recap chain (TTS end → auto-record start) cancels the
    /// resume and keeps music paused through the whole sequence.
    private var pendingResume: DispatchWorkItem?
    /// Window during which a follow-up pause cancels the resume. Long
    /// enough to bridge TTS-stop → STT-engine-start including the BT
    /// warmup, short enough that a true session end resumes promptly.
    private static let resumeDebounce: TimeInterval = 1.2

    private init() {
        let url = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, url as CFURL),
              CFBundleLoadExecutable(bundle) else {
            print("MediaRemoteController: failed to load MediaRemote framework")
            self.sendCommand = nil
            self.isPlaying = nil
            return
        }
        guard let sendPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) else {
            print("MediaRemoteController: MRMediaRemoteSendCommand symbol missing")
            self.sendCommand = nil
            self.isPlaying = nil
            return
        }
        self.sendCommand = unsafeBitCast(sendPtr, to: SendCommandFn.self)
        if let isPlayingPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString) {
            self.isPlaying = unsafeBitCast(isPlayingPtr, to: IsPlayingFn.self)
        } else {
            // Symbol missing on this macOS — degrade gracefully. Pause will
            // still work, but we can't tell if media is already paused.
            print("MediaRemoteController: MRMediaRemoteGetNowPlayingApplicationIsPlaying missing — pre-pause state check disabled")
            self.isPlaying = nil
        }
    }

    /// Pause whatever is playing — but only if Now Playing reports something
    /// is *actually* playing right now. If the user already had their media
    /// paused (or nothing is registered as playing), this is a no-op and
    /// `didPause` stays false, so a later resume won't unpause something the
    /// user wanted paused. Idempotent while already paused-by-us. Cancels any
    /// pending debounced resume so the recap chain stays muted throughout.
    func pause() {
        pendingResume?.cancel()
        pendingResume = nil
        guard let send = sendCommand else { return }
        guard !didPause else { return }
        // No state-query API available on this macOS — fall back to blind
        // pause. (Older behavior; better than nothing.)
        guard let isPlaying = isPlaying else {
            let ok = send(Command.pause.rawValue, nil)
            if ok {
                didPause = true
                print("MediaRemoteController: paused active media (state unknown)")
            }
            return
        }
        // State query is async; only commit the pause if Now Playing confirms
        // something is currently playing.
        isPlaying(.main) { [weak self] playing in
            guard let self = self else { return }
            guard playing else {
                print("MediaRemoteController: nothing playing — skipping pause")
                return
            }
            // Re-check in case we got paused-by-us in the interim.
            guard !self.didPause else { return }
            let ok = send(Command.pause.rawValue, nil)
            if ok {
                self.didPause = true
                print("MediaRemoteController: paused active media")
            }
        }
    }

    /// Schedule a resume, debounced. If a fresh `pause()` arrives within
    /// `resumeDebounce` it cancels the scheduled resume and the music stays
    /// paused. No-op if we never paused.
    func resumeIfWePaused() {
        guard sendCommand != nil else { return }
        guard didPause else { return }
        pendingResume?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.didPause, let send = self.sendCommand else { return }
            self.didPause = false
            self.pendingResume = nil
            _ = send(Command.play.rawValue, nil)
            print("MediaRemoteController: resumed media we paused")
        }
        pendingResume = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resumeDebounce, execute: work)
    }
}
