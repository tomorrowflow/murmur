import Foundation
import AVFoundation
import CoreAudio
import AppKit
import Combine
import SharedModels

// MARK: - State

enum CallCaptureState: String {
    case idle
    case recording
    case finalizing
    case transcribing   // capture done; transcription pipeline running
}

// MARK: - Known-app registry

/// A call app Murmur knows how to target by friendly alias. Extended at
/// runtime via the `callCapture.extraBundleIDs` UserDefaults string array.
struct KnownCaptureApp {
    let alias: String        // "slack"
    let bundleID: String     // "com.tinyspeck.slackmacgap"
    let displayName: String  // "Slack"
}

/// A known app that is currently running and therefore capturable right now.
struct DetectedCaptureApp {
    let alias: String?       // known alias, if this bundle id maps to one
    let bundleID: String
    let displayName: String
    let pid: pid_t
    let icon: NSImage?
}

// MARK: - Session info

/// Snapshot returned to callers (HTTP, menu) describing a session's files.
struct CallCaptureSessionInfo {
    let id: String
    let app: String          // bundle id, or "system" for the all-output tap
    let directory: URL
    let micFile: URL?
    let appFile: URL
    let startedAt: Date
    let endedAt: Date?
}

// MARK: - Errors

enum CallCaptureError: LocalizedError {
    case alreadyCapturing
    case appNotRunning(String)
    case unknownApp(String)
    case permissionDenied
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcSetupFailed(OSStatus)
    case formatUnavailable
    case fileCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyCapturing:
            return "A capture session is already in progress."
        case .appNotRunning(let app):
            return "\(app) is not running."
        case .unknownApp(let app):
            return "Unknown app \"\(app)\". Use slack/teams/zoom, a bundle id, or \"system\"."
        case .permissionDenied:
            return "System audio recording permission denied. Enable Murmur under System Settings > Privacy & Security > Screen & System Audio Recording."
        case .tapCreationFailed(let status):
            return "Failed to create the process tap (OSStatus \(status))."
        case .aggregateCreationFailed(let status):
            return "Failed to create the aggregate capture device (OSStatus \(status))."
        case .ioProcSetupFailed(let status):
            return "Failed to start the audio capture callback (OSStatus \(status))."
        case .formatUnavailable:
            return "Could not read the tap's audio format."
        case .fileCreationFailed(let detail):
            return "Could not create the output audio file: \(detail)"
        }
    }
}

// MARK: - Delegate

protocol CallCaptureManagerDelegate: AnyObject {
    func callCaptureStateDidChange(_ state: CallCaptureState)
    func callCaptureDidFail(_ message: String)
    /// Fired after a session is fully finalized (files flushed, metadata.json
    /// written) — for any stop trigger including auto-finalize. The app decides
    /// whether to kick off transcription.
    func callCaptureDidFinish(_ info: CallCaptureSessionInfo)
}

// MARK: - Manager

/// Captures a call in a target app by combining a Core Audio process tap on
/// the app's audio OUTPUT (the far end) with the microphone (the near end),
/// writing two WAV files that share a common host-time anchor. Phase B1 only —
/// no transcription or workflows. Follows the existing Manager pattern; the
/// companion `CallCaptureOverlayWindow` observes the published properties for
/// live UI.
final class CallCaptureManager: NSObject, ObservableObject {

    weak var delegate: CallCaptureManagerDelegate?

    // Observed by the overlay.
    @Published private(set) var state: CallCaptureState = .idle
    @Published private(set) var micLevel: CGFloat = 0      // 0...1
    @Published private(set) var appLevel: CGFloat = 0      // 0...1
    @Published private(set) var elapsedSeconds: Int = 0
    @Published private(set) var capturingAppLabel: String = ""
    @Published private(set) var micEnabled: Bool = false
    /// True when the app is targeted but hasn't produced audio yet, so the
    /// far-end tap is deferred and we're waiting for a matching audio process.
    @Published private(set) var waitingForAppAudio: Bool = false

    // MARK: Known apps

