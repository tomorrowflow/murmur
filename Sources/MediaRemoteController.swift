import Foundation
import AppKit
import CoreAudio
import os.log

/// Pauses / resumes whichever app currently owns macOS "Now Playing" — Spotify,
/// Apple Music, Apple Podcasts, Apple TV, anything that registers with the
/// system. Independent of audio output device — works the same with built-in
/// speakers, AirPods, USB headsets, etc., because the scope is the Now Playing
/// app, not the audio path.
///
/// Uses `MRMediaRemoteSendCommand` from MediaRemote.framework via dlsym.
/// Confirmed working on this user's macOS 26.4.1 Tahoe build (2026-04-27)
/// for Spotify and Safari/YouTube; some browsers (Brave) don't register
/// with Now Playing, in which case nothing pauses — that's a limitation
/// of those apps, not Murmur.
///
/// Distinct Pause (1) and Play (0) commands are used instead of the F8 toggle
/// — Pause is idempotent (no-op on already-paused media), so we can't
/// accidentally start something the user had paused.
///
/// The dangerous command is Play: when *no* app owns Now Playing, macOS
/// answers a bare Play by launching the default player (Apple Music). Every
/// guard in this class exists to make sure Play is only ever sent to an app
/// we actually paused and that is still running.
final class MediaRemoteController {
    static let shared = MediaRemoteController()

    /// os_log handle visible by default — NSLog/print from third-party apps
    /// gets redacted to `<private>` in Console. Filter on subsystem
    /// `com.murmur.app` and category `MediaRemote` to see these lines.
    private static let log = OSLog(subsystem: "com.murmur.app", category: "MediaRemote")

    private static func info(_ msg: String) {
        os_log("%{public}@", log: log, type: .info, msg)
    }

    /// MRMediaRemoteSendCommand(commandID, userInfo) → Bool. Confirmed live
    /// on Tahoe for Spotify + Safari. Returns true even when the system
    /// drops it (older speculation that it was gated turned out to be
    /// incomplete on this build).
    private typealias SendCommandFn = @convention(c) (Int, AnyObject?) -> Bool

    /// Command IDs accepted by MRMediaRemoteSendCommand.
    private enum Command: Int {
        case play = 0
        case pause = 1
        // case togglePlayPause = 2 — kept here for reference but unused;
        // explicit Play/Pause keeps Pause idempotent.
    }

    private let sendCommand: SendCommandFn?

    /// A media player process we found producing output.
    private struct ActivePlayer {
        let pid: pid_t
        let bundleID: String
    }

    // All mutable state below is guarded by `lock`. `pause()` is called from
    // the cooperative thread pool (Read Aloud / Draft Editing playback tasks)
    // as well as from main (podcast, STT gate), and `resumeIfWePaused()` from
    // main — without the lock the two race on `didPause`.
    private let lock = NSLock()

    /// Tracks whether *we* paused playback so we resume only what we
    /// stopped. Note: on macOS 26 the read APIs (`IsPlaying`, `GetInfo`)
    /// are gated for third-party apps, so we can't pre-check whether
    /// something was actually playing. We trust the CoreAudio per-process
    /// "is running output" flag of a known media player instead.
    private var didPause = false

    /// The player we sent Pause to. Resume only fires if this process is
    /// still alive — if it quit, nothing owns Now Playing and Play would
    /// launch Apple Music.
    private var pausedPlayer: ActivePlayer?

    /// Pending resume work item — held briefly so a fresh `pause()` call
    /// during the recap chain (TTS end → STT start) cancels the resume
    /// and keeps media paused throughout.
    private var pendingResume: DispatchWorkItem?

    /// Debounce window for resume. Long enough to bridge TTS-stop →
    /// STT-engine-start including the BT warmup, short enough that a true
    /// session end resumes promptly.
    private static let resumeDebounce: TimeInterval = 1.2

