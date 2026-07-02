import Foundation
import AVFoundation
import CoreAudio
import AppKit
import Combine

// MARK: - State

enum CallCaptureState: String {
    case idle
    case recording
    case finalizing
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
    private var appURL: URL?

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

    // Near-end (microphone) plumbing.
    private var micEngine: AVAudioEngine?
    private var micAudioFile: AVAudioFile?

    private var elapsedTimer: Timer?
    private var watchedApp: NSRunningApplication?
    private var terminationObserver: NSObjectProtocol?

    // Level metering throttle (shared 20 Hz gate, cheap and good enough for meters).
    private var lastLevelPublish: TimeInterval = 0

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

        // Resolve the target: system-wide or a specific bundle id.
        let systemMode = ["system", "all", "all-system-output"].contains(app.lowercased())
        var targetBundleID: String? = nil
        var processObjectIDs: [AudioObjectID] = []

        if !systemMode {
            let bundleID = Self.resolveBundleID(from: app)
            guard let bundleID else { throw CallCaptureError.unknownApp(app) }
            targetBundleID = bundleID
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            guard let running = runningApps.first else {
                throw CallCaptureError.appNotRunning(Self.friendlyName(forBundleID: bundleID))
            }
            watchedApp = running
            for a in runningApps {
                if let obj = Self.processObject(forPID: a.processIdentifier) {
                    processObjectIDs.append(obj)
                }
            }
            if processObjectIDs.isEmpty {
                // App is running but Core Audio has no process object for it
                // yet (it hasn't produced audio). Tapping an empty process
                // list captures silence — surface that clearly.
                throw CallCaptureError.appNotRunning("\(Self.friendlyName(forBundleID: bundleID)) (no active audio process)")
            }
        }

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

        // Start the far end first — it's the one that can hit the TCC prompt.
        do {
            try startFarEndCapture(processObjectIDs: processObjectIDs, systemMode: systemMode, outputURL: appFileURL)
        } catch {
            teardownFarEnd()
            watchedApp = nil
            throw error
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
        sessionDirectory = dir
        sessionAppLabel = systemMode ? "system" : (targetBundleID ?? "app")
        startedAt = Date()
        endedAt = nil
        appURL = appFileURL
        micURL = micStarted ? micFileURL : nil

        DispatchQueue.main.async {
            self.micEnabled = micStarted
            self.capturingAppLabel = systemMode ? "System Audio" : Self.friendlyName(forBundleID: targetBundleID ?? "")
            self.micLevel = 0
            self.appLevel = 0
            self.elapsedSeconds = 0
        }

        installTerminationObserver()
        startElapsedTimer()
        writeSessionJSON()
        setState(.recording)

        NSLog("[CallCapture] Started session \(sessionId ?? "?") app=\(sessionAppLabel) mic=\(micStarted) dir=\(dir.path)")
        return currentSessionInfo()
    }

    /// Stop the active session, flush both files, write the final session.json.
    /// Returns the session info, or nil if nothing was capturing.
    @discardableResult
    func stop() -> CallCaptureSessionInfo? {
        guard state == .recording else { return nil }
        setState(.finalizing)

        stopElapsedTimer()
        removeTerminationObserver()
        teardownFarEnd()
        teardownMic()

        endedAt = Date()
        writeSessionJSON()
        let info = currentSessionInfo()

        NSLog("[CallCapture] Stopped session \(sessionId ?? "?"); files in \(sessionDirectory?.path ?? "?")")

        setState(.idle)
        DispatchQueue.main.async {
            self.micLevel = 0
            self.appLevel = 0
        }
        return info
    }

    /// Snapshot for the status endpoint.
    func statusSnapshot() -> (state: String, sessionId: String?, elapsedSeconds: Int, app: String?) {
        let elapsed: Int
        if let startedAt {
            elapsed = state == .idle ? 0 : Int(Date().timeIntervalSince(startedAt))
        } else {
            elapsed = 0
        }
        return (state.rawValue, state == .idle ? nil : sessionId, elapsed, state == .idle ? nil : sessionAppLabel)
    }