    static let knownApps: [KnownCaptureApp] = [
        KnownCaptureApp(alias: "slack", bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack"),
        KnownCaptureApp(alias: "teams", bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams"),
        KnownCaptureApp(alias: "zoom", bundleID: "us.zoom.xos", displayName: "Zoom")
    ]

    /// Extra bundle ids the user added in settings (treated as known targets).
    private static func extraBundleIDs() -> [String] {
        UserDefaults.standard.stringArray(forKey: "callCapture.extraBundleIDs") ?? []
    }

    /// All targetable bundle ids (built-in registry + user extras).
    static func allTargetBundleIDs() -> [String] {
        knownApps.map(\.bundleID) + extraBundleIDs()
    }

    static func friendlyName(forBundleID bundleID: String) -> String {
        if let known = knownApps.first(where: { $0.bundleID == bundleID }) {
            return known.displayName
        }
        // Fall back to the running app's localized name, then the bundle id.
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = app.localizedName {
            return name
        }
        return bundleID
    }

    /// Known + user-extra apps that are running right now, so the menu can
    /// offer them for one-click capture.
    static func detectedRunningApps() -> [DetectedCaptureApp] {
        var results: [DetectedCaptureApp] = []
        for bundleID in allTargetBundleIDs() {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { continue }
            let alias = knownApps.first(where: { $0.bundleID == bundleID })?.alias
            let displayName = knownApps.first(where: { $0.bundleID == bundleID })?.displayName
                ?? app.localizedName ?? bundleID
            results.append(DetectedCaptureApp(
                alias: alias,
                bundleID: bundleID,
                displayName: displayName,
                pid: app.processIdentifier,
                icon: app.icon
            ))
        }
        return results
    }

    // MARK: Session state

    private(set) var sessionId: String?
    private var sessionDirectory: URL?
    private var sessionAppLabel: String = ""      // bundle id or "system"
    private var startedAt: Date?
    private var endedAt: Date?
    private var micURL: URL?
    private var appURL: URL?                       // primary far-end file (app.wav), nil until opened
    private var plannedAppFileURL: URL?            // intended app.wav path (before it opens)
    private var extraAppURLs: [URL] = []           // app-2.wav, … from format-change rebuilds

    // Target identity, retained so the process-list listener can re-resolve the
    // match set on change. `systemMode` taps the whole system mixdown.
    private var systemMode = false
    private var targetBundleID: String?

    // Host-time anchor + per-track first-sample host times (offsets computed at finalize).
    private var startHostTime: UInt64 = 0
    private var appFirstHostTime: UInt64 = 0
    private var micFirstHostTime: UInt64 = 0

    // Far-end (process tap) plumbing.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var appIOProcID: AudioDeviceIOProcID?
    private var appAudioFile: AVAudioFile?
    private var appFormat: AVAudioFormat?
    private let appQueue = DispatchQueue(label: "com.murmur.callcapture.app")
    private var farEndActive = false
    /// The process-object set currently being tapped, so the listener can tell
    /// whether a process-list change actually affects our target.
    private var tappedProcessObjects: Set<AudioObjectID> = []
    /// Listener block on kAudioHardwarePropertyProcessObjectList (retained so we
    /// can remove exactly this registration).
    private var processListListenerBlock: AudioObjectPropertyListenerBlock?

    // Near-end (microphone) plumbing.
    private var micEngine: AVAudioEngine?
    private var micAudioFile: AVAudioFile?

    private var elapsedTimer: Timer?
    private var watchedApp: NSRunningApplication?
    private var terminationObserver: NSObjectProtocol?

    // Level metering throttle (20 Hz gate). Per-channel timestamps: mic and app
    // levels arrive on different audio threads, so they must not share state.
    private var lastMicLevelPublish: TimeInterval = 0
    private var lastAppLevelPublish: TimeInterval = 0

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    override init() {
        super.init()
        requestMicrophonePermission()
    }

    // MARK: - Public control

    var isCapturing: Bool { state != .idle }

    /// Start capturing `app` (alias, bundle id, or "system"/"all"). Throws a
    /// `CallCaptureError` on any precondition failure; on success returns the
    /// session info. Must be called on the main thread.
    @discardableResult
    func start(app: String, includeMic: Bool) throws -> CallCaptureSessionInfo {
        guard state == .idle else { throw CallCaptureError.alreadyCapturing }

        // Reset per-session far-end state.
        extraAppURLs = []
        tappedProcessObjects = []
        farEndActive = false

        // Resolve the target: system-wide or a specific bundle id.
        let systemMode = ["system", "all", "all-system-output"].contains(app.lowercased())
        self.systemMode = systemMode
        var targetBundleID: String? = nil
        var resolved: [ResolvedProcess] = []

        if !systemMode {
            let bundleID = Self.resolveBundleID(from: app)
            guard let bundleID else { throw CallCaptureError.unknownApp(app) }
            targetBundleID = bundleID
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            guard let running = runningApps.first else {
                throw CallCaptureError.appNotRunning(Self.friendlyName(forBundleID: bundleID))
            }
            watchedApp = running
            // Family-matching resolution: covers Electron/Chromium helper
            // processes (Slack/Teams render audio in a helper whose bundle id
            // extends the main app's). An empty result is allowed — the app is
            // running but hasn't produced audio yet; the process-list listener
            // brings the far-end up when a matching process appears.
            resolved = Self.resolveProcessObjects(forBundleID: bundleID)
        }
        self.targetBundleID = targetBundleID

        // Build the session directory.
        let label = systemMode ? "system" : (targetBundleID.map(Self.shortSlug) ?? "app")
        let stamp = Self.folderStampFormatter.string(from: Date())
        let baseDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/Murmur Calls", isDirectory: true)
        let dir = baseDir.appendingPathComponent("\(stamp)-\(label)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw CallCaptureError.fileCreationFailed(error.localizedDescription)
        }

        let appFileURL = dir.appendingPathComponent("app.wav")
        let micFileURL = dir.appendingPathComponent("mic.wav")

        // Record the shared anchor before either track opens.
        startHostTime = AudioGetCurrentHostTime()
        appFirstHostTime = 0
        micFirstHostTime = 0

        sessionDirectory = dir
        plannedAppFileURL = appFileURL
        appURL = nil

        // Bring the far end up (it can hit the TCC prompt). When a specific app
        // is targeted but not yet producing audio, defer: start mic + the
        // listener and let activateFarEnd() bring the tap up on first audio.
        let processObjectIDs = resolved.map(\.object)
        tappedProcessObjects = Set(processObjectIDs)
        if systemMode || !processObjectIDs.isEmpty {
            do {
                let format = try createFarEndTapAndAggregate(processObjectIDs: processObjectIDs, systemMode: systemMode)
                appAudioFile = try openAppFile(at: appFileURL, format: format)
                appFormat = format
                appURL = appFileURL
                try startFarEndIOProc()
                farEndActive = true
            } catch {
                teardownFarEnd()
                watchedApp = nil
                self.systemMode = false
                self.targetBundleID = nil
                throw error
            }
            NSLog("[CallCapture] Far-end tapping \(systemMode ? "system output" : Self.describe(resolved))")
        } else {
            NSLog("[CallCapture] \(Self.friendlyName(forBundleID: targetBundleID ?? "")) running but no audio process yet — deferring far-end, waiting for audio")
        }

        // Near end is best-effort: a mic failure shouldn't lose the far-end
        // audio that's already flowing.
        var micStarted = false
        if includeMic {
            do {
                try startMicCapture(outputURL: micFileURL)
                micStarted = true
            } catch {
                NSLog("[CallCapture] Microphone capture failed, continuing far-end only: \(error.localizedDescription)")
            }
        }

        // Commit session state.
        sessionId = "\(stamp)-\(label)"
        sessionAppLabel = systemMode ? "system" : (targetBundleID ?? "app")
        startedAt = Date()
        endedAt = nil
        micURL = micStarted ? micFileURL : nil

        let deferredFarEnd = !farEndActive && !systemMode
        DispatchQueue.main.async {
            self.micEnabled = micStarted
            self.capturingAppLabel = systemMode ? "System Audio" : Self.friendlyName(forBundleID: targetBundleID ?? "")
            self.waitingForAppAudio = deferredFarEnd
            self.micLevel = 0
            self.appLevel = 0
            self.elapsedSeconds = 0
        }

        installTerminationObserver()
        installProcessListListener()
        startElapsedTimer()
        writeSessionJSON()
        setState(.recording)

        // Reconcile once now that state is .recording: catches a matching audio
        // process that appeared between the initial resolve and the listener
        // registration (a listener only fires on subsequent changes). No-op when
        // the set is unchanged.
        if !systemMode { processListDidChange() }

        NSLog("[CallCapture] Started session \(sessionId ?? "?") app=\(sessionAppLabel) mic=\(micStarted) farEnd=\(farEndActive) dir=\(dir.path)")
        return currentSessionInfo()
    }

    /// Stop the active session, flush both files, write the final metadata.json.
    /// Returns the session info, or nil if nothing was capturing.
    @discardableResult
    func stop() -> CallCaptureSessionInfo? {
        // Single-shot: setState is synchronous on the main thread (all triggers
        // run on main), so a second stop() (e.g. manual stop racing the
        // auto-finalize on app exit) sees .finalizing here and returns nil —
        // callCaptureDidFinish fires exactly once per session.
        guard state == .recording else { return nil }
        setState(.finalizing)

        stopElapsedTimer()
        removeTerminationObserver()
        removeProcessListListener()
        teardownFarEnd()
        teardownMic()

        endedAt = Date()
        writeSessionJSON()
        let info = currentSessionInfo()
        micLevel = 0
        appLevel = 0
        waitingForAppAudio = false

        NSLog("[CallCapture] Stopped session \(sessionId ?? "?"); files in \(sessionDirectory?.path ?? "?")")

        // Stay in .finalizing and hand off — the delegate transitions us to
        // .transcribing (if transcribing) or .idle. We never pass through .idle
        // here, so there's no window in which a racing start() could slip a new
        // session in before markTranscribing lands.
        delegate?.callCaptureDidFinish(info)
        return info
    }

    /// Snapshot for the status endpoint.
    func statusSnapshot() -> (state: String, sessionId: String?, elapsedSeconds: Int, app: String?) {
        // Elapsed only counts while actively recording.
        let elapsed: Int
        if state == .recording, let startedAt {
            elapsed = Int(Date().timeIntervalSince(startedAt))
        } else {
            elapsed = 0
        }
        return (state.rawValue, state == .idle ? nil : sessionId, elapsed, state == .idle ? nil : sessionAppLabel)
    }

    /// Move to the .transcribing state after capture stops (drives the overlay
    /// and status endpoint while the pipeline runs). Keeps the session's id/app.
    func markTranscribing() {
        setState(.transcribing)
    }

    /// Transcription finished (or failed) — return to idle and dismiss UI.
    func markTranscriptionDone() {
        setState(.idle)
    }

    func currentSessionInfo() -> CallCaptureSessionInfo {
        CallCaptureSessionInfo(
            id: sessionId ?? "",
            app: sessionAppLabel,
            directory: sessionDirectory ?? URL(fileURLWithPath: NSTemporaryDirectory()),
            micFile: micURL,
            appFile: appURL ?? plannedAppFileURL ?? URL(fileURLWithPath: "/dev/null"),
            startedAt: startedAt ?? Date(),
            endedAt: endedAt
        )
    }

    // MARK: - Far-end (process tap) capture

    /// Create the process tap + its private aggregate device for the given
    /// targets and return the tap's audio format. Does NOT open the output file
    /// or start the IOProc — the caller wires the file, then calls
    /// `startFarEndIOProc()`. Split out from the old monolithic setup so the
    /// process-list listener can rebuild the tap without touching the mic.
    private func createFarEndTapAndAggregate(processObjectIDs: [AudioObjectID], systemMode: Bool) throws -> AVAudioFormat {
        let tapDescription: CATapDescription
        if systemMode {
            // Tap everything, excluding nothing → the full system mixdown.
            tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        } else {
            tapDescription = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        }
        tapDescription.uuid = UUID()
        tapDescription.name = "Murmur Call Capture"
        tapDescription.muteBehavior = .unmuted   // leave the call audible to the user
        tapDescription.isPrivate = true          // only visible to Murmur

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapErr = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard tapErr == noErr, newTapID != kAudioObjectUnknown else {
            // The TCC denial for system audio recording surfaces here.
            if tapErr == kAudioHardwareIllegalOperationError || tapErr == -1 {
                throw CallCaptureError.permissionDenied
            }
            throw CallCaptureError.tapCreationFailed(tapErr)
        }
        tapID = newTapID

        // Read the tap's actual output format.
        var asbd = try readTapFormat(tapID: newTapID)
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CallCaptureError.formatUnavailable
        }

        // Build a private aggregate device that owns just this tap.
        let aggUID = "com.murmur.callcapture.\(tapDescription.uuid.uuidString)"
        let aggDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Murmur Call Capture",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]
        var newAggID = AudioObjectID(kAudioObjectUnknown)
        let aggErr = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &newAggID)
        guard aggErr == noErr, newAggID != kAudioObjectUnknown else {
            throw CallCaptureError.aggregateCreationFailed(aggErr)
        }
        aggregateDeviceID = newAggID
        return format
    }

