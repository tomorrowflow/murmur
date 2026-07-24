import Foundation
import AVFoundation
import ObjCExceptionCatcher

/// Owns an `AVAudioEngine` capture session: input tap, resampling to a target rate,
/// sample accumulation, level metering, and Bluetooth codec-switch recovery.
///
/// Every engine mutation is serialized onto a private queue and never runs on main.
/// `AVAudioEngine.start()` blocks for 1-2s while a Bluetooth headset renegotiates
/// A2DP→HFP; doing that on main freezes the UI and skews any key-timing the caller
/// measures. Because the queue is serial, a `stop()` issued while a `start()` is still
/// in flight is always applied after that start completes, rather than racing it.
///
/// Threading contract: `start`, `stop`, `cancel` and `clearBuffer` are called on the
/// main thread, and every callback is delivered on the main thread.
public final class AudioEngineRecorder {

    public struct Configuration {
        /// Prefix for log lines and dispatch queue labels.
        public var label: String
        /// Rate the captured audio is resampled to before it reaches the buffer.
        public var targetSampleRate: Double
        /// How long to keep retrying the engine restart after a Bluetooth codec switch
        /// before the session is declared lost. A single A2DP→HFP switch can take 1-2s to
        /// settle, during which the input node reports a stale format and `installTap`
        /// fails with "format mismatch"; we poll across this window until it settles.
        public var codecSwitchRecoveryWindow: TimeInterval
        /// Interval between restart attempts inside the recovery window.
        public var codecSwitchRetryInterval: TimeInterval

        public init(label: String,
                    targetSampleRate: Double = 16000,
                    codecSwitchRecoveryWindow: TimeInterval = 4.0,
                    codecSwitchRetryInterval: TimeInterval = 0.15) {
            self.label = label
            self.targetSampleRate = targetSampleRate
            self.codecSwitchRecoveryWindow = codecSwitchRecoveryWindow
            self.codecSwitchRetryInterval = codecSwitchRetryInterval
        }
    }

    // MARK: - Callbacks (all delivered on main)

    /// Fires once per session, when the first audio buffer arrives. On Bluetooth this is
    /// the proof that the A2DP→HFP profile switch finished and the mic is really live.
    public var onMicReady: (() -> Void)?
    /// Per-buffer input level in dBFS.
    public var onLevel: ((Float) -> Void)?
    /// The buffer grew past `maxBufferSamples`. The owner decides what to do (normally stop).
    public var onBufferLimit: (() -> Void)?
    /// The engine refused to start. The session is already torn down.
    public var onStartFailure: ((String) -> Void)?
    /// The engine died mid-session and exhausted its restart budget. Already torn down.
    public var onEngineLost: ((String) -> Void)?

    // MARK: - State (main thread only)

    public private(set) var isRecording = false
    /// True between `start()` and the engine actually running. A second `start()` is ignored
    /// while this holds; a `stop()` is honoured and applied once the start completes.
    public private(set) var isStarting = false

    // MARK: - Internals

    private let config: Configuration
    private let engineQueue: DispatchQueue
    private let bufferQueue: DispatchQueue

    /// engineQueue-confined.
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var configChangeObserver: NSObjectProtocol?
    /// True while a codec-switch recovery loop is polling. A single switch emits several
    /// `.AVAudioEngineConfigurationChange` notifications; this keeps only one loop running so
    /// they don't stack into overlapping restart chains.
    private var isRecoveringFromConfigChange = false
    /// Absolute deadline after which the current recovery loop gives up. Set when a recovery
    /// begins, cleared when it finishes.
    private var configRecoveryDeadline: DispatchTime?
    /// Session the live engine belongs to. Recovery attempts carry this so a retry scheduled
    /// on the old session can't disrupt an engine the user has since restarted.
    private var engineSession = 0

    /// bufferQueue-confined.
    private var audioBuffer: [Float] = []
    private var autoStopRequested = false
    private var activeMaxBufferSamples = Int.max

    /// Audio-thread-confined (single tap callback thread per session).
    private var micReadyFired = false

