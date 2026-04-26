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
    private typealias RegisterNotificationsFn = @convention(c) (DispatchQueue) -> Void

    /// Command IDs used by MRMediaRemoteSendCommand.
    private enum Command: Int {
        case play = 0
        case pause = 1
    }

    private let sendCommand: SendCommandFn?
    private let isPlaying: IsPlayingFn?
    private let registerNotifications: RegisterNotificationsFn?
    /// Notification name posted by MediaRemote when the active app's
    /// playback state flips. We use it to catch spurious resumes during
    /// recording (BT routing changes can wake the video player back up).
    private static let isPlayingChangedNotification = Notification.Name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification")
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
            self.registerNotifications = nil
            return
        }
        guard let sendPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) else {
            print("MediaRemoteController: MRMediaRemoteSendCommand symbol missing")
            self.sendCommand = nil
            self.isPlaying = nil
            self.registerNotifications = nil
            return
        }
        self.sendCommand = unsafeBitCast(sendPtr, to: SendCommandFn.self)
        if let isPlayingPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString) {
            self.isPlaying = unsafeBitCast(isPlayingPtr, to: IsPlayingFn.self)
        } else {
            print("MediaRemoteController: MRMediaRemoteGetNowPlayingApplicationIsPlaying missing — pre-pause state check disabled")
            self.isPlaying = nil
        }
        if let regPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString) {
            let fn = unsafeBitCast(regPtr, to: RegisterNotificationsFn.self)
            self.registerNotifications = fn
            // Activate notification stream + subscribe to the playing-state
            // change notification. The watchdog re-pauses if a video / song
            // wakes itself back up during a recording (BT routing changes
            // can do this on macOS).
            fn(.main)
            NotificationCenter.default.addObserver(
                forName: Self.isPlayingChangedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleIsPlayingChanged()
            }
        } else {
            print("MediaRemoteController: MRMediaRemoteRegisterForNowPlayingNotifications missing — spurious-resume watchdog disabled")
            self.registerNotifications = nil
        }
    }

    private func handleIsPlayingChanged() {
        // Only act when we're holding a pause we actually issued. If state
        // flipped to playing while we believe media should be silenced,
        // re-pause without altering didPause.
        guard didPause else { return }
        guard let isPlaying = isPlaying, let send = sendCommand else { return }
        isPlaying(.main) { [weak self] playing in
            guard let self = self, self.didPause, playing else { return }
            _ = send(Command.pause.rawValue, nil)
            print("MediaRemoteController: spurious resume detected — re-paused")
        }
    }

    /// Pause whatever is playing — but only if Now Playing reports something
    /// is *actually* playing right now. If the user already had their media
    /// paused (or nothing is registered as playing), this is a no-op and
    /// `didPause` stays false, so a later resume won't unpause something the
    /// user wanted paused. Idempotent while already paused-by-us. Cancels any
    /// pending debounced resume so the recap chain stays muted throughout.
    ///
    /// `completion` runs on main once the snapshot + pause decision is
    /// resolved. Callers that need to wait (e.g. defer an audio-engine
    /// startup that would disrupt Now Playing routing) should pass one;
    /// fire-and-forget callers can omit it.
    func pause(completion: (() -> Void)? = nil) {
        pendingResume?.cancel()
        pendingResume = nil
        guard let send = sendCommand else {
            completion?()
            return
        }
        guard !didPause else {
            completion?()
            return
        }
        // No state-query API available on this macOS — fall back to blind
        // pause. (Older behavior; better than nothing.)
        guard let isPlaying = isPlaying else {
            let ok = send(Command.pause.rawValue, nil)
            if ok {
                didPause = true
                print("MediaRemoteController: paused active media (state unknown)")
            }
            completion?()
            return
        }
        // State query is async; only commit the pause if Now Playing confirms
        // something is currently playing.
        isPlaying(.main) { [weak self] playing in
            guard let self = self else {
                completion?()
                return
            }
            guard playing else {
                print("MediaRemoteController: nothing playing — skipping pause")
                completion?()
                return
            }
            guard !self.didPause else {
                completion?()
                return
            }
            let ok = send(Command.pause.rawValue, nil)
            if ok {
                self.didPause = true
                print("MediaRemoteController: paused active media")
            }
            completion?()
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
