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

    /// Command IDs used by MRMediaRemoteSendCommand.
    private enum Command: Int {
        case play = 0
        case pause = 1
    }

    private let sendCommand: SendCommandFn?
    /// Tracks whether *we* paused playback so we don't resume something the
    /// user paused themselves.
    private var didPause = false

    private init() {
        let url = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, url as CFURL),
              CFBundleLoadExecutable(bundle) else {
            print("MediaRemoteController: failed to load MediaRemote framework")
            self.sendCommand = nil
            return
        }
        guard let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) else {
            print("MediaRemoteController: MRMediaRemoteSendCommand symbol missing")
            self.sendCommand = nil
            return
        }
        self.sendCommand = unsafeBitCast(ptr, to: SendCommandFn.self)
    }

    /// Pause whatever is playing. Idempotent — repeated calls are no-ops while
    /// already paused-by-us. Records the pause so `resumeIfWePaused()` knows to
    /// resume only what we stopped.
    func pause() {
        guard let send = sendCommand else { return }
        guard !didPause else { return }
        let ok = send(Command.pause.rawValue, nil)
        if ok {
            didPause = true
            print("MediaRemoteController: paused active media")
        }
    }

    /// Resume only if we were the one who paused. No-op if the user paused
    /// themselves before TTS started.
    func resumeIfWePaused() {
        guard let send = sendCommand else { return }
        guard didPause else { return }
        didPause = false
        _ = send(Command.play.rawValue, nil)
        print("MediaRemoteController: resumed media we paused")
    }
}