    /// Identifies the current capture session. Bumped by every start, stop and cancel, so
    /// engine work queued for a session the caller has already abandoned drops out instead
    /// of bringing a microphone up that nobody is listening to.
    private var activeSession = 0
    private let sessionLock = NSLock()

    private func beginSession() -> Int {
        sessionLock.lock(); defer { sessionLock.unlock() }
        activeSession &+= 1
        return activeSession
    }

    private func endSession() {
        sessionLock.lock(); defer { sessionLock.unlock() }
        activeSession &+= 1
    }

    private func isCurrent(_ session: Int) -> Bool {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return activeSession == session
    }

    public init(configuration: Configuration) {
        self.config = configuration
        self.engineQueue = DispatchQueue(label: "com.murmur.\(configuration.label).engine")
        self.bufferQueue = DispatchQueue(label: "com.murmur.\(configuration.label).audioBuffer")
    }

    deinit {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Lifecycle

    /// Begin capturing. `isRecording` flips synchronously — callers gate UI and stop-handling
    /// on it — while the engine comes up on a background queue.
    ///
    /// - Parameters:
    ///   - maxBufferSamples: buffer ceiling before `onBufferLimit` fires.
    ///   - gate: optional async precondition. It receives a `launch` closure and must call it
    ///     once the engine may come up (used to let a media-pause snapshot resolve first).
    ///     A `stop()` during the gate cancels the launch rather than orphaning a live mic.
    public func start(maxBufferSamples: Int = .max, gate: ((@escaping () -> Void) -> Void)? = nil) {
        guard !isStarting, !isRecording else { return }
        isStarting = true
        isRecording = true
        let session = beginSession()

        bufferQueue.sync {
            audioBuffer.removeAll()
            autoStopRequested = false
            activeMaxBufferSamples = maxBufferSamples
        }

        let launch: () -> Void = { [weak self] in
            self?.engineQueue.async {
                guard let self = self, self.isCurrent(session) else { return }
                self.startEngine(session: session)
            }
        }
        if let gate = gate { gate(launch) } else { launch() }
    }

    /// Stop capturing and hand the captured samples back on the main thread.
    /// Safe to call while a start is still in flight — the teardown queues behind it.
    public func stop(deliveringSamples completion: @escaping ([Float]) -> Void) {
        guard isRecording else { return }
        isRecording = false
        isStarting = false
        endSession()

        engineQueue.async { [weak self] in
            guard let self = self else { return }
            self.teardownEngine()
            // Snapshot under the buffer queue: late tap callbacks may still be appending.
            let samples = self.bufferQueue.sync { self.audioBuffer }
            DispatchQueue.main.async { completion(samples) }
        }
    }

    /// Stop capturing and discard whatever was captured.
    public func cancel() {
        guard isRecording else { return }
        isRecording = false
        isStarting = false
        endSession()

        engineQueue.async { [weak self] in
            guard let self = self else { return }
            self.teardownEngine()
            self.bufferQueue.sync { self.audioBuffer.removeAll() }
        }
    }

    /// Discard audio captured so far without stopping — used to drop the garbage a
    /// Bluetooth mic emits before its profile switch settles.
    public func clearBuffer() {
        bufferQueue.sync { audioBuffer.removeAll() }
    }

    // MARK: - Engine (engineQueue only)

    /// engineQueue-confined. Counts how many times the engine bring-up actually ran, so tests
    /// can prove that abandoned sessions never reach the microphone.
    private var engineStartAttempts = 0

    /// Test hook. Reads the counter on the queue that owns it.
    internal func engineStartAttemptsForTesting() -> Int {
        engineQueue.sync { engineStartAttempts }
    }

    private func startEngine(session: Int) {
        engineStartAttempts += 1
        let engine = AVAudioEngine()
        let input = engine.inputNode
        audioEngine = engine
        inputNode = input
        engineSession = session
        isRecoveringFromConfigChange = false
        configRecoveryDeadline = nil
        micReadyFired = false

        configureInputDevice(input)
        installInputTap(on: input)
        registerConfigChangeObserver(for: engine)

        do {
            engine.prepare()
            try engine.start()
            print("🎤 \(config.label): recording started")
            DispatchQueue.main.async { [weak self] in self?.isStarting = false }
        } catch {
            print("\(config.label): failed to start audio engine: \(error)")
            teardownEngine()
            let message = "Could not start the microphone: \(error.localizedDescription)"
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isRecording = false
                self.isStarting = false
                self.onStartFailure?(message)
            }
        }
    }

