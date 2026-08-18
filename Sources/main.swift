import Cocoa
import SwiftUI
import KeyboardShortcuts
import AVFoundation
import WhisperKit
import SharedModels
import Combine
import ApplicationServices
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

// Find the app icon from either .app bundle Resources or the source directory
func appIconImage() -> NSImage? {
    // In a .app bundle, Bundle.main.resourceURL points to Contents/Resources/
    if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
       let image = NSImage(contentsOf: url) {
        return image
    }
    // Fallback for swift run: look next to the source files
    let sourceIcon = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("AppIcon.icns")
    if let image = NSImage(contentsOf: sourceIcon) {
        return image
    }
    return nil
}

// Environment variable loading
func loadEnvironmentVariables() {
    let fileManager = FileManager.default

    // cwd works for `swift run` from the repo; a Murmur.app launched from
    // Finder has cwd "/" — fall back to the bundle resources and a stable
    // per-user location so GEMINI_API_KEY doesn't silently vanish in the
    // bundled build.
    var candidates = ["\(fileManager.currentDirectoryPath)/.env"]
    if let resourceURL = Bundle.main.resourceURL {
        candidates.append(resourceURL.appendingPathComponent(".env").path)
    }
    if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
        candidates.append(appSupport.appendingPathComponent("Murmur/.env").path)
    }

    guard let envPath = candidates.first(where: { fileManager.fileExists(atPath: $0) }),
          let envContent = try? String(contentsOfFile: envPath) else {
        NSLog("No .env found (looked in: \(candidates.joined(separator: ", ")))")
        return
    }
    NSLog("Loading environment from \(envPath)")

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
    static let podcastToggle = Self("podcastToggle")
    static let draftEditing = Self("draftEditing")
    static let captureCall = Self("captureCall")
}

/// A single physical modifier-key event. The global and local event monitors can each deliver
/// the same event; two distinct events never share a hardware timestamp.
struct OptionEventKey: Equatable {
    let keyCode: UInt16
    let timestamp: TimeInterval
}

enum OptionDoubleTapState {
    case idle
    case firstPress
    case firstRelease
    case recording       // double-tap held — release stops recording
    case recordingToggle // double-tap released — next tap stops recording