    private init() {
        let url = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, url as CFURL),
              CFBundleLoadExecutable(bundle) else {
            Self.info("failed to load MediaRemote.framework")
            self.sendCommand = nil
            return
        }
        guard let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) else {
            Self.info("MRMediaRemoteSendCommand symbol missing")
            self.sendCommand = nil
            return
        }
        self.sendCommand = unsafeBitCast(ptr, to: SendCommandFn.self)
        Self.info("MRMediaRemoteSendCommand loaded")
    }

    // MARK: - Active-playback detection (CoreAudio per-process API)

    /// FourCC selectors from <CoreAudio/AudioHardware.h> (macOS 14.2+).
    /// Hardcoded because the Swift CoreAudio module-map exposure of these
    /// constants varies across SDK versions.
    private static let prsListSelector: AudioObjectPropertySelector = fourCC("prs#")
    private static let isRunningOutputSelector: AudioObjectPropertySelector = fourCC("piro")
    private static let bundleIDSelector: AudioObjectPropertySelector = fourCC("pbid")
    private static let pidSelector: AudioObjectPropertySelector = fourCC("ppid")

    private static func fourCC(_ s: StaticString) -> AudioObjectPropertySelector {
        precondition(s.utf8CodeUnitCount == 4)
        return s.withUTF8Buffer { buf in
            (UInt32(buf[0]) << 24) | (UInt32(buf[1]) << 16) | (UInt32(buf[2]) << 8) | UInt32(buf[3])
        }
    }

    /// Native media players that register with Now Playing and close their
    /// output stream while paused, so "IsRunningOutput" genuinely means
    /// "playing". Only a process from this set (plus the user extension
    /// below) is ever paused.
    ///
    /// This used to be the inverse — a denylist of browsers / conferencing
    /// helpers, with every *other* process that had output running treated
    /// as a media player. That is what kept launching Apple Music: any app
    /// emitting a notification chime during a TTS session (mail client,
    /// chat app, terminal bell) read as a player, `didPause` was set with
    /// nothing actually paused, and the session-end Play landed on an empty
    /// Now Playing. An unknown process is now simply left alone.
    private static let knownMediaPlayerBundleIDs: Set<String> = [
        "com.spotify.client",
        "com.apple.Music",
        "com.apple.iTunes",
        "com.apple.podcasts",
        "com.apple.TV",
        "com.apple.Books",
        "com.apple.QuickTimePlayerX",
        "org.videolan.vlc",
        "com.colliderli.iina",
        "io.mpv",
        "tv.plex.plexamp",
        "tv.plex.desktop",
        "com.tidal.desktop",
        "com.deezer.deezer-desktop",
        "com.amazon.music",
        "com.swinsian.Swinsian",
        "com.audirvana.Audirvana-Studio",
        "org.foobar2000.foobar2000",
    ]

    /// Bundle IDs the user can add without a rebuild:
    /// `defaults write com.murmur.app audio.mediaPlayerBundleIDs -array com.example.player`
    static let userMediaPlayersDefaultsKey = "audio.mediaPlayerBundleIDs"

    private static func isKnownMediaPlayer(_ bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        if knownMediaPlayerBundleIDs.contains(bundleID) { return true }
        let extra = UserDefaults.standard.stringArray(forKey: userMediaPlayersDefaultsKey) ?? []
        return extra.contains(bundleID)
    }

    /// The first known media player that currently has `IsRunningOutput=true`,
    /// or nil when nothing pausable is playing. Processes that are not on
    /// the allowlist are logged once per call so a missing player can be
    /// spotted in Console and added via the defaults key.
    private static func activeMediaPlayer() -> ActivePlayer? {
        var listAddr = AudioObjectPropertyAddress(
            mSelector: prsListSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let s1 = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddr, 0, nil, &dataSize
        )
        guard s1 == noErr else {
            info("ProcessObjectList size query failed (\(s1)) — treating as 'nothing playing'")
            return nil
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        let s2 = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddr, 0, nil, &dataSize, &ids
        )
        guard s2 == noErr else {
            info("ProcessObjectList read failed (\(s2))")
            return nil
        }
        var ignored: [String] = []
        for objID in ids {
            guard let running = boolProp(objID, isRunningOutputSelector), running else { continue }
            let bundle = stringProp(objID, bundleIDSelector) ?? ""
            guard Self.isKnownMediaPlayer(bundle) else {
                ignored.append(bundle.isEmpty ? "<no bundle>" : bundle)
                continue
            }
            guard let pid = pidProp(objID) else {
                info("known media player \(bundle) has no pid — skipping")
                continue
            }
            info("active media player detected: \(bundle) (pid \(pid))")
            return ActivePlayer(pid: pid, bundleID: bundle)
        }
        if !ignored.isEmpty {
            info("output running but not a known media player, leaving alone: \(ignored.joined(separator: ", "))")
        }
        return nil
    }

    private static func boolProp(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> Bool? {
        var addr = AudioObjectPropertyAddress(
            mSelector: sel,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr else { return nil }
        return v != 0
    }

    private static func pidProp(_ id: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(
            mSelector: pidSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var v: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr, v > 0 else { return nil }
        return v
    }

    private static func stringProp(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: sel,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { raw in
                AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw)
            }
        }
        guard status == noErr, let cfStr = cfStr else { return nil }
        return cfStr.takeRetainedValue() as String
    }

    // MARK: - Public API

    /// Send Pause to whichever app owns Now Playing — but only if a known
    /// media player is currently producing audio. Without this guard we'd
    /// `Pause` against nothing, set `didPause=true`, and on resume blindly
    /// send `Play`, which starts (or launches) music the user never had
    /// running. Spotify/Music/Podcasts close their output stream when
    /// paused, so "running output" is a reliable "playing right now".
    ///
    /// Idempotent: repeated calls while already paused only cancel a pending
    /// resume (recap chain: TTS end → STT start keeps media paused).
    ///
    /// `completion` runs synchronously after the decision is made, outside
    /// the lock; callers that need to wait for an audio-engine startup can
    /// pass one.
    func pause(completion: (() -> Void)? = nil) {
        defer { completion?() }
        lock.lock()
        defer { lock.unlock() }

        pendingResume?.cancel()
        pendingResume = nil
        guard !didPause else { return }
        guard let send = sendCommand else {
            Self.info("MRMediaRemoteSendCommand unavailable — skipping pause")
            return
        }
        guard let player = Self.activeMediaPlayer() else {
            Self.info("no known media player active — skipping pause")
            return
        }
        let ok = send(Command.pause.rawValue, nil)
        didPause = true
        pausedPlayer = player
        Self.info("sent Pause(1) for \(player.bundleID), MRMediaRemoteSendCommand returned \(ok)")
    }

    /// Send Play to the app we paused — but only if we previously paused
    /// and that app is still running. Debounced; a fresh `pause()` within
    /// `resumeDebounce` cancels the scheduled resume and media stays
    /// paused. Safe to call from any session-end path, any thread.
    func resumeIfWePaused() {
        lock.lock()
        defer { lock.unlock() }
        guard didPause else { return }
        pendingResume?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performScheduledResume()
        }
        pendingResume = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resumeDebounce, execute: work)
    }

    private func performScheduledResume() {
        lock.lock()
        defer { lock.unlock() }
        guard didPause else { return }
        didPause = false
        pendingResume = nil
        let player = pausedPlayer
        pausedPlayer = nil

        guard let send = sendCommand else { return }
        guard let player = player else {
            Self.info("resume requested but no paused player recorded — skipping Play")
            return
        }
        // If the player quit while we held the pause, Now Playing has no
        // owner and a bare Play would launch the default player.
        guard let app = NSRunningApplication(processIdentifier: player.pid),
              !app.isTerminated,
              app.bundleIdentifier == player.bundleID else {
            Self.info("paused player \(player.bundleID) (pid \(player.pid)) is gone — skipping Play")
            return
        }
        let ok = send(Command.play.rawValue, nil)
        Self.info("sent Play(0) for \(player.bundleID), MRMediaRemoteSendCommand returned \(ok)")
    }
}