    private func teardownEngine() {
        removeConfigChangeObserver()
        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine?.reset()
        AudioDeviceManager.shared.restoreDefaultInputDeviceIfOverridden()
    }

    private func configureInputDevice(_ input: AVAudioInputNode) {
        if let deviceName = AudioDeviceManager.shared.applyInputDeviceOverrideIfNeeded() {
            print("✅ \(config.label): set input to \(deviceName)")
        }
        let outFormat = input.outputFormat(forBus: 0)
        let hwFormat = input.inputFormat(forBus: 0)
        print("   \(config.label) format: out \(outFormat.sampleRate)Hz/\(outFormat.channelCount)ch, hw \(hwFormat.sampleRate)Hz/\(hwFormat.channelCount)ch")
    }

    /// Installs the capture tap. Returns `false` (without a usable tap installed) when the
    /// input node's format is unusable — common mid-way through a Bluetooth codec switch.
    ///
    /// Two failure modes are guarded:
    ///   1. A transient 0 Hz / 0-channel format (caught up-front by validation).
    ///   2. `installTap` itself raising an Objective-C `NSException` for a format that looks
    ///      valid but is incompatible with the node's current hardware bus. Swift's `do/catch`
    ///      cannot catch that — an uncaught `NSException` aborts the process (SIGABRT) — so the
    ///      call is funnelled through `ObjCTryCatch` and converted into a recoverable error.
    @discardableResult
    private func installInputTap(on input: AVAudioInputNode) -> Bool {
        // Match the tap to the node's *hardware input* format, not its output format.
        // installTap asserts `format.sampleRate == inputHWFormat.sampleRate`; on a Bluetooth
        // mic in HFP mode the hardware runs at e.g. 16 kHz while `outputFormat` still reports
        // 48 kHz, so passing outputFormat throws "format mismatch" until the rates happen to
        // converge (often never, within any reasonable window). `inputFormat` reflects the real
        // hardware rate, so the tap installs immediately at whatever the codec is currently
        // using. Fall back to outputFormat if the hardware format isn't reported.
        let hwFormat = input.inputFormat(forBus: 0)
        let outFormat = input.outputFormat(forBus: 0)
        let recordingFormat = (hwFormat.sampleRate > 0 && hwFormat.channelCount > 0) ? hwFormat : outFormat
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            print("⚠️ \(config.label): input format not ready (hw \(hwFormat.sampleRate)Hz/\(hwFormat.channelCount)ch, out \(outFormat.sampleRate)Hz/\(outFormat.channelCount)ch) — deferring tap install")
            return false
        }
        let resampler = StreamingResampler(targetSampleRate: config.targetSampleRate)

