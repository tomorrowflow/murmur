import Cocoa
import SwiftUI
import KeyboardShortcuts
import AVFoundation
import WhisperKit
import SharedModels
import Combine
import ApplicationServices
import Foundation

// Environment variable loading
func loadEnvironmentVariables() {
    let fileManager = FileManager.default
    let currentDirectory = fileManager.currentDirectoryPath
    let envPath = "\(currentDirectory)/.env"
    
    guard fileManager.fileExists(atPath: envPath),
          let envContent = try? String(contentsOfFile: envPath) else {
        return
    }
    
    for line in envContent.components(separatedBy: .newlines) {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty && !trimmedLine.hasPrefix("#") else { continue }

        guard let equalsIndex = trimmedLine.firstIndex(of: "=") else { continue }

        let key = String(trimmedLine[trimmedLine.startIndex..<equalsIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(trimmedLine[trimmedLine.index(after: equalsIndex)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { continue }
        setenv(key, value, 1)
    }
}

extension KeyboardShortcuts.Name {
    static let startRecording = Self("startRecording")
    static let showHistory = Self("showHistory")
    static let readSelectedText = Self("readSelectedText")

    static let pasteLastTranscription = Self("pasteLastTranscription")
    static let openclawRecording = Self("openclawRecording")
}

enum OptionDoubleTapState {
    case idle
    case firstPress
    case firstRelease
    case recording
}

class AppDelegate: NSObject, NSApplicationDelegate, AudioTranscriptionManagerDelegate, OpenClawRecordingManagerDelegate {
    var statusItem: NSStatusItem!
    var settingsWindow: SettingsWindowController?
    private var unifiedWindow: UnifiedManagerWindow?
    private var historyWindow: TranscriptionHistoryWindow?

    private var displayTimer: Timer?
    private var modelCancellable: AnyCancellable?
    private var engineCancellable: AnyCancellable?
    private var parakeetVersionCancellable: AnyCancellable?
    private var waveformAnimationTimer: Timer?
    private var audioManager: AudioTranscriptionManager!
    private var audioOverlay: AudioTranscriptionOverlayWindow?
    private var streamingPlayer: GeminiStreamingPlayer?
    private var audioCollector: GeminiAudioCollector?
    private var isCurrentlyPlaying = false
    private var currentStreamingTask: Task<Void, Never>?
    private var currentPlayingSound: NSSound?
    var openClawManagerPublic: OpenClawManager? { openClawManager }
    private var openClawManager: OpenClawManager?
    private var openClawRecordingManager: OpenClawRecordingManager?
    private var openClawOverlay: OpenClawOverlayWindow?
    private var optionDoubleTapMonitor: Any?
    private var leftOptionState: OptionDoubleTapState = .idle
    private var leftOptionFirstPressTime: TimeInterval = 0
    private var leftOptionFirstReleaseTime: TimeInterval = 0
    private var leftOptionResetTimer: Timer?
    private var rightOptionState: OptionDoubleTapState = .idle
    private var rightOptionFirstPressTime: TimeInterval = 0
    private var rightOptionFirstReleaseTime: TimeInterval = 0
    private var rightOptionResetTimer: Timer?
    private var sttPushToTalkActive = false
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load environment variables
        loadEnvironmentVariables()
        
        // Initialize streaming TTS components if API key is available
        if let apiKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !apiKey.isEmpty {
            if #available(macOS 14.0, *) {
                streamingPlayer = GeminiStreamingPlayer(playbackSpeed: 1.15)
                audioCollector = GeminiAudioCollector(apiKey: apiKey)
                print("✅ Streaming TTS components initialized")
            } else {
                print("⚠️ Streaming TTS requires macOS 14.0 or later")
            }
        } else {
            print("⚠️ GEMINI_API_KEY not found in environment variables")
        }
        
        // Create the status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        // Set the waveform icon
        if let button = statusItem.button {
            button.image = defaultWaveformImage()
        }
        
        // Create menu
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "View History...", action: #selector(showTranscriptionHistory), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        // Set default keyboard shortcuts only if not already stored
        let defaults: [(KeyboardShortcuts.Key, KeyboardShortcuts.Name)] = [
            (.c, .startRecording),
            (.a, .showHistory),
            (.s, .readSelectedText),
            (.v, .pasteLastTranscription),
            (.o, .openclawRecording)
        ]
        for (key, name) in defaults {
            if KeyboardShortcuts.getShortcut(for: name) == nil {
                KeyboardShortcuts.setShortcut(.init(key, modifiers: [.command, .option]), for: name)
            }
        }
        
        // Set up keyboard shortcut handlers
        KeyboardShortcuts.onKeyUp(for: .startRecording) { [weak self] in
            guard let self = self else { return }

            // Prevent starting audio recording if OpenClaw recording is active
            if self.openClawRecordingManager?.isRecording == true || self.openClawRecordingManager?.isProcessing == true {
                let notification = NSUserNotification()
                notification.title = "Cannot Start Audio Recording"
                notification.informativeText = "OpenClaw recording is currently active. Stop it first with Cmd+Option+O"
                NSUserNotificationCenter.default.deliver(notification)
                print("⚠️ Blocked audio recording - OpenClaw recording is active")
                return
            }

            // If about to start a fresh recording, make sure any previous
            // processing indicator is stopped and UI is reset.
            if !self.audioManager.isRecording {
                self.stopTranscriptionIndicator()
            }
            self.audioManager.toggleRecording()
        }
        
        KeyboardShortcuts.onKeyUp(for: .showHistory) { [weak self] in
            self?.showTranscriptionHistory()
        }
        
        KeyboardShortcuts.onKeyUp(for: .readSelectedText) { [weak self] in
            self?.handleReadSelectedTextToggle()
        }

        KeyboardShortcuts.onKeyUp(for: .pasteLastTranscription) { [weak self] in
            self?.pasteLastTranscription()
        }

        KeyboardShortcuts.onKeyUp(for: .openclawRecording) { [weak self] in
            guard let self = self else { return }

            // Mutual exclusion with WhisperKit recording
            if self.audioManager.isRecording {
                let notification = NSUserNotification()
                notification.title = "Cannot Start OpenClaw Recording"
                notification.informativeText = "WhisperKit recording is currently active. Stop it first with Cmd+Option+Z"
                NSUserNotificationCenter.default.deliver(notification)
                print("OpenClaw: blocked - WhisperKit recording is active")
                return
            }

            guard let recordingManager = self.openClawRecordingManager else {
                let notification = NSUserNotification()
                notification.title = "OpenClaw Not Configured"
                notification.informativeText = "Configure OpenClaw credentials in Settings → OpenClaw"
                NSUserNotificationCenter.default.deliver(notification)
                return
            }

            if !recordingManager.isRecording {
                self.stopTranscriptionIndicator()
            }
            recordingManager.toggleRecording()
        }

        // Set up audio manager
        audioManager = AudioTranscriptionManager()
        audioManager.delegate = self

        // Initialize OpenClaw if configured (from UserDefaults)
        if let openClawURL = UserDefaults.standard.string(forKey: "openClaw.url"), !openClawURL.isEmpty,
           let openClawToken = UserDefaults.standard.string(forKey: "openClaw.token"), !openClawToken.isEmpty {
            let sessionKey = UserDefaults.standard.string(forKey: "openClaw.sessionKey") ?? "voice-assistant"
            let password = UserDefaults.standard.string(forKey: "openClaw.password")
            connectOpenClaw(url: openClawURL, token: openClawToken, password: password, sessionKey: sessionKey)
        }

        // Set up double-tap-and-hold Option key for OpenClaw push-to-talk
        setupOptionDoubleTapMonitor()

        // Check downloaded models at startup (in background)
        Task {
            await ModelStateManager.shared.checkDownloadedModels()
            print("Model check completed at startup")

            // Load the initially selected model based on engine
            switch ModelStateManager.shared.selectedEngine {
            case .whisperKit:
                if let selectedModel = ModelStateManager.shared.selectedModel {
                    _ = await ModelStateManager.shared.loadModel(selectedModel)
                }
            case .parakeet:
                await ModelStateManager.shared.loadParakeetModel()
            }

            // Auto-load Kokoro TTS if previously downloaded
            let kokoroPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/fluidaudio/Models/kokoro")
            if FileManager.default.fileExists(atPath: kokoroPath.path) {
                print("Kokoro TTS: found on disk, auto-loading...")
                await ModelStateManager.shared.loadKokoroTtsModel()
            }
        }

        // Observe WhisperKit model selection changes
        modelCancellable = ModelStateManager.shared.$selectedModel
            .dropFirst() // Skip the initial value
            .sink { selectedModel in
                guard let selectedModel = selectedModel else { return }
                // Only load if WhisperKit is the selected engine
                guard ModelStateManager.shared.selectedEngine == .whisperKit else { return }
                Task {
                    // Load the new model
                    _ = await ModelStateManager.shared.loadModel(selectedModel)
                }
            }

        // Observe engine changes - only handle memory management, not loading
        // Loading is triggered by user actions (selecting/downloading models)
        engineCancellable = ModelStateManager.shared.$selectedEngine
            .dropFirst() // Skip the initial value
            .sink { engine in
                switch engine {
                case .whisperKit:
                    // Unload Parakeet to free memory
                    ModelStateManager.shared.unloadParakeetModel()
                case .parakeet:
                    // Unload WhisperKit to free memory
                    ModelStateManager.shared.unloadWhisperKitModel()
                }
            }

        // Note: Parakeet version changes don't auto-load
        // User must click to download/select a specific version
    }
    

    
    @objc func openSettings() {
        if unifiedWindow == nil {
            unifiedWindow = UnifiedManagerWindow()
        }
        unifiedWindow?.showWindow(tab: .settings)
    }
    
    func connectOpenClaw(url: String, token: String, password: String?, sessionKey: String) {
        // Tear down existing connection if any
        disconnectOpenClaw()

        let manager = OpenClawManager(url: url, token: token, password: password, sessionKey: sessionKey)
        openClawManager = manager
        openClawRecordingManager = OpenClawRecordingManager(
            openClawManager: manager,
            streamingPlayer: streamingPlayer,
            audioCollector: audioCollector
        )
        openClawRecordingManager?.delegate = self
        if openClawOverlay == nil {
            openClawOverlay = OpenClawOverlayWindow()
            openClawOverlay?.onCancel = { [weak self] in
                self?.openClawRecordingManager?.cancelRecording()
                self?.stopWaveformAnimation()
            }
        }
        manager.connect()
        print("OpenClaw: initialized (url=\(url))")
    }

    func disconnectOpenClaw() {
        openClawManager?.disconnect()
        openClawManager = nil
        openClawRecordingManager = nil
    }

    // MARK: - Double-Tap-and-Hold Option Keys (Push-to-Talk)
    // Left Option → OpenClaw, Right Option → STT Recording

    private func setupOptionDoubleTapMonitor() {
        let leftOptionKeyCode: UInt16 = 58
        let rightOptionKeyCode: UInt16 = 61

        optionDoubleTapMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self else { return }

            let optionDown = event.modifierFlags.contains(.option)

            // Ignore if other modifiers are held (Cmd, Ctrl, Shift) — don't interfere with shortcuts
            let otherModifiers: NSEvent.ModifierFlags = [.command, .control, .shift]
            if !event.modifierFlags.intersection(otherModifiers).isEmpty {
                self.resetLeftOptionState()
                self.resetRightOptionState()
                return
            }

            let now = ProcessInfo.processInfo.systemUptime

            if event.keyCode == leftOptionKeyCode {
                self.handleDoubleTapHold(
                    optionDown: optionDown, now: now,
                    state: &self.leftOptionState,
                    firstPressTime: &self.leftOptionFirstPressTime,
                    firstReleaseTime: &self.leftOptionFirstReleaseTime,
                    resetTimer: &self.leftOptionResetTimer,
                    onStart: { self.startOpenClawPushToTalk() },
                    onStop: { self.stopOpenClawPushToTalk() },
                    onReset: { self.resetLeftOptionState() }
                )
            } else if event.keyCode == rightOptionKeyCode {
                self.handleDoubleTapHold(
                    optionDown: optionDown, now: now,
                    state: &self.rightOptionState,
                    firstPressTime: &self.rightOptionFirstPressTime,
                    firstReleaseTime: &self.rightOptionFirstReleaseTime,
                    resetTimer: &self.rightOptionResetTimer,
                    onStart: { self.startSTTPushToTalk() },
                    onStop: { self.stopSTTPushToTalk() },
                    onReset: { self.resetRightOptionState() }
                )
            }
        }
    }

    private func handleDoubleTapHold(
        optionDown: Bool, now: TimeInterval,
        state: inout OptionDoubleTapState,
        firstPressTime: inout TimeInterval,
        firstReleaseTime: inout TimeInterval,
        resetTimer: inout Timer?,
        onStart: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onReset: @escaping () -> Void
    ) {
        switch state {
        case .idle:
            if optionDown {
                state = .firstPress
                firstPressTime = now
                resetTimer?.invalidate()
                resetTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
                    onReset()
                }
            }

        case .firstPress:
            if !optionDown {
                let tapDuration = now - firstPressTime
                if tapDuration < 0.3 {
                    state = .firstRelease
                    firstReleaseTime = now
                    resetTimer?.invalidate()
                    resetTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                        onReset()
                    }
                } else {
                    onReset()
                }
            }

        case .firstRelease:
            if optionDown {
                let gap = now - firstReleaseTime
                if gap < 0.4 {
                    resetTimer?.invalidate()
                    resetTimer = nil
                    state = .recording
                    onStart()
                } else {
                    onReset()
                }
            }

        case .recording:
            if !optionDown {
                state = .idle
                onStop()
            }
        }
    }

    private func resetLeftOptionState() {
        leftOptionState = .idle
        leftOptionResetTimer?.invalidate()
        leftOptionResetTimer = nil
    }

    private func resetRightOptionState() {
        rightOptionState = .idle
        rightOptionResetTimer?.invalidate()
        rightOptionResetTimer = nil
    }

    private func startOpenClawPushToTalk() {
        if audioManager.isRecording {
            print("OpenClaw PTT: blocked - audio recording is active")
            resetLeftOptionState()
            return
        }

        guard let recordingManager = openClawRecordingManager else {
            print("OpenClaw PTT: not configured")
            resetLeftOptionState()
            return
        }

        if recordingManager.isRecording || recordingManager.isProcessing {
            print("OpenClaw PTT: already recording/processing")
            resetLeftOptionState()
            return
        }

        print("OpenClaw PTT: started (double-tap-hold)")
        stopTranscriptionIndicator()
        recordingManager.toggleRecording()
    }

    private func stopOpenClawPushToTalk() {
        guard let recordingManager = openClawRecordingManager, recordingManager.isRecording else {
            return
        }

        print("OpenClaw PTT: released — stopping")
        recordingManager.toggleRecording()
    }

    private func startSTTPushToTalk() {
        if openClawRecordingManager?.isRecording == true || openClawRecordingManager?.isProcessing == true {
            print("STT PTT: blocked - OpenClaw recording is active")
            resetRightOptionState()
            return
        }

        if audioManager.isRecording {
            print("STT PTT: already recording")
            resetRightOptionState()
            return
        }

        print("STT PTT: started (double-tap-hold)")
        sttPushToTalkActive = true
        stopTranscriptionIndicator()
        audioManager.toggleRecording()
    }

    private func stopSTTPushToTalk() {
        guard audioManager.isRecording else { return }

        print("STT PTT: released — stopping")
        audioManager.toggleRecording()
    }

    @discardableResult
    private func ensureAudioOverlay() -> AudioTranscriptionOverlayWindow {
        if audioOverlay == nil {
            audioOverlay = AudioTranscriptionOverlayWindow()
        }
        return audioOverlay!
    }

    @objc func showTranscriptionHistory() {
        if historyWindow == nil {
            historyWindow = TranscriptionHistoryWindow()
        }
        historyWindow?.showWindow()
    }
    
    func handleReadSelectedTextToggle() {
        NSLog("TTS: handleReadSelectedTextToggle called, isCurrentlyPlaying=\(isCurrentlyPlaying)")

        // If currently playing, stop the audio
        if isCurrentlyPlaying {
            stopCurrentPlayback()
            return
        }

        // Otherwise, start reading selected text
        readSelectedText()
    }


    func pasteLastTranscription() {
        // Get the most recent transcription from history
        guard let lastEntry = TranscriptionHistory.shared.getEntries().first else {
            let notification = NSUserNotification()
            notification.title = "No Transcription Available"
            notification.informativeText = "No transcription history found"
            NSUserNotificationCenter.default.deliver(notification)
            print("⚠️ No transcription history to paste")
            return
        }

        // Paste the last transcription at cursor
        pasteTextAtCursor(lastEntry.text)

        let notification = NSUserNotification()
        notification.title = "Pasted Last Transcription"
        notification.informativeText = lastEntry.text.prefix(100) + (lastEntry.text.count > 100 ? "..." : "")
        NSUserNotificationCenter.default.deliver(notification)
        print("📋 Pasted last transcription: \(lastEntry.text.prefix(50))...")
    }

    func stopCurrentPlayback() {
        print("🛑 Stopping audio playback")

        // Cancel the current streaming task
        currentStreamingTask?.cancel()
        currentStreamingTask = nil

        // Stop Kokoro NSSound playback
        currentPlayingSound?.stop()
        currentPlayingSound = nil

        // Stop the Gemini audio player
        streamingPlayer?.stopAudioEngine()

        // Reset playing state
        isCurrentlyPlaying = false
        stopWaveformAnimation()
        
        let notification = NSUserNotification()
        notification.title = "Audio Stopped"
        notification.informativeText = "Text-to-speech playback stopped"
        NSUserNotificationCenter.default.deliver(notification)
    }
    
    func getSelectedTextViaAccessibility() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard result == .success, let element = focusedElement else { return nil }

        var selectedText: AnyObject?
        let textResult = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedText)
        guard textResult == .success, let text = selectedText as? String, !text.isEmpty else { return nil }
        return text
    }

    func readSelectedText() {
        guard let selectedText = getSelectedTextViaAccessibility(), !selectedText.isEmpty else {
            NSLog("TTS: no selected text found via Accessibility API")
            let notification = NSUserNotification()
            notification.title = "No Text Selected"
            notification.informativeText = "Please select some text first before using TTS"
            NSUserNotificationCenter.default.deliver(notification)
            return
        }

        NSLog("TTS: got selected text via Accessibility (\(selectedText.count) chars)")

        let hasGemini = audioCollector != nil && streamingPlayer != nil

        isCurrentlyPlaying = true
        startWaveformAnimation()

        currentStreamingTask = Task { [weak self] in
            do {
                // Check for Kokoro inside the task (MainActor-isolated property)
                let ttsManager = await MainActor.run { ModelStateManager.shared.loadedTtsManager }

                if let ttsManager = ttsManager {
                    let wavData = try await ttsManager.synthesize(text: selectedText)
                    guard !Task.isCancelled else { return }

                    let sound = NSSound(data: wavData)
                    await MainActor.run { self?.currentPlayingSound = sound }
                    sound?.play()

                    while sound?.isPlaying == true && !Task.isCancelled {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                } else if hasGemini, let audioCollector = self?.audioCollector, let streamingPlayer = self?.streamingPlayer {
                    try await streamingPlayer.playText(selectedText, audioCollector: audioCollector)
                } else {
                    let notification = NSUserNotification()
                    notification.title = "TTS Not Available"
                    notification.informativeText = "No TTS engine loaded"
                    NSUserNotificationCenter.default.deliver(notification)
                }
            } catch is CancellationError {
                NSLog("TTS: playback cancelled")
            } catch {
                NSLog("TTS: error: \(error)")
                let notification = NSUserNotification()
                notification.title = "TTS Error"
                notification.informativeText = error.localizedDescription
                NSUserNotificationCenter.default.deliver(notification)
            }

            DispatchQueue.main.async {
                self?.isCurrentlyPlaying = false
                self?.currentStreamingTask = nil
                self?.currentPlayingSound = nil
                self?.stopWaveformAnimation()
            }
        }
    }
    
    func defaultWaveformImage() -> NSImage {
        let width: CGFloat = 18
        let height: CGFloat = 18
        let barWidth: CGFloat = 3.0
        let barSpacing: CGFloat = 1.5
        let cornerRadius: CGFloat = 1.5

        let barHeights: [CGFloat] = [8.0, 12.0, 8.0]

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        let totalBarsWidth = 3 * barWidth + 2 * barSpacing
        let startX = (width - totalBarsWidth) / 2

        for i in 0..<3 {
            let x = startX + CGFloat(i) * (barWidth + barSpacing)
            let y = (height - barHeights[i]) / 2
            let rect = NSRect(x: x, y: y, width: barWidth, height: barHeights[i])
            let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            NSColor.black.setFill()
            path.fill()
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    func generateWaveformImage() -> NSImage {
        let width: CGFloat = 18
        let height: CGFloat = 18
        let barWidth: CGFloat = 3.0
        let barSpacing: CGFloat = 1.5
        let cornerRadius: CGFloat = 1.5
        let minBarHeight: CGFloat = 4.0
        let maxBarHeight: CGFloat = 14.0

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        let totalBarsWidth = 3 * barWidth + 2 * barSpacing
        let startX = (width - totalBarsWidth) / 2

        for i in 0..<3 {
            let barHeight = CGFloat.random(in: minBarHeight...maxBarHeight)
            let x = startX + CGFloat(i) * (barWidth + barSpacing)
            let y = (height - barHeight) / 2
            let rect = NSRect(x: x, y: y, width: barWidth, height: barHeight)
            let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            NSColor.black.setFill()
            path.fill()
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    func startWaveformAnimation() {
        // Don't start if already animating or screen recording is active
        if waveformAnimationTimer != nil { return }

        // Show first frame immediately
        if let button = statusItem.button {
            button.title = ""
            button.image = generateWaveformImage()
        }

        waveformAnimationTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if let button = self.statusItem.button {
                button.title = ""
                button.image = self.generateWaveformImage()
            }
        }
    }

    func stopWaveformAnimation() {
        waveformAnimationTimer?.invalidate()
        waveformAnimationTimer = nil

        // Don't update status bar if screen recording is active


        if let button = statusItem.button {
            button.image = defaultWaveformImage()
            button.title = ""
        }
    }

    func updateStatusBarWithLevel(db: Float) {

        startWaveformAnimation()
    }

    func startTranscriptionIndicator() {

        startWaveformAnimation()
    }

    func stopTranscriptionIndicator() {


        // If not currently recording, stop animation and reset.
        // When recording, the live level updates will keep animation going.
        if audioManager?.isRecording != true {
            stopWaveformAnimation()
        }
    }

    

    
    func showTranscriptionNotification(_ text: String) {
        let notification = NSUserNotification()
        notification.title = "Transcription Complete"
        notification.informativeText = text
        notification.subtitle = "Pasted at cursor"
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }
    
    func showTranscriptionError(_ message: String) {
        let notification = NSUserNotification()
        notification.title = "Transcription Error"
        notification.informativeText = message
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }
    
    func pasteTextAtCursor(_ text: String) {
        // Save current clipboard contents first
        let pasteboard = NSPasteboard.general
        let savedTypes = pasteboard.types ?? []
        var savedItems: [NSPasteboard.PasteboardType: Data] = [:]
        
        for type in savedTypes {
            if let data = pasteboard.data(forType: type) {
                savedItems[type] = data
            }
        }
        
        print("📋 Saved \(savedItems.count) clipboard types")
        
        // Set our text to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        // Try to paste
        let source = CGEventSource(stateID: .hidSystemState)
        
        // Create paste event
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
        }
        
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) {
            keyUp.post(tap: .cghidEventTap)
        }
        
        print("✅ Paste command sent")
        
        // After a short delay, check if paste might have failed
        // and show history window for easy manual copying
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            // Get the frontmost app to see where we tried to paste
            let frontmostApp = NSWorkspace.shared.frontmostApplication
            let appName = frontmostApp?.localizedName ?? "Unknown"
            let bundleId = frontmostApp?.bundleIdentifier ?? ""
            
            print("📱 Attempted paste in: \(appName) (\(bundleId))")
            
            // Apps where paste typically fails or doesn't make sense
            let problematicApps = [
                "com.apple.finder",
                "com.apple.dock", 
                "com.apple.systempreferences"
            ]
            
            // Check if the app is known to not accept pastes well
            // OR if the user is in an unusual context
            if problematicApps.contains(bundleId) {
                print("⚠️ Detected potential paste failure - showing history window")
                self?.showHistoryForPasteFailure()
            }
            
            // Restore clipboard
            pasteboard.clearContents()
            for (type, data) in savedItems {
                pasteboard.setData(data, forType: type)
            }
            print("♻️ Restored clipboard")
        }
    }
    
    func showHistoryForPasteFailure() {
        // When paste fails in certain apps, show the history window
        // by simulating the Command+Option+A keyboard shortcut
        let source = CGEventSource(stateID: .hidSystemState)
        
        // Key code for 'A' is 0x00
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x00, keyDown: true) {
            keyDown.flags = [.maskCommand, .maskAlternate]
            keyDown.post(tap: .cghidEventTap)
        }
        
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x00, keyDown: false) {
            keyUp.flags = [.maskCommand, .maskAlternate]
            keyUp.post(tap: .cghidEventTap)
        }
        
        print("📚 Showing history window for paste failure recovery")
    }
    
    // MARK: - AudioTranscriptionManagerDelegate
    
    func audioLevelDidUpdate(db: Float) {
        updateStatusBarWithLevel(db: db)
        ensureAudioOverlay().show(state: .listening)
    }

    func transcriptionDidStart() {
        startTranscriptionIndicator()
        ensureAudioOverlay().show(state: .transcribing)
    }

    func transcriptionDidComplete(text: String) {
        stopTranscriptionIndicator()
        audioOverlay?.dismiss()
        let shouldSendReturn = sttPushToTalkActive
        sttPushToTalkActive = false
        pasteTextAtCursor(text)
        if shouldSendReturn {
            // Simulate Return key after paste completes (slight delay for paste to land)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let source = CGEventSource(stateID: .hidSystemState)
                if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true) {
                    keyDown.post(tap: .cghidEventTap)
                }
                if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false) {
                    keyUp.post(tap: .cghidEventTap)
                }
                print("STT PTT: sent Return key")
            }
        }
        showTranscriptionNotification(text)
    }

    func transcriptionDidFail(error: String) {
        stopTranscriptionIndicator()
        ensureAudioOverlay().showError(error)
        showTranscriptionError(error)
    }

    func recordingWasCancelled() {
        sttPushToTalkActive = false
        // Ensure any processing indicator is stopped
        stopTranscriptionIndicator()
        audioOverlay?.dismiss()
        // Reset the status bar icon
        if let button = statusItem.button {
            button.image = defaultWaveformImage()
            button.title = ""
        }

        // Show notification
        let notification = NSUserNotification()
        notification.title = "Recording Cancelled"
        notification.informativeText = "Recording was cancelled"
        NSUserNotificationCenter.default.deliver(notification)
    }

    func recordingWasSkippedDueToSilence() {
        sttPushToTalkActive = false
        // Ensure any processing indicator is stopped
        stopTranscriptionIndicator()
        audioOverlay?.dismiss()
        // Reset the status bar icon
        if let button = statusItem.button {
            button.image = defaultWaveformImage()
            button.title = ""
        }

        // Optionally show a subtle notification
        let notification = NSUserNotification()
        notification.title = "Recording Skipped"
        notification.informativeText = "Audio was too quiet to transcribe"
        NSUserNotificationCenter.default.deliver(notification)
    }

    // MARK: - OpenClawRecordingManagerDelegate

    func openClawAudioLevelDidUpdate(db: Float) {
        updateStatusBarWithLevel(db: db)
        openClawOverlay?.show(state: .listening)
    }

    func openClawDidStartProcessing() {
        startTranscriptionIndicator()
        openClawOverlay?.show(state: .processing)
    }

    func openClawDidReceiveResponse(text: String) {
        startWaveformAnimation()
        openClawOverlay?.updateResponse(text)
    }

    func openClawDidFinish(question: String, answer: String) {
        stopWaveformAnimation()
        openClawOverlay?.updateResponse(answer)
        openClawOverlay?.complete()
    }

    func openClawDidFail(error: String) {
        stopWaveformAnimation()
        openClawOverlay?.showError(error)
    }

    func openClawRecordingWasCancelled() {
        stopWaveformAnimation()
        openClawOverlay?.dismiss()
    }

    func openClawTTSDidStart() {
        openClawOverlay?.ttsStarted()
    }

    func openClawTTSDidFinish() {
        openClawOverlay?.ttsFinished()
    }

}

// Create and run the app
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Hide dock icon, keep global keyboard shortcuts

// Set the app icon from our custom ICNS file
if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
   let iconImage = NSImage(contentsOf: iconURL) {
    app.applicationIconImage = iconImage
}

// Set up main menu with Edit menu so text fields support copy/paste
let mainMenu = NSMenu()

let appMenuItem = NSMenuItem()
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit Super Voice Assistant", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appMenuItem.submenu = appMenu
mainMenu.addItem(appMenuItem)

let fileMenuItem = NSMenuItem()
let fileMenu = NSMenu(title: "File")
fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
fileMenuItem.submenu = fileMenu
mainMenu.addItem(fileMenuItem)

let editMenuItem = NSMenuItem()
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(NSMenuItem.separator())
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editMenuItem.submenu = editMenu
mainMenu.addItem(editMenuItem)

app.mainMenu = mainMenu

app.run()