    /// Recording with no Option key held down — the user's hands are free.
    var isHandsFreeRecording: Bool {
        if case .recordingToggle = self { return true }
        return false
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, AudioTranscriptionManagerDelegate, OpenClawRecordingManagerDelegate, PodcastManagerDelegate, ReadAloudManagerDelegate, DraftEditingManagerDelegate, CallCaptureManagerDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var settingsWindow: SettingsWindowController?
    private var unifiedWindow: UnifiedManagerWindow?
    private var historyWindow: TranscriptionHistoryWindow?

    private var displayTimer: Timer?
    private var modelCancellable: AnyCancellable?
    private var engineCancellable: AnyCancellable?
    private var parakeetVersionCancellable: AnyCancellable?
    var waveformAnimationTimer: Timer?
    var audioManager: AudioTranscriptionManager!
    var audioOverlay: AudioTranscriptionOverlayWindow?
    var streamingPlayer: GeminiStreamingPlayer?
    var audioCollector: GeminiAudioCollector?
    var isCurrentlyPlaying = false
    var currentStreamingTask: Task<Void, Never>?
    var currentPlayingSound: NSSound?
    var openClawManagerPublic: OpenClawManager? { openClawManager }
    var openClawManager: OpenClawManager?
    var openClawRecordingManager: OpenClawRecordingManager?
    var openClawOverlay: OpenClawOverlayWindow?
    // Auto-mic loop after OpenClaw answers: when TTS finishes, optionally
    // re-open the mic with a distinct tone so the user can keep the
    // conversation going hands-free. State variables track the deferred
    // fire (between TTS-end and tone-finishes), the live recording, the
    // dead-start timer (no voice → silent cancel), and the per-utterance
    // silence timer (voice detected then quiet → stop + transcribe).
    var openClawAutoMicFireWorkItem: DispatchWorkItem?
    var openClawAutoMicActive = false
    var openClawAutoMicVoiceDetected = false
    var openClawAutoMicDeadStartTimer: Timer?
    var openClawAutoMicSilenceTimer: Timer?
    static let openClawAutoMicDeadStartSeconds: TimeInterval = 3.5
    static let openClawAutoMicSilenceSeconds: TimeInterval = 4.0
    static let openClawAutoMicVoiceThresholdDb: Float = -40.0
    // Status bar items showing live OpenClaw state + interaction hint.
    // Updated by refreshOpenClawStatusHint() whenever OpenClaw transitions.
    var openClawStatusMenuItem: NSMenuItem?
    var openClawHintMenuItem: NSMenuItem?
    var optionDoubleTapMonitor: Any?
    var optionDoubleTapLocalMonitor: Any?
    var leftOptionState: OptionDoubleTapState = .idle
    var leftOptionFirstPressTime: TimeInterval = 0
    var leftOptionFirstReleaseTime: TimeInterval = 0
    var leftOptionHandsFreeArmedAt: TimeInterval = 0
    var leftOptionResetTimer: Timer?
    var rightOptionState: OptionDoubleTapState = .idle
    var rightOptionFirstPressTime: TimeInterval = 0
    var rightOptionFirstReleaseTime: TimeInterval = 0
    var rightOptionHandsFreeArmedAt: TimeInterval = 0
    var rightOptionResetTimer: Timer?
    /// Identifies one physical key event, so an echo from the second monitor can be dropped.
    var lastOptionEventKey: OptionEventKey?
    /// Invalidates deferred start work (tone, overlay transition) from a superseded PTT session.
    var sttStartGeneration: Int = 0
    var podcastManager: PodcastManager?
    var podcastOverlay: PodcastOverlayWindow?
    var podcastInterruptActive = false
    // Tracks whether the current podcast session has already been persisted
    // to TranscriptionHistory — reset on each new startSession / dismiss.
    var savedCurrentPodcastToHistory = false
    var sttPushToTalkActive = false
    var bluetoothWarmingUp = false
    var sttPushToTalkStartTime: Date?
    var sttPushToTalkTargetApp: NSRunningApplication?
    var sttPushToTalkTargetWindow: AXUIElement?
    // Auto-record silence handling: when recording starts right after a Claude
    // recap (not when user triggered PTT manually), auto-cancel if the user
    // never speaks. Prevents the queue from stalling on an unanswered recap.
    var sttAutoRecordAfterRecap = false
    var sttSilenceTimeoutTimer: Timer?
    // Recording starts after the start-tone delay (~0.4s wired). If the user
    // releases the key inside that window the stop used to be dropped (guard
    // on isRecording), then the deferred start fired anyway — leaving the mic
    // open with the PTT state machine already idle ("wedged until restart").
    // Keeping the deferred start in a work item lets the stop cancel it.
    var sttPendingStartWorkItem: DispatchWorkItem?
    var openClawPendingStartWorkItem: DispatchWorkItem?
    static let sttDeadStartTimeoutSeconds: TimeInterval = 3.5
    static let sttVoiceDetectionThresholdDb: Float = -40.0
    // Tracks whether the current recording has captured at least one
    // above-threshold sample. Used to distinguish "user never spoke" (cancel)
    // from "user spoke and then went silent" (stop + transcribe).
    var sttHasCapturedVoice = false
    var readAloudManager: ReadAloudManager?
    var readAloudOverlay: ReadAloudOverlayWindow?
    var readAloudInterruptActive = false
    var pendingAutoRecordAfterReadAloud = false
    var recapTargetApp: NSRunningApplication?
    var recapTargetWindow: AXUIElement?

    // FIFO queue for Claude Code recap requests arriving via /api/v1/read-aloud.
    // Audio device is single-user: TTS → STT → paste for one recap runs to
    // completion before the next pops. Queue survives only in-memory.
    struct QueuedRecap {
        let id: UUID
        let text: String
        let autoRecordAfter: Bool
        let targetApp: NSRunningApplication?
        let targetWindow: AXUIElement?
    }
    var recapQueue: [QueuedRecap] = []
    var draftEditingManager: DraftEditingManager?
    var draftEditingOverlay: DraftEditingOverlayWindow?
    var draftEditInterruptActive = false
    var cursorAnchoredOverlay: CursorAnchoredOverlayWindow?
    var httpServer: MurmurHTTPServer?
    var callCaptureManager: CallCaptureManager?
    var callCaptureOverlay: CallCaptureOverlayWindow?
    var captureSubmenu: NSMenu?
    // Whether the current/last capture session should transcribe on stop.
    // Set at start time: HTTP uses the request's `transcribe`; hotkey/menu use
    // the `callCapture.autoTranscribe` default.
    var captureTranscribeOnStop: Bool = true
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load environment variables
        loadEnvironmentVariables()

        // Ask for notification permission up front (bundled builds) so the
        // first error/status notification isn't dropped mid-authorization.
        AppNotifier.requestAuthorizationIfNeeded()

        // Check accessibility permissions (needed for paste via CGEvent)
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        if !trusted {
            print("⚠️ Accessibility permission not granted — paste will not work until enabled in System Settings")
        } else {
            print("✅ Accessibility permission granted")
        }

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
        // Header items show the live OpenClaw state + interaction hint at the
        // top of the menu. Held by reference so refreshOpenClawStatusHint()
        // can update them without rebuilding the menu.
        let openClawStatusItem = NSMenuItem(title: "OpenClaw: idle", action: nil, keyEquivalent: "")
        openClawStatusItem.isEnabled = false
        let openClawHintItem = NSMenuItem(title: "Double-tap Left Option to talk", action: nil, keyEquivalent: "")
        openClawHintItem.isEnabled = false
        menu.addItem(openClawStatusItem)
        menu.addItem(openClawHintItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "View History...", action: #selector(showTranscriptionHistory), keyEquivalent: "h"))

        // Capture Call submenu — repopulated on open via NSMenuDelegate.
        let captureItem = NSMenuItem(title: "Capture Call", action: nil, keyEquivalent: "")
        let captureMenu = NSMenu(title: "Capture Call")
        captureMenu.delegate = self
        captureItem.submenu = captureMenu
        captureSubmenu = captureMenu
        menu.addItem(captureItem)

        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        self.openClawStatusMenuItem = openClawStatusItem
        self.openClawHintMenuItem = openClawHintItem
        refreshOpenClawStatusHint()

        // Set default keyboard shortcuts only if not already stored
        let defaults: [(KeyboardShortcuts.Key, KeyboardShortcuts.Name)] = [
            (.c, .startRecording),
            (.a, .showHistory),
            (.s, .readSelectedText),
            (.v, .pasteLastTranscription),
            (.o, .openclawRecording),
            (.p, .podcastToggle),
            (.d, .draftEditing),
            (.h, .captureCall)
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
                AppNotifier.notify(title: "Cannot Start Audio Recording", body: "OpenClaw recording is currently active. Stop it first with Cmd+Option+O")
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
                let sttShortcut = KeyboardShortcuts.getShortcut(for: .startRecording).map { "\($0)" } ?? "Cmd+Option+C"
                AppNotifier.notify(title: "Cannot Start OpenClaw Recording", body: "STT recording is currently active. Stop it first with \(sttShortcut)")
                print("OpenClaw: blocked - WhisperKit recording is active")
                return
            }

            guard let recordingManager = self.openClawRecordingManager else {
                AppNotifier.notify(title: "OpenClaw Not Configured", body: "Configure OpenClaw credentials in Settings → OpenClaw")
                return
            }

            if !recordingManager.isRecording {
                self.stopTranscriptionIndicator()
                // If a follow-up auto-mic is queued (or running) and the user
                // hits the manual hotkey, treat that as taking over — cancel
                // pending auto-mic so we don't double-trigger.
                self.cancelOpenClawAutoMicPending()
                // Cut any active TTS so the manual recording can begin
                // immediately, mirroring the left-Option interrupt behavior.
                if recordingManager.isAnswering {
                    recordingManager.cancelStreamingTTS()
                }
            }
            recordingManager.toggleRecording()
        }

        KeyboardShortcuts.onKeyUp(for: .podcastToggle) { [weak self] in
            NSLog("Podcast: Cmd+Opt+P pressed")
            self?.togglePodcast()
        }

        KeyboardShortcuts.onKeyUp(for: .draftEditing) { [weak self] in
            NSLog("DraftEditing: Cmd+Opt+D pressed")
            self?.toggleDraftEditing()
        }

        KeyboardShortcuts.onKeyUp(for: .captureCall) { [weak self] in
            NSLog("CallCapture: Cmd+Opt+H pressed")
            self?.toggleCallCapture()
        }

        // Log current podcast shortcut binding
        if let shortcut = KeyboardShortcuts.getShortcut(for: .podcastToggle) {
            print("Podcast shortcut registered: \(shortcut)")
        } else {
            print("Podcast shortcut: NOT SET — setting default now")
            KeyboardShortcuts.setShortcut(.init(.p, modifiers: [.command, .option]), for: .podcastToggle)
        }

        // Set up HTTP server for editor integration
        setupHTTPServer()

        // Set up audio manager
        audioManager = AudioTranscriptionManager()
        audioManager.delegate = self

        // Set up call capture (process tap + mic)
        let capture = CallCaptureManager()
        capture.delegate = self
        callCaptureManager = capture
        callCaptureOverlay = CallCaptureOverlayWindow(manager: capture)
        callCaptureOverlay?.onStop = { [weak self] in
            self?.stopCallCapture()
        }

        // Initialize OpenClaw if configured (URL in UserDefaults, secrets in
        // SecretsStore — Keychain for bundled builds)
        if let openClawURL = UserDefaults.standard.string(forKey: "openClaw.url"), !openClawURL.isEmpty,
           let openClawToken = SecretsStore.get("openClaw.token"), !openClawToken.isEmpty {
            let sessionKey = UserDefaults.standard.string(forKey: "openClaw.sessionKey") ?? "voice-assistant"
            let password = SecretsStore.get("openClaw.password")
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

        // First launch: ask about launch at login
        if !UserDefaults.standard.bool(forKey: "hasShownLaunchAtLoginPrompt") {
            UserDefaults.standard.set(true, forKey: "hasShownLaunchAtLoginPrompt")
            DispatchQueue.main.async {
                self.showLaunchAtLoginPrompt()
            }
        }
    }
    

    
    @objc func openSettings() {
        if unifiedWindow == nil {
            unifiedWindow = UnifiedManagerWindow()
        }
        unifiedWindow?.showWindow(tab: .general)
    }

    func showLaunchAtLoginPrompt() {
        let alert = NSAlert()
        alert.messageText = "Launch Murmur at Login?"
        alert.informativeText = "Would you like Murmur to start automatically when you log in to your Mac? You can change this later in Settings → General."
        alert.alertStyle = .informational
        if let iconImage = appIconImage() {
            alert.icon = iconImage
        }
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Not Now")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            do {
                try SMAppService.mainApp.register()
                print("✅ Launch at login enabled")
            } catch {
                print("Failed to enable launch at login: \(error)")
            }
        }
    }
    

    var sttAutoStopTimer: Timer?

    @objc func showTranscriptionHistory() {
        if historyWindow == nil {
            historyWindow = TranscriptionHistoryWindow()
        }
        historyWindow?.showWindow()
    }
    




    

    

    

    
    
    

    lazy var promptRefinementClient = LLMClient()














}

// Create and run the app
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Hide dock icon, keep global keyboard shortcuts

// Set the app icon from our custom ICNS file
if let iconImage = appIconImage() {
    app.applicationIconImage = iconImage
}

// Set up main menu with Edit menu so text fields support copy/paste
let mainMenu = NSMenu()

let appMenuItem = NSMenuItem()
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