        let installError = ObjCTryCatch {
            input.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                guard let self = self, let channelData = buffer.floatChannelData?[0] else { return }
                let frameLength = Int(buffer.frameLength)

                if !self.micReadyFired {
                    self.micReadyFired = true
                    DispatchQueue.main.async { self.onMicReady?() }
                }

                let samples = resampler?.resample(buffer)
                    ?? Array(UnsafeBufferPointer(start: channelData, count: frameLength))

                self.bufferQueue.async {
                    self.audioBuffer.append(contentsOf: samples)
                    if self.audioBuffer.count > self.activeMaxBufferSamples && !self.autoStopRequested {
                        self.autoStopRequested = true
                        print("⚠️ \(self.config.label): buffer limit reached")
                        DispatchQueue.main.async {
                            guard self.isRecording else { return }
                            self.onBufferLimit?()
                        }
                    }
                }

                let rms = sqrt(channelData.withMemoryRebound(to: Float.self, capacity: frameLength) { ptr in
                    var sum: Float = 0
                    for i in 0..<frameLength {
                        sum += ptr[i] * ptr[i]
                    }
                    return sum / Float(frameLength)
                })
                let db = 20 * log10(max(rms, 0.00001))
                DispatchQueue.main.async { self.onLevel?(db) }
            }
        }

        if let installError = installError {
            print("⚠️ \(config.label): installTap raised (\(installError.localizedDescription)) — deferring")
            // The tap may have been partially registered before the throw; clear it so the
            // retry starts from a clean bus.
            input.removeTap(onBus: 0)
            return false
        }
        return true
    }

    // MARK: - Bluetooth codec-switch recovery

    private func registerConfigChangeObserver(for engine: AVAudioEngine) {
        removeConfigChangeObserver()
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func removeConfigChangeObserver() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
    }

    /// macOS stops the engine when a Bluetooth mic switches codec (A2DP→HFP), often before
    /// a single buffer has arrived. Restart it so the recording actually begins.
    ///
    /// The switch is asynchronous and can take 1-2s to settle. While it is in flight the input
    /// node reports a stale format, so reinstalling the tap fails with "format mismatch" and
    /// `start()` may throw. We therefore poll — reinstalling the tap and restarting the engine
    /// every `codecSwitchRetryInterval` — until it succeeds or `codecSwitchRecoveryWindow`
    /// elapses, rather than giving up after a handful of immediate attempts.
    private func handleConfigurationChange() {
        guard isRecording else { return }

        // Onto the engine queue: on Bluetooth this notification is emitted from inside the
        // very `start()` that is still running there, so touching the engine here would race it.
        engineQueue.async { [weak self] in
            guard let self = self, self.audioEngine != nil else { return }
            let session = self.engineSession
            guard self.isCurrent(session) else { return }
            // A single codec switch emits several notifications; keep just one recovery loop.
            guard !self.isRecoveringFromConfigChange else { return }
            self.isRecoveringFromConfigChange = true
            self.configRecoveryDeadline = .now() + self.config.codecSwitchRecoveryWindow
            print("🔁 \(self.config.label): engine config changed (codec switch?) — recovering (window \(self.config.codecSwitchRecoveryWindow)s)")
            self.attemptEngineRecovery(session: session)
        }
    }

    /// One restart attempt in the codec-switch recovery loop. engineQueue-confined; reschedules
    /// itself until the engine restarts cleanly or the recovery window expires.
    private func attemptEngineRecovery(session: Int) {
        // Bail if the session was stopped/replaced while this attempt was queued.
        guard isRecording, isCurrent(session), let engine = audioEngine else {
            isRecoveringFromConfigChange = false
            configRecoveryDeadline = nil
            return
        }

        let fail: (String) -> Void = { [weak self] message in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isRecording = false
                self.isStarting = false
                self.onEngineLost?(message)
            }
        }

        let windowExpired = configRecoveryDeadline.map { DispatchTime.now() >= $0 } ?? true

        let retryOrGiveUp: (String) -> Void = { [weak self] reason in
            guard let self = self else { return }
            if windowExpired {
                print("⚠️ \(self.config.label): codec switch never settled (\(reason)) — giving up")
                self.isRecoveringFromConfigChange = false
                self.configRecoveryDeadline = nil
                self.removeConfigChangeObserver()
                self.teardownEngine()
                self.bufferQueue.sync { self.audioBuffer.removeAll() }
                fail("Mic failed to start (Bluetooth audio device unstable). Try again or pick a different input device.")
                return
            }
            self.engineQueue.asyncAfter(deadline: .now() + self.config.codecSwitchRetryInterval) { [weak self] in
                self?.attemptEngineRecovery(session: session)
            }
        }

        inputNode?.removeTap(onBus: 0)
        // Re-acquire the input node — its format may have changed with the codec.
        let input = engine.inputNode
        inputNode = input

        guard installInputTap(on: input) else {
            retryOrGiveUp("tap install")
            return
        }

        do {
            engine.prepare()
            try engine.start()
            isRecoveringFromConfigChange = false
            configRecoveryDeadline = nil
            print("🎤 \(config.label): engine recovered after codec switch")
            DispatchQueue.main.async { [weak self] in self?.isStarting = false }
        } catch {
            retryOrGiveUp("start: \(error.localizedDescription)")
        }
    }
}
