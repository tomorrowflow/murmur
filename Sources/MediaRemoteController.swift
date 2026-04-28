import Foundation
import AppKit
import CoreAudio
import os.log

/// Pauses / resumes whichever app currently owns macOS "Now Playing" — Spotify,
/// Apple Music, Apple Podcasts, Safari (YouTube/Netflix), Apple TV, anything
/// that registers with the system. Independent of audio output device — works
/// the same with built-in speakers, AirPods, USB headsets, etc., because the
/// scope is the Now Playing app, not the audio path.
///
/// Uses `MRMediaRemoteSendCommand` from MediaRemote.framework via dlsym.
/// Confirmed working on this user's macOS 26.4.1 Tahoe build (2026-04-27)
/// for Spotify and Safari/YouTube; some browsers (Brave) don't register
/// with Now Playing, in which case nothing pauses — that's a limitation
/// of those apps, not Murmur.
///
/// Distinct Pause (1) and Play (0) commands are used instead of the F8 toggle
/// — Pause is idempotent (no-op on already-paused media), so we can't
/// accidentally start something the user had paused. The opposite case
/// remains: if media was paused before Murmur ran, our resume Play *will*
/// start it. Documented limitation.
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

    /// Tracks whether *we* paused playback so we resume only what we
    /// stopped. Note: on macOS 26 the read APIs (`IsPlaying`, `GetInfo`)
    /// are gated for third-party apps, so we can't pre-check whether
    /// something was actually playing. We trust the user's intent: if
    /// they triggered Murmur, they want the audio stage clear, and we'll
    /// restore on resume.
    private var didPause = false

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

    private static func fourCC(_ s: StaticString) -> AudioObjectPropertySelector {
        precondition(s.utf8CodeUnitCount == 4)
        return s.withUTF8Buffer { buf in
            (UInt32(buf[0]) << 24) | (UInt32(buf[1]) << 16) | (UInt32(buf[2]) << 8) | UInt32(buf[3])
        }
    }

    /// Bundle IDs that hold the audio output stream open even while the
    /// user has paused playback. Their presence in the
    /// `IsRunningOutput=true` list is uninformative — they're "always on"
    /// from CoreAudio's point of view. We exclude them from active-playback
    /// detection so we don't pause+set didPause when only a browser is
    /// nominally rendering.
    private static let streamHoardingBundleIDs: Set<String> = [
        "com.apple.WebKit.GPU",            // Safari (and embedded WebKit)
        "com.google.Chrome.helper",        // Chrome
        "com.google.Chrome.helper.plugin",
        "com.brave.Browser.helper",        // Brave
        "com.microsoft.edgemac.helper",    // Edge
        "org.mozilla.firefox",             // Firefox
        "com.apple.audio.coreaudiod",      // CoreAudio daemon (defensive)
        "com.murmur.app",                  // ourselves
    ]

    /// True iff at least one audio process *other than* a known stream-
    /// hoarder (Safari/Chrome/etc.) currently has IsRunningOutput=true.
    /// In other words: a real media player like Spotify or Apple Music is
    /// actively playing right now. Returns false if only browsers (or
    /// nothing) are running output — in that case we can't tell whether
    /// real playback is happening, so we treat it as "no playback" and
    /// skip the pause to avoid the spurious-resume bug.
    private static func anyMediaPlayerActive() -> Bool {
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
            info("ProcessObjectList size query failed (\(s1)) — falling back to 'unknown / skip'")
            return false
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        let s2 = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &listAddr, 0, nil, &dataSize, &ids
        )
        guard s2 == noErr else {
            info("ProcessObjectList read failed (\(s2))")
            return false
        }
        for objID in ids {
            guard let running = boolProp(objID, isRunningOutputSelector), running else { continue }
            let bundle = stringProp(objID, bundleIDSelector) ?? ""
            if streamHoardingBundleIDs.contains(bundle) { continue }
            info("active media player detected: \(bundle.isEmpty ? "<no bundle>" : bundle)")
            return true
        }
        return false
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

    /// Send Pause to whichever app owns Now Playing — but only if a real
    /// media player (not a stream-hoarding browser) is currently producing
    /// audio. Without this guard, we'd `Pause` against nothing, set
    /// `didPause=true`, and on resume blindly send `Play` — which would
    /// *start* music the user had paused before Murmur ran. The CoreAudio
    /// per-process check tells us whether something is actually playing
    /// right now (Spotify/Music/Podcasts properly close their output
    /// stream when paused). If detection comes back negative, we skip
    /// both the Pause and the `didPause` flag, so the resume Play stays
    /// dormant.
    ///
    /// `completion` runs synchronously after the decision is made;
    /// callers that need to wait for an audio-engine startup can pass one.
    func pause(completion: (() -> Void)? = nil) {
        pendingResume?.cancel()
        pendingResume = nil
        guard !didPause else {
            completion?()
            return
        }
        guard let send = sendCommand else {
            Self.info("MRMediaRemoteSendCommand unavailable — skipping pause")
            completion?()
            return
        }
        guard Self.anyMediaPlayerActive() else {
            Self.info("no real media player active — skipping pause")
            completion?()
            return
        }
        let ok = send(Command.pause.rawValue, nil)
        didPause = true
        Self.info("sent Pause(1), MRMediaRemoteSendCommand returned \(ok)")
        completion?()
    }

    /// Send Play to whichever app owns Now Playing — but only if we
    /// previously paused. Debounced; a fresh `pause()` within
    /// `resumeDebounce` cancels the scheduled resume and media stays
    /// paused.
    ///
    /// Limitation: if the user had media paused before Murmur ran, our
    /// pause was a no-op but `didPause` was still set; this Play will
    /// start the media. There's no reliable way to detect that case on
    /// macOS 26 (the read APIs are gated).
    func resumeIfWePaused() {
        guard didPause else { return }
        pendingResume?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.didPause else { return }
            guard let send = self.sendCommand else { return }
            self.didPause = false
            self.pendingResume = nil
            let ok = send(Command.play.rawValue, nil)
            Self.info("sent Play(0), MRMediaRemoteSendCommand returned \(ok)")
        }
        pendingResume = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resumeDebounce, execute: work)
    }
}