    /// Open a WAV for writing that mirrors the tap format exactly (no conversion).
    private func openAppFile(at url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        do {
            return try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } catch {
            throw CallCaptureError.fileCreationFailed(error.localizedDescription)
        }
    }

    /// Create + start the IOProc against the current aggregate device. The
    /// output file and `appFormat` must already be set.
    private func startFarEndIOProc() throws {
        // IOProc reads the tap stream on our dedicated (non-realtime) queue.
        var newProcID: AudioDeviceIOProcID?
        let procErr = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateDeviceID, appQueue) { [weak self] _, inInputData, inInputTime, _, _ in
            self?.handleAppAudio(inInputData: inInputData, inInputTime: inInputTime)
        }
        guard procErr == noErr, let procID = newProcID else {
            throw CallCaptureError.ioProcSetupFailed(procErr)
        }
        appIOProcID = procID

        let startErr = AudioDeviceStart(aggregateDeviceID, procID)
        guard startErr == noErr else {
            throw CallCaptureError.ioProcSetupFailed(startErr)
        }
    }

    /// Bring the far-end tap up (or rebuild it) for `processObjectIDs`, called
    /// from the process-list listener when the match set changes. Tears down
    /// only the far-end audio objects — the mic keeps recording throughout.
    ///
    /// File strategy across rebuilds (as specified): when the new tap format
    /// matches the current one, keep writing to the SAME WAV (a silent gap
    /// spans any pause, so the timeline stays continuous). Only when the format
    /// genuinely changes do we finalize the current file and continue into
    /// `app-<n>.wav`, registered as an extra `app-output` track. That extra
    /// track reuses the primary app offset in metadata (the anchor holds a
    /// single app offset); acceptable since a mid-call format change is rare.
    /// Empty `processObjectIDs` (non-system) tears the far-end down and waits.
    /// Best-effort: errors are logged (and a permission denial surfaced via the
    /// delegate), never thrown, so a live session keeps its mic track.
    private func activateFarEnd(processObjectIDs: [AudioObjectID]) {
        // Tear down the existing tap/aggregate/IOProc but keep the open file so
        // a format-matching rebuild can keep appending to it.
        teardownFarEndAudioObjects()

        guard systemMode || !processObjectIDs.isEmpty else {
            farEndActive = false
            DispatchQueue.main.async { self.waitingForAppAudio = true }
            NSLog("[CallCapture] No matching audio process — far-end idle, waiting for \(targetBundleID ?? "app") audio")
            return
        }

        do {
            let format = try createFarEndTapAndAggregate(processObjectIDs: processObjectIDs, systemMode: systemMode)

            if appAudioFile == nil {
                // First activation → open the primary app.wav.
                let url = plannedAppFileURL ?? (sessionDirectory ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent("app.wav")
                appAudioFile = try openAppFile(at: url, format: format)
                appFormat = format
                appURL = url
            } else if let current = appFormat, Self.formatsMatch(current, format) {
                // Same format → keep the existing file (do not reset the anchor).
            } else {
                // Format changed → finalize the current file, roll to app-<n>.wav.
                appAudioFile = nil
                let n = extraAppURLs.count + 2
                let url = (sessionDirectory ?? URL(fileURLWithPath: NSTemporaryDirectory()))
                    .appendingPathComponent("app-\(n).wav")
                appAudioFile = try openAppFile(at: url, format: format)
                appFormat = format
                extraAppURLs.append(url)
            }

            try startFarEndIOProc()
            farEndActive = true
            DispatchQueue.main.async { self.waitingForAppAudio = false }
            writeSessionJSON()
        } catch {
            farEndActive = false
            teardownFarEndAudioObjects()
            NSLog("[CallCapture] Far-end activation failed: \(error.localizedDescription)")
            if case CallCaptureError.permissionDenied = error {
                delegate?.callCaptureDidFail(error.localizedDescription)
            }
        }
    }

    private func handleAppAudio(inInputData: UnsafePointer<AudioBufferList>, inInputTime: UnsafePointer<AudioTimeStamp>) {
        guard let format = appFormat, let file = appAudioFile else { return }
        if appFirstHostTime == 0 {
            appFirstHostTime = inInputTime.pointee.mHostTime
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else { return }
        publishLevel(peakFromBufferList(inInputData), channel: .app)
        do {
            try file.write(from: buffer)
        } catch {
            NSLog("[CallCapture] app.wav write failed: \(error.localizedDescription)")
        }
    }

    /// Tear down just the tap/aggregate/IOProc, leaving `appAudioFile` /
    /// `appFormat` intact so a format-matching rebuild keeps the same WAV.
    private func teardownFarEndAudioObjects() {
        if aggregateDeviceID != kAudioObjectUnknown, let procID = appIOProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
        }
        // Flush any in-flight callback before touching the file/objects.
        appQueue.sync {}

        if aggregateDeviceID != kAudioObjectUnknown, let procID = appIOProcID {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
        }
        appIOProcID = nil
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    /// Full far-end teardown (session end): audio objects + the output file.
    private func teardownFarEnd() {
        teardownFarEndAudioObjects()
        appAudioFile = nil
        appFormat = nil
        farEndActive = false
    }

    private func readTapFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let err = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard err == noErr else { throw CallCaptureError.formatUnavailable }
        return asbd
    }

    // MARK: - Near-end (microphone) capture

    private func startMicCapture(outputURL: URL) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: outputURL,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } catch {
            throw CallCaptureError.fileCreationFailed(error.localizedDescription)
        }
        micAudioFile = file

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self else { return }
            if self.micFirstHostTime == 0 {
                self.micFirstHostTime = when.hostTime
            }
            self.publishLevel(self.peakFromPCMBuffer(buffer), channel: .mic)
            do {
                try self.micAudioFile?.write(from: buffer)
            } catch {
                NSLog("[CallCapture] mic.wav write failed: \(error.localizedDescription)")
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            micAudioFile = nil
            throw CallCaptureError.fileCreationFailed("microphone engine: \(error.localizedDescription)")
        }
        micEngine = engine
    }

    private func teardownMic() {
        if let engine = micEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        micEngine = nil
        micAudioFile = nil
    }

    // MARK: - Level metering

    private enum LevelChannel { case mic, app }

    private func publishLevel(_ peak: Float, channel: LevelChannel) {
        let now = ProcessInfo.processInfo.systemUptime
        switch channel {
        case .mic:
            guard now - lastMicLevelPublish >= 1.0 / 20.0 else { return }
            lastMicLevelPublish = now
        case .app:
            guard now - lastAppLevelPublish >= 1.0 / 20.0 else { return }
            lastAppLevelPublish = now
        }

        // Map peak amplitude to a dB-normalized 0...1, matching AudioLevelMonitor.
        let db = 20 * log10(max(peak, 0.00001))
        let normalized = CGFloat((db + 60) / 60).clampedUnit()

        DispatchQueue.main.async {
            switch channel {
            case .mic: self.micLevel = self.micLevel * 0.6 + normalized * 0.4
            case .app: self.appLevel = self.appLevel * 0.6 + normalized * 0.4
            }
        }
    }

    private func peakFromPCMBuffer(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        var peak: Float = 0
        for c in 0..<channels {
            let samples = channelData[c]
            for i in 0..<frames { peak = max(peak, abs(samples[i])) }
        }
        return peak
    }

    private func peakFromBufferList(_ abl: UnsafePointer<AudioBufferList>) -> Float {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        var peak: Float = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let floats = data.bindMemory(to: Float.self, capacity: count)
            for i in 0..<count { peak = max(peak, abs(floats[i])) }
        }
        return peak
    }

    // MARK: - Elapsed timer

    private func startElapsedTimer() {
        stopElapsedTimer()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.startedAt else { return }
            DispatchQueue.main.async {
                self.elapsedSeconds = Int(Date().timeIntervalSince(startedAt))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // MARK: - Process termination watch

    private func installTerminationObserver() {
        guard let watched = watchedApp else { return }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.processIdentifier == watched.processIdentifier {
                NSLog("[CallCapture] Tapped app exited — auto-finalizing session")
                _ = self.stop()
            }
        }
    }

    private func removeTerminationObserver() {
        if let observer = terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            terminationObserver = nil
        }
        watchedApp = nil
    }

    // MARK: - Process-list watch (helper processes appearing mid-call)

    /// Listen for changes to the system's audio process list. Electron/Chromium
    /// call apps spin up (and tear down) helper render processes as a call
    /// starts, and a call may begin AFTER capture starts, so the initial match
    /// set can miss the process that actually renders audio. On any change we
    /// re-resolve and, if our match set changed, rebuild the far-end tap.
    /// Only installed for app-targeted sessions (system mode taps everything).
    private func installProcessListListener() {
        guard !systemMode else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.processListDidChange()
        }
        let err = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        if err == noErr {
            processListListenerBlock = block
        } else {
            NSLog("[CallCapture] Failed to add process-list listener (OSStatus \(err))")
        }
    }

    private func removeProcessListListener() {
        guard let block = processListListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        processListListenerBlock = nil
    }

    /// Runs on the main queue (the listener's dispatch queue). Re-resolve the
    /// target's match set; rebuild the far-end only when it actually changed.
    private func processListDidChange() {
        guard state == .recording, !systemMode, let bundleID = targetBundleID else { return }
        let resolved = Self.resolveProcessObjects(forBundleID: bundleID)
        let newSet = Set(resolved.map(\.object))
        guard newSet != tappedProcessObjects else { return }
        tappedProcessObjects = newSet
        if resolved.isEmpty {
            NSLog("[CallCapture] Process list changed: no audio process for \(bundleID) — far-end idle")
        } else {
            NSLog("[CallCapture] Process list changed: rebuilding far-end tap for \(bundleID) → \(Self.describe(resolved))")
        }
        activateFarEnd(processObjectIDs: resolved.map(\.object))
    }

    // MARK: - metadata.json sidecar

    /// The metadata.json contract for the current session, pre-transcription.
    /// The transcription pipeline reads this to find the tracks and later fills
    /// in engine/transcript/durations. Grows the B1 skeleton into the full
    /// spec sidecar (source, tracks, engine, transcript, workflowOutputs).
    private func writeSessionJSON() {
        guard let dir = sessionDirectory, let id = sessionId, let started = startedAt else { return }

        // Emit an app-output track per opened far-end file. In the common case
        // that's just app.wav; a mid-call format change adds app-2.wav, etc.
        // When the far-end never opened (app targeted but never produced audio),
        // appURL is nil and no app track is written — so transcription doesn't
        // fail loading a file that doesn't exist.
        var tracks: [CallSessionMetadata.Track] = []
        if let appURL {
            tracks.append(.init(role: "app-output", file: appURL.lastPathComponent))
            for extra in extraAppURLs {
                tracks.append(.init(role: "app-output", file: extra.lastPathComponent))
            }
        }
        if let micURL {
            tracks.append(.init(role: "mic", file: micURL.lastPathComponent))
        }

        var meta = CallSessionMetadata(
            id: id,
            source: "live-capture",
            app: sessionAppLabel,
            startedAt: Self.iso8601.string(from: started),
            tracks: tracks,
            anchor: .init(
                appOffsetSeconds: hostTimeOffsetSeconds(from: startHostTime, to: appFirstHostTime),
                micOffsetSeconds: hostTimeOffsetSeconds(from: startHostTime, to: micFirstHostTime)
            )
        )
        if let ended = endedAt {
            meta.endedAt = Self.iso8601.string(from: ended)
            meta.durationSeconds = Int(ended.timeIntervalSince(started))
        }

        do {
            try meta.write(to: dir.appendingPathComponent("metadata.json"))
        } catch {
            NSLog("[CallCapture] Failed to write metadata.json: \(error.localizedDescription)")
        }
    }

    private func hostTimeOffsetSeconds(from start: UInt64, to first: UInt64) -> Double {
        guard first > start else { return 0 }
        let nanos = AudioConvertHostTimeToNanos(first) - AudioConvertHostTimeToNanos(start)
        return Double(nanos) / 1_000_000_000.0
    }

    // MARK: - Helpers

    /// Apply the state change synchronously when already on the main thread, so
    /// main-thread callers' guards (e.g. start()'s `state == .idle`, stop()'s
    /// `state == .recording`) observe the new state immediately rather than one
    /// runloop tick later. All trigger paths run on main; off-main callers (if
    /// any) fall back to an async hop. `state` is @Published, so it must only be
    /// mutated on the main thread either way.
    private func setState(_ newState: CallCaptureState) {
        if Thread.isMainThread {
            state = newState
            delegate?.callCaptureStateDidChange(newState)
        } else {
            DispatchQueue.main.async {
                self.state = newState
                self.delegate?.callCaptureStateDidChange(newState)
            }
        }
    }

    /// Map an alias, display name, or raw bundle id to a bundle id.
    private static func resolveBundleID(from input: String) -> String? {
        let lower = input.lowercased()
        if let known = knownApps.first(where: { $0.alias == lower }) {
            return known.bundleID
        }
        // A dotted string that matches a known/extra id, or looks like a bundle id.
        if allTargetBundleIDs().contains(input) { return input }
        if input.contains(".") { return input }
        return nil
    }

    /// Compact, filesystem-safe label for a bundle id (prefers the alias).
    private static func shortSlug(_ bundleID: String) -> String {
        if let known = knownApps.first(where: { $0.bundleID == bundleID }) {
            return known.alias
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? "app"
    }

    private static let folderStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// A Core Audio process object matched to a capture target, with its bundle
    /// id and pid for logging.
    private struct ResolvedProcess {
        let object: AudioObjectID
        let bundleID: String
        let pid: pid_t
    }

    /// Resolve the Core Audio process objects to tap for `bundleID`. Electron/
    /// Chromium apps (Slack, Teams) render call audio in HELPER processes whose
    /// bundle ids extend the main app's (e.g.
    /// `com.tinyspeck.slackmacgap.helper`), so match every process object whose
    /// bundle id equals the target OR has the target as a dotted prefix, unioned
    /// with the PID-translate result for the running main app(s). Processes
    /// appear in the system list only once they produce audio.
    private static func resolveProcessObjects(forBundleID bundleID: String) -> [ResolvedProcess] {
        var byObject: [AudioObjectID: ResolvedProcess] = [:]

        // 1. Family match against the full audio process list.
        for obj in processObjectList() {
            guard let objBundleID = processBundleID(obj) else { continue }
            if objBundleID == bundleID || objBundleID.hasPrefix(bundleID + ".") {
                byObject[obj] = ResolvedProcess(object: obj, bundleID: objBundleID, pid: processPID(obj))
            }
        }

        // 2. Union the PID-translate result for the running main app(s).
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            if let obj = processObject(forPID: app.processIdentifier) {
                byObject[obj] = ResolvedProcess(object: obj, bundleID: bundleID, pid: app.processIdentifier)
            }
        }

        return byObject.values.sorted { $0.object < $1.object }
    }

    /// Every audio process object the system currently knows about.
    private static func processObjectList() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let sizeErr = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize)
        guard sizeErr == noErr, dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids)
        guard err == noErr else { return [] }
        return ids
    }

    /// Bundle id for a Core Audio process object, or nil if unavailable/empty.
    private static func processBundleID(_ obj: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // The property returns a +1-retained CFString (Copy semantics), so read
        // into an Unmanaged and balance the retain with takeRetainedValue().
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = AudioObjectGetPropertyData(obj, &address, 0, nil, &size, &unmanaged)
        guard err == noErr, let cf = unmanaged?.takeRetainedValue() else { return nil }
        let s = cf as String
        return s.isEmpty ? nil : s
    }

    /// PID backing a Core Audio process object (0 if unavailable) — for logging.
    private static func processPID(_ obj: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let err = AudioObjectGetPropertyData(obj, &address, 0, nil, &size, &pid)
        guard err == noErr else { return 0 }
        return pid
    }

    /// Whether two tap formats are interchangeable for file reuse across a
    /// far-end rebuild (same sample rate / channels / sample type / layout).
    private static func formatsMatch(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate &&
        a.channelCount == b.channelCount &&
        a.commonFormat == b.commonFormat &&
        a.isInterleaved == b.isInterleaved
    }

    private static func describe(_ procs: [ResolvedProcess]) -> String {
        guard !procs.isEmpty else { return "(none)" }
        return procs.map { "\($0.bundleID)#\($0.object)(pid \($0.pid))" }.joined(separator: ", ")
    }

    /// Translate a running app's PID into a Core Audio process object, creating
    /// one if needed. Returns nil if the process has no audio object.
    private static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidValue = pid
        var obj = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &obj
        )
        guard err == noErr, obj != kAudioObjectUnknown else { return nil }
        return obj
    }

    // MARK: - Permissions

    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if !granted {
                NSLog("[CallCapture] Microphone permission denied — near-end capture will be silent")
            }
        }
    }
}

private extension CGFloat {
    func clampedUnit() -> CGFloat { Swift.min(Swift.max(self, 0), 1) }
}