    func currentSessionInfo() -> CallCaptureSessionInfo {
        CallCaptureSessionInfo(
            id: sessionId ?? "",
            app: sessionAppLabel,
            directory: sessionDirectory ?? URL(fileURLWithPath: NSTemporaryDirectory()),
            micFile: micURL,
            appFile: appURL ?? URL(fileURLWithPath: "/dev/null"),
            startedAt: startedAt ?? Date(),
            endedAt: endedAt
        )
    }

    // MARK: - Far-end (process tap) capture

    private func startFarEndCapture(processObjectIDs: [AudioObjectID], systemMode: Bool, outputURL: URL) throws {
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

        // Read the tap's actual output format and mirror it in the WAV file.
        var asbd = try readTapFormat(tapID: newTapID)
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CallCaptureError.formatUnavailable
        }
        appFormat = format

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

        // Open the output WAV matching the tap format exactly (no conversion).
        do {
            appAudioFile = try AVAudioFile(
                forWriting: outputURL,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } catch {
            throw CallCaptureError.fileCreationFailed(error.localizedDescription)
        }

        // IOProc reads the tap stream on our dedicated (non-realtime) queue.
        var newProcID: AudioDeviceIOProcID?
        let procErr = AudioDeviceCreateIOProcIDWithBlock(&newProcID, newAggID, appQueue) { [weak self] _, inInputData, inInputTime, _, _ in
            self?.handleAppAudio(inInputData: inInputData, inInputTime: inInputTime)
        }
        guard procErr == noErr, let procID = newProcID else {
            throw CallCaptureError.ioProcSetupFailed(procErr)
        }
        appIOProcID = procID

        let startErr = AudioDeviceStart(newAggID, procID)
        guard startErr == noErr else {
            throw CallCaptureError.ioProcSetupFailed(startErr)
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

    private func teardownFarEnd() {
        if aggregateDeviceID != kAudioObjectUnknown, let procID = appIOProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
        }
        // Flush any in-flight callback before closing the file.
        appQueue.sync {}
        appAudioFile = nil

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
        appFormat = nil
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
        guard now - lastLevelPublish >= 1.0 / 20.0 else { return }
        lastLevelPublish = now

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

    // MARK: - session.json sidecar

    private func writeSessionJSON() {
        guard let dir = sessionDirectory, let id = sessionId, let started = startedAt else { return }
        var payload: [String: Any] = [
            "id": id,
            "app": sessionAppLabel,
            "startedAt": Self.iso8601.string(from: started),
            "files": [
                "app": appURL?.lastPathComponent ?? "app.wav",
                "mic": micURL?.lastPathComponent ?? NSNull()
            ]
        ]
        if let ended = endedAt {
            payload["endedAt"] = Self.iso8601.string(from: ended)
            payload["durationSeconds"] = Int(ended.timeIntervalSince(started))
        }
        // Per-track offsets from the shared host-time anchor (seconds).
        payload["anchor"] = [
            "appOffsetSeconds": hostTimeOffsetSeconds(from: startHostTime, to: appFirstHostTime),
            "micOffsetSeconds": hostTimeOffsetSeconds(from: startHostTime, to: micFirstHostTime)
        ]

        let url = dir.appendingPathComponent("session.json")
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("[CallCapture] Failed to write session.json: \(error.localizedDescription)")
        }
    }

    private func hostTimeOffsetSeconds(from start: UInt64, to first: UInt64) -> Double {
        guard first > start else { return 0 }
        let nanos = AudioConvertHostTimeToNanos(first) - AudioConvertHostTimeToNanos(start)
        return Double(nanos) / 1_000_000_000.0
    }

    // MARK: - Helpers

    private func setState(_ newState: CallCaptureState) {
        DispatchQueue.main.async {
            self.state = newState
            self.delegate?.callCaptureStateDidChange(newState)
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
