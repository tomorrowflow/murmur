import Foundation
import AppKit
import CoreGraphics

/// Pauses / resumes whichever app currently owns macOS "Now Playing" — Spotify,
/// Music, Podcasts, browser-hosted media (YouTube, Netflix), anything that
/// registers with the system. Independent of audio output device — works the
/// same with built-in speakers, AirPods, USB headsets, etc., because the
/// scope is the Now Playing app, not the audio path.
///
/// Two native macOS APIs in use:
///   - **MediaRemote.framework (read side)**: `MRMediaRemoteGetNowPlayingApplicationIsPlaying`
///     and the `…IsPlayingDidChange` notification — both still functional on
///     macOS 15+. Used to snapshot state before pausing and to drive a
///     watchdog that re-pauses if a player wakes itself back up mid-session
///     (BT routing changes, etc.).
///   - **CGEvent (write side)**: post a system-defined media key event for
///     F8 (NX_KEYTYPE_PLAY). macOS dispatches this to the active Now
///     Playing client, so it works system-wide. Uses the Accessibility
///     permission Murmur already requires for paste; if the user also
///     grants Input Monitoring the path is even more reliable, but
///     Accessibility alone is usually enough.
///
/// `MRMediaRemoteSendCommand` is intentionally **not** used — Apple gated it
/// on macOS 15.4+ and the function call silently no-ops for third parties.
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
    /// resumes during recording.
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

    /// Constants from <IOKit/hidsystem/ev_keymap.h>. Pulled in by value so
    /// we don't have to drag in the full IOKit umbrella header.
    private static let nxSubtypeAuxControlButtons: Int16 = 8
    private static let nxKeyTypePlay: Int = 16
    private static let nxKeyDown: Int = 0xA
    private static let nxKeyUp: Int = 0xB
    /// Modifier-flags value the system uses on synthetic media-key events.
    private static let mediaKeyModifierFlags: NSEvent.ModifierFlags = NSEvent.ModifierFlags(rawValue: 0xA00)

    private init() {
        let url = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, url as CFURL),
              CFBundleLoadExecutable(bundle) else {
            NSLog("MediaRemoteController: failed to load MediaRemote framework")
            self.isPlaying = nil
            self.registerNotifications = nil
            return
        }
        if let isPlayingPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString) {
            self.isPlaying = unsafeBitCast(isPlayingPtr, to: IsPlayingFn.self)
        } else {
            NSLog("MediaRemoteController: MRMediaRemoteGetNowPlayingApplicationIsPlaying missing — pause cannot be state-aware")
            self.isPlaying = nil
        }
        if let regPtr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteRegisterForNowPlayingNotifications" as CFString) {
            let fn = unsafeBitCast(regPtr, to: RegisterNotificationsFn.self)
            self.registerNotifications = fn
            fn(.main)
            NotificationCenter.default.addObserver(
                forName: Self.isPlayingChangedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleIsPlayingChanged()
            }
        } else {
            NSLog("MediaRemoteController: MRMediaRemoteRegisterForNowPlayingNotifications missing — spurious-resume watchdog disabled")
            self.registerNotifications = nil
        }
    }

    // MARK: - Public API

    /// Pause whatever is playing — only if Now Playing reports something
    /// is *actually* playing right now. If the user already had their media
    /// paused (or nothing is registered as playing), this is a no-op and
    /// `didPause` stays false. Idempotent while already paused-by-us.
    /// Cancels any pending debounced resume.
    ///
    /// `completion` runs on main once the snapshot + pause decision is
    /// resolved. Callers that need to wait (e.g. defer audio-engine
    /// startup) should pass one; fire-and-forget callers can omit it.
    func pause(completion: (() -> Void)? = nil) {
        pendingResume?.cancel()
        pendingResume = nil
        guard !didPause else {
            completion?()
            return
        }
        guard let isPlaying = isPlaying else {
            // No state-query API → blind toggle.
            sendPlayPauseToggle()
            didPause = true
            NSLog("MediaRemoteController: sent play/pause toggle (state unknown)")
            completion?()
            return
        }
        isPlaying(.main) { [weak self] playing in
            guard let self = self else {
                completion?()
                return
            }
            guard playing else {
                NSLog("MediaRemoteController: nothing playing — skipping pause")
                completion?()
                return
            }
            guard !self.didPause else {
                completion?()
                return
            }
            self.sendPlayPauseToggle()
            self.didPause = true
            NSLog("MediaRemoteController: paused active media via media-key")
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
            // Verify state before toggling. If the user manually resumed
            // during our paused window, isPlaying will report true and
            // sending the toggle would *pause* them again. Skip in that case.
            if let isPlaying = self.isPlaying {
                isPlaying(.main) { [weak self] playing in
                    guard let self = self else { return }
                    if playing {
                        NSLog("MediaRemoteController: media already playing — skip resume toggle")
                        return
                    }
                    self.sendPlayPauseToggle()
                    NSLog("MediaRemoteController: resumed media we paused via media-key")
                }
            } else {
                self.sendPlayPauseToggle()
                NSLog("MediaRemoteController: resumed media we paused (state unknown)")
            }
        }
        pendingResume = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resumeDebounce, execute: work)
    }

    // MARK: - Internals

    private func handleIsPlayingChanged() {
        // Only act when we're holding a pause we issued. If state flipped to
        // playing while we believe media should be silenced, re-pause without
        // touching didPause.
        guard didPause else { return }
        guard let isPlaying = isPlaying else { return }
        isPlaying(.main) { [weak self] playing in
            guard let self = self, self.didPause, playing else { return }
            self.sendPlayPauseToggle()
            NSLog("MediaRemoteController: spurious resume detected — re-paused via media-key")
        }
    }

    /// Synthesize an F8 (NX_KEYTYPE_PLAY) media-key press via the system-
    /// defined NSEvent path, then post via CGEvent. macOS dispatches the
    /// resulting media key to whichever app currently owns Now Playing —
    /// works for native media apps and browser-embedded video alike,
    /// regardless of audio output device. Requires Accessibility (which
    /// Murmur already has for paste); on macOS 15+ also requires Input
    /// Monitoring to actually deliver the synthesized event to other
    /// processes.
    private func sendPlayPauseToggle() {
        let now = Date()
        if now.timeIntervalSince(lastMediaKeyAt) < Self.mediaKeyMinInterval {
            return
        }
        lastMediaKeyAt = now
        NSLog("MediaRemoteController: posting F8 media-key (down + up)")
        postMediaKey(keyState: Self.nxKeyDown)
        postMediaKey(keyState: Self.nxKeyUp)
        // Verify the toggle actually moved state. If isPlaying is unchanged
        // after a short delay, the system filtered the event — most likely
        // Input Monitoring not granted.
        if let isPlaying = isPlaying {
            let beforeDidPause = didPause
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isPlaying(.main) { playing in
                    let expectedPlaying = !beforeDidPause
                    if playing != expectedPlaying {
                        NSLog("MediaRemoteController: WARNING — media-key did not change playback (state still playing=\(playing)). Likely missing Input Monitoring permission for Murmur in System Settings → Privacy & Security → Input Monitoring.")
                    } else {
                        NSLog("MediaRemoteController: media-key delivered (playing=\(playing))")
                    }
                }
            }
        }
    }

    private func postMediaKey(keyState: Int) {
        let data1 = (Self.nxKeyTypePlay << 16) | (keyState << 8)
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: NSPoint.zero,
            modifierFlags: Self.mediaKeyModifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: Self.nxSubtypeAuxControlButtons,
            data1: data1,
            data2: -1
        ) else {
            NSLog("MediaRemoteController: failed to construct system-defined event")
            return
        }
        guard let cgEvent = event.cgEvent else {
            NSLog("MediaRemoteController: NSEvent has no underlying CGEvent")
            return
        }
        // Post via two taps to maximize chance of delivery — different tap
        // points are filtered differently across macOS versions, and the
        // Now Playing dispatch listens at the HID level on most versions.
        cgEvent.post(tap: .cghidEventTap)
        cgEvent.post(tap: .cgAnnotatedSessionEventTap)
    }
}
