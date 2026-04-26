import Foundation
import AppKit

/// Pauses / resumes whichever app currently owns macOS "Now Playing" — Spotify,
/// Music, Podcasts, browser-hosted media (YouTube, Netflix), anything that
/// registers with the system. Independent of audio output device — works the
/// same with built-in speakers, AirPods, USB headsets, etc.
///
/// Implementation note: we read playback state via the private MediaRemote
/// framework (`MRMediaRemoteGetNowPlayingApplicationIsPlaying` and the
/// matching change notification — both still functional on macOS 15+).
/// For *issuing* play/pause we drive the F8 media key through System Events
/// via NSAppleScript:
///   - `MRMediaRemoteSendCommand` is silently dropped on macOS 15.4+
///     (Apple gated it behind an entitlement third-party apps can't get).
///   - Synthesized `CGEvent` media-key posts are filtered unless the app
///     holds Input Monitoring entitlement, which macOS doesn't grant
///     interactively.
///   - System Events is system-blessed and routes the F8 to whichever app
///     owns Now Playing. macOS prompts once for Automation permission for
///     "System Events" the first time we run.
final class MediaRemoteController {
    static let shared = MediaRemoteController()

    /// MRMediaRemoteGetNowPlayingApplicationIsPlaying signature:
    /// (DispatchQueue, completion(Bool)) — fires asynchronously with the
    /// current "is playing" state from the Now Playing system.
    private typealias IsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias RegisterNotificationsFn = @convention(c) (DispatchQueue) -> Void

    private let isPlaying: IsPlayingFn?
    private let registerNotifications: RegisterNotificationsFn?

    /// Notification name posted by MediaRemote when the active app's
    /// playback state flips. Used by the watchdog to catch spurious
    /// resumes during recording (BT routing changes can wake players).
    private static let isPlayingChangedNotification = Notification.Name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification")

    /// Tracks whether *we* paused playback so we don't resume something the
    /// user paused themselves.
    private var didPause = false

    /// Pending resume work item — held briefly so a fresh `pause()` call
    /// during the recap chain (TTS end → STT start) cancels the resume and
    /// keeps music paused throughout.
    private var pendingResume: DispatchWorkItem?

    /// Debounce window for resume. Long enough to bridge TTS-stop →
    /// STT-engine-start including the BT warmup, short enough that a true
    /// session end resumes promptly.
    private static let resumeDebounce: TimeInterval = 1.2

    /// Minimum gap between media-key sends; prevents the watchdog from
    /// hammering the system if state oscillates rapidly during BT switches.
    private static let mediaKeyMinInterval: TimeInterval = 0.4
    private var lastMediaKeyAt: Date = .distantPast

    /// Source for the System Events F8 (play/pause) keypress. Compiled
    /// fresh per invocation on the background queue we execute on —
    /// NSAppleScript is not thread-safe.
    private static let playPauseScriptSource = "tell application \"System Events\" to key code 100"

    private init() {
        let url = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, url as CFURL),
              CFBundleLoadExecutable(bundle) else {
            print("MediaRemoteController: failed to load MediaRemote framework")
            self.isPlaying = nil
            self.registerNotifications = nil
            return
        }
        if let isPlayingPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString) {
            self.isPlaying = unsafeBitCast(isPlayingPtr, to: IsPlayingFn.self)
        } else {
            print("MediaRemoteController: MRMediaRemoteGetNowPlayingApplicationIsPlaying missing — pause cannot be state-aware")
            self.isPlaying = nil
        }
        if let regPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString) {
            let fn = unsafeBitCast(regPtr, to: RegisterNotificationsFn.self)
            self.registerNotifications = fn
            // Activate the notification stream so we receive playback-state
            // change notifications, then subscribe via NSNotificationCenter.
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

    // MARK: - Public API

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
        guard !didPause else {
            completion?()
            return
        }
        // No state-query API → blind toggle. Best effort.
        guard let isPlaying = isPlaying else {
            sendPlayPauseToggle()
            didPause = true
            print("MediaRemoteController: sent play/pause toggle (state unknown)")
            completion?()
            return
        }
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
            self.sendPlayPauseToggle()
            self.didPause = true
            print("MediaRemoteController: paused active media via media-key")
            completion?()
        }
    }

    /// Schedule a resume, debounced. If a fresh `pause()` arrives within
    /// `resumeDebounce` it cancels the scheduled resume and the music stays
    /// paused. No-op if we never paused.
    func resumeIfWePaused() {
        guard didPause else { return }
        pendingResume?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.didPause else { return }
            self.didPause = false
            self.pendingResume = nil
            // Verify state before toggling. If the user already manually
            // resumed during our paused window, isPlaying will be true and
            // sending the toggle would *pause* them again. Skip in that case.
            if let isPlaying = self.isPlaying {
                isPlaying(.main) { [weak self] playing in
                    guard let self = self else { return }
                    if playing {
                        print("MediaRemoteController: media already playing — skip resume toggle")
                        return
                    }
                    self.sendPlayPauseToggle()
                    print("MediaRemoteController: resumed media we paused via media-key")
                }
            } else {
                self.sendPlayPauseToggle()
                print("MediaRemoteController: resumed media we paused (state unknown)")
            }
        }
        pendingResume = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resumeDebounce, execute: work)
    }

    // MARK: - Internals

    private func handleIsPlayingChanged() {
        // Only act when we're holding a pause we issued. If state flipped to
        // playing while we believe media should be silenced, re-pause without
        // touching didPause. Throttled so we don't fight a rapid oscillation.
        guard didPause else { return }
        guard let isPlaying = isPlaying else { return }
        isPlaying(.main) { [weak self] playing in
            guard let self = self, self.didPause, playing else { return }
            self.sendPlayPauseToggle()
            print("MediaRemoteController: spurious resume detected — re-paused via media-key")
        }
    }

    /// Send an F8 (play/pause) keypress through System Events. macOS
    /// dispatches the resulting media key to whichever app currently owns
    /// Now Playing — works for native media apps and browser-embedded video
    /// alike, regardless of audio output device. Audio source (AirPods,
    /// built-in, USB) is irrelevant: this targets the Now Playing app, not
    /// the audio device.
    private func sendPlayPauseToggle() {
        let now = Date()
        if now.timeIntervalSince(lastMediaKeyAt) < Self.mediaKeyMinInterval {
            // Throttle: prevents the watchdog from spamming if Now Playing
            // state oscillates during a BT codec switch.
            return
        }
        lastMediaKeyAt = now
        // Compile + execute on a background queue so the System Events RPC
        // doesn't stall the main thread (especially the very first call,
        // which can pop a permission prompt). NSAppleScript is not
        // thread-safe, so we build a fresh instance on this queue.
        DispatchQueue.global(qos: .userInitiated).async {
            guard let script = NSAppleScript(source: Self.playPauseScriptSource) else {
                print("MediaRemoteController: AppleScript compile failed")
                return
            }
            var errorInfo: NSDictionary?
            script.executeAndReturnError(&errorInfo)
            if let errorInfo = errorInfo {
                let msg = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown"
                let num = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
                print("MediaRemoteController: F8 via System Events failed (\(num)): \(msg)")
                if num == -1743 {
                    print("MediaRemoteController: grant Murmur Automation access for System Events in System Settings → Privacy & Security → Automation")
                }
            }
        }
    }
}
