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

extension AppDelegate {
    // MARK: - HTTP Server

    func setupHTTPServer() {
        let server = MurmurHTTPServer()

        server.get("/api/v1/health") { _ in
            return (200, MurmurHTTPServer.jsonResponse(["ok": true, "version": "1.0"]))
        }

        // MARK: Call capture (Phase B1)

        server.post("/api/v1/capture/start") { [weak self] body in
            let json = MurmurHTTPServer.parseJSON(body) ?? [:]
            let appArg = (json["app"] as? String) ?? "system"
            let includeMic = json["mic"] as? Bool ?? true
            // Transcribe on stop when requested (defaults to the autoTranscribe
            // setting). Workflows remain not-implemented until Phase B3.
            let wantsTranscribe = json["transcribe"] as? Bool
            let wantsWorkflows = json["workflows"] != nil

            let result: (Int, Data) = await MainActor.run {
                guard let self = self, let manager = self.callCaptureManager else {
                    return (500, MurmurHTTPServer.jsonResponse(["error": "Capture manager unavailable"]))
                }
                do {
                    let info = try manager.start(app: appArg, includeMic: includeMic)
                    self.captureTranscribeOnStop = wantsTranscribe ?? self.callCaptureAutoTranscribe
                    self.callCaptureOverlay?.show()
                    var payload: [String: Any] = [
                        "sessionId": info.id,
                        "app": info.app,
                        "directory": info.directory.path,
                        "mic": info.micFile != nil,
                        "transcribe": self.captureTranscribeOnStop
                    ]
                    if wantsWorkflows { payload["workflows"] = "not-implemented" }
                    return (200, MurmurHTTPServer.jsonResponse(payload))
                } catch let error as CallCaptureError {
                    // No alert from the HTTP path — a modal would block the main
                    // thread and hang the API caller. Guidance goes in the body.
                    if case .permissionDenied = error {
                        return (409, MurmurHTTPServer.jsonResponse([
                            "error": error.localizedDescription,
                            "guidance": "Enable Murmur under System Settings > Privacy & Security > Screen & System Audio Recording, then retry."
                        ]))
                    }
                    return (409, MurmurHTTPServer.jsonResponse(["error": error.localizedDescription]))
                } catch {
                    return (500, MurmurHTTPServer.jsonResponse(["error": error.localizedDescription]))
                }
            }
            return result
        }

        server.post("/api/v1/capture/stop") { [weak self] _ in
            let result: (Int, Data) = await MainActor.run {
                guard let self = self, let manager = self.callCaptureManager else {
                    return (500, MurmurHTTPServer.jsonResponse(["error": "Capture manager unavailable"]))
                }
                // stop() fires callCaptureDidFinish → overlay + transcription.
                guard let info = manager.stop() else {
                    return (409, MurmurHTTPServer.jsonResponse(["error": "No capture in progress"]))
                }
                var files: [String: Any] = [:]
                if let app = info.appFile { files["app"] = app.path }
                if let mic = info.micFile { files["mic"] = mic.path }
                return (200, MurmurHTTPServer.jsonResponse([
                    "sessionId": info.id,
                    "directory": info.directory.path,
                    "files": files,
                    "transcribe": self.captureTranscribeOnStop
                ]))
            }
            return result
        }

        // MARK: Transcription pipeline (Phase B2)

        server.post("/api/v1/transcribe") { body in
            let json = MurmurHTTPServer.parseJSON(body) ?? [:]
            var paths: [URL] = []
            if let files = json["files"] as? [String] {
                paths = files.map { URL(fileURLWithPath: $0) }
            } else if let filePath = json["filePath"] as? String {
                paths = [URL(fileURLWithPath: filePath)]
            }
            let wantsWorkflows = json["workflows"] != nil

            guard !paths.isEmpty else {
                return (400, MurmurHTTPServer.jsonResponse(["error": "Provide `filePath` or `files`"]))
            }
            for p in paths where !FileManager.default.isReadableFile(atPath: p.path) {
                return (400, MurmurHTTPServer.jsonResponse(["error": "File not readable: \(p.path)"]))
            }

            let result: (Int, Data) = await MainActor.run {
                do {
                    let session = try CallTranscriptionRunner.shared.transcribeFiles(paths)
                    var payload: [String: Any] = [
                        "sessionId": session.id,
                        "directory": session.dir.path
                    ]
                    if wantsWorkflows { payload["workflows"] = "not-implemented" }
                    return (202, MurmurHTTPServer.jsonResponse(payload))
                } catch {
                    return (400, MurmurHTTPServer.jsonResponse(["error": error.localizedDescription]))
                }
            }
            return result
        }

        server.get("/api/v1/sessions") { _ in
            let list: [[String: Any]] = await MainActor.run {
                CallTranscriptionRunner.shared.listSessions()
            }
            return (200, MurmurHTTPServer.jsonResponse(["sessions": list]))
        }

        server.getPrefix("/api/v1/sessions/") { path, _ in
            let id = String(path.dropFirst("/api/v1/sessions/".count))
                .removingPercentEncoding ?? ""
            // Reject empty ids and path traversal (the id is used as a directory name).
            guard !id.isEmpty, !id.contains("/"), !id.contains("..") else {
                return (404, MurmurHTTPServer.jsonResponse(["error": "Invalid session id"]))
            }
            let data: Data? = await MainActor.run {
                CallTranscriptionRunner.shared.metadataJSON(forSessionId: id)
            }
            if let data {
                return (200, data)
            }
            return (404, MurmurHTTPServer.jsonResponse(["error": "Unknown session \(id)"]))
        }

        server.get("/api/v1/capture/status") { [weak self] _ in
            let result: (Int, Data) = await MainActor.run {
                guard let self = self, let manager = self.callCaptureManager else {
                    return (200, MurmurHTTPServer.jsonResponse(["state": "idle"]))
                }
                let snap = manager.statusSnapshot()
                var payload: [String: Any] = [
                    "state": snap.state,
                    "elapsedSeconds": snap.elapsedSeconds
                ]
                payload["sessionId"] = snap.sessionId ?? NSNull()
                payload["app"] = snap.app ?? NSNull()
                return (200, MurmurHTTPServer.jsonResponse(payload))
            }
            return result
        }

        server.get("/api/v1/draft/status") { [weak self] _ in
            guard let manager = self?.draftEditingManager, manager.isActive,
                  let doc = manager.document else {
                return (200, MurmurHTTPServer.jsonResponse([
                    "active": false
                ]))
            }
            return (200, MurmurHTTPServer.jsonResponse([
                "active": true,
                "sessionId": manager.sessionId.uuidString,
                "currentParagraph": manager.currentParagraphIndex,
                "totalParagraphs": doc.paragraphs.count,
                "state": manager.state.displayName
            ]))
        }

        server.post("/api/v1/draft/start") { [weak self] body in
            guard let json = MurmurHTTPServer.parseJSON(body),
                  let filePath = json["filePath"] as? String else {
                return (400, MurmurHTTPServer.jsonResponse(["error": "Missing filePath"]))
            }

            guard self?.draftEditingManager?.isActive != true else {
                return (409, MurmurHTTPServer.jsonResponse(["error": "Session already active"]))
            }

            let startLine = json["startLine"] as? Int
            let editorName = json["editor"] as? String ?? "textmate"
            let adapter: EditorAdapter = editorName.lowercased() == "obsidian"
                ? ObsidianAdapter()
                : TextMateAdapter()
            await MainActor.run {
                self?.startDraftEditing(filePath: filePath, adapter: adapter, startLine: startLine)
            }

            // Wait briefly for parsing
            try? await Task.sleep(nanoseconds: 500_000_000)

            let paragraphCount = await MainActor.run { self?.draftEditingManager?.document?.paragraphs.count ?? 0 }
            let sessionId = await MainActor.run { self?.draftEditingManager?.sessionId.uuidString ?? "" }

            return (200, MurmurHTTPServer.jsonResponse([
                "sessionId": sessionId,
                "totalParagraphs": paragraphCount
            ]))
        }

        server.post("/api/v1/draft/stop") { [weak self] _ in
            await MainActor.run { self?.stopDraftEditing() }
            return (200, MurmurHTTPServer.jsonResponse(["ok": true]))
        }

        server.post("/api/v1/draft/navigate") { [weak self] body in
            guard let json = MurmurHTTPServer.parseJSON(body),
                  let action = json["action"] as? String else {
                return (400, MurmurHTTPServer.jsonResponse(["error": "Missing action"]))
            }

            await MainActor.run {
                switch action {
                case "next": self?.draftEditingManager?.nextParagraph()
                case "prev": self?.draftEditingManager?.prevParagraph()
                case "goto":
                    if let paragraph = json["paragraph"] as? Int {
                        self?.draftEditingManager?.navigateTo(paragraph: paragraph)
                    }
                default: break
                }
            }

            let current = await MainActor.run { self?.draftEditingManager?.currentParagraphIndex ?? 0 }
            return (200, MurmurHTTPServer.jsonResponse(["currentParagraph": current]))
        }

        server.post("/api/v1/draft/pause") { [weak self] _ in
            await MainActor.run {
                self?.draftEditingManager?.togglePause()
                if let isPaused = self?.draftEditingManager?.isPaused {
                    self?.draftEditingOverlay?.updatePaused(isPaused)
                }
            }
            return (200, MurmurHTTPServer.jsonResponse(["ok": true, "paused": true]))
        }

        server.post("/api/v1/draft/resume") { [weak self] _ in
            await MainActor.run {
                if self?.draftEditingManager?.isPaused == true {
                    self?.draftEditingManager?.togglePause()
                    self?.draftEditingOverlay?.updatePaused(false)
                }
            }
            return (200, MurmurHTTPServer.jsonResponse(["ok": true, "paused": false]))
        }

        server.post("/api/v1/read-aloud") { [weak self] body in
            guard let json = MurmurHTTPServer.parseJSON(body),
                  let rawText = (json["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawText.isEmpty else {
                return (400, MurmurHTTPServer.jsonResponse(["error": "Missing or empty text"]))
            }

            // Respect the user's "Read Claude recap aloud" toggle (Settings →
            // Claude). When off, accept the request but do nothing — so the
            // hook doesn't error and the recap is silently dropped. Defaults
            // to on for setups that predate the toggle.
            let recapEnabled = UserDefaults.standard.object(forKey: "recap.enabled") as? Bool ?? true
            guard recapEnabled else {
                return (200, MurmurHTTPServer.jsonResponse(["ok": true, "skipped": "recap disabled"]))
            }

            let autoRecord = json["autoRecordAfter"] as? Bool ?? false
            let overrideMode = json["preprocess"] as? String
            let mode = overrideMode
                ?? UserDefaults.standard.string(forKey: "recap.preprocessMode")
                ?? "none"

            // Resolve the binding terminal. Prefer PPID chain sent by the hook
            // (so we bind to the actual terminal Claude Code ran in, even if
            // the user has since switched to Outlook/etc). Fall back to the
            // current frontmost app if the chain can't be resolved.
            let sourcePids: [pid_t] = (json["sourcePids"] as? String)?
                .split(separator: ",")
                .compactMap { pid_t($0) } ?? []

            let (capturedApp, capturedWindow): (NSRunningApplication?, AXUIElement?) = await MainActor.run {
                guard autoRecord else { return (nil, nil) }

                let ownPid = ProcessInfo.processInfo.processIdentifier
                var resolved: NSRunningApplication? = nil
                for pid in sourcePids {
                    if pid == ownPid { continue }
                    guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
                    // .regular = normal Dock app. Shells / CLI tools typically
                    // return .prohibited or nil, which we skip.
                    if app.activationPolicy == .regular {
                        resolved = app
                        break
                    }
                }

                let app = resolved ?? NSWorkspace.shared.frontmostApplication
                guard let app = app else { return (nil, nil) }
                NSLog("Recap: bound to \(app.localizedName ?? "?") (pid \(app.processIdentifier), resolved from \(resolved != nil ? "ppid chain" : "frontmost fallback"))")

                // Match the specific terminal window by the shell's cwd.
                // kAXFocusedWindowAttribute alone would hand us whichever
                // window is currently focused in the terminal app — which is
                // wrong when Claude in window B responds while the user is
                // typing in window A. Both Ghostty and Terminal.app expose
                // AXDocument on each window as a file:// URL of the shell's
                // working directory; we match against that.
                let shellCwd = Self.resolveShellCwd(
                    sourcePids: sourcePids,
                    ownPid: ownPid,
                    terminalAppPid: app.processIdentifier
                )
                let window = Self.findTerminalWindow(
                    forAppPid: app.processIdentifier,
                    matchingCwd: shellCwd
                )
                return (app, window)
            }

            let text = await Self.preprocessRecap(rawText, mode: mode)

            // Persist the raw assistant message to history. If the LLM rewrote
            // it into a shorter spoken summary, keep that too so the user can
            // copy either version from the history window.
            let storedSpoken = (text != rawText) ? text : nil

            await MainActor.run {
                // TranscriptionHistory is main-thread-only; every other writer
                // already runs on main.
                TranscriptionHistory.shared.addRecapEntry(rawText, spokenText: storedSpoken)
                guard let self = self else { return }
                // Enqueue rather than clobber: FIFO across parallel Claude
                // terminals. drainRecapQueueIfIdle pops and starts the next
                // entry whenever the audio device becomes free.
                let entry = QueuedRecap(
                    id: UUID(),
                    text: text,
                    autoRecordAfter: autoRecord,
                    targetApp: capturedApp,
                    targetWindow: capturedWindow
                )
                self.recapQueue.append(entry)
                NSLog("Recap: enqueued (queue depth: \(self.recapQueue.count))")
                self.drainRecapQueueIfIdle()
            }

            return (200, MurmurHTTPServer.jsonResponse(["ok": true, "autoRecordAfter": autoRecord, "queued": true]))
        }

        server.post("/api/v1/draft/cursor-sync") { [weak self] body in
            guard let json = MurmurHTTPServer.parseJSON(body),
                  let line = json["line"] as? Int else {
                return (400, MurmurHTTPServer.jsonResponse(["error": "Missing line"]))
            }

            await MainActor.run {
                self?.draftEditingManager?.jumpToCursorLine(line)
            }

            let current = await MainActor.run { self?.draftEditingManager?.currentParagraphIndex ?? 0 }
            return (200, MurmurHTTPServer.jsonResponse(["paragraph": current]))
        }

        // Claude Code PreToolUse hook endpoint. Wire it in ~/.claude/settings.json
        // with "type": "http", "url": "http://127.0.0.1:7878/api/v1/claude/permission-check".
        // When the "auto-approve tool requests" setting is on, we respond with
        // permissionDecision=allow and log the tool call to history for audit.
        // Otherwise respond with permissionDecision=ask to fall through to the
        // normal interactive prompt — and don't log (user will decide manually).
        server.post("/api/v1/claude/permission-check") { body in
            let autoApprove = UserDefaults.standard.bool(forKey: "claude.autoApproveTools")

            guard let json = MurmurHTTPServer.parseJSON(body) else {
                return (400, MurmurHTTPServer.jsonResponse(["error": "Invalid JSON"]))
            }

            let toolName = (json["tool_name"] as? String) ?? "Unknown"
            let toolInput = json["tool_input"] as? [String: Any] ?? [:]
            let preview = Self.previewForToolInput(toolName: toolName, input: toolInput)

            if autoApprove {
                await MainActor.run {
                    TranscriptionHistory.shared.addPermissionEntry(toolName: toolName, inputPreview: preview)
                }
                NSLog("Permission: auto-approved \(toolName) — \(preview.prefix(120))")
                return (200, MurmurHTTPServer.jsonResponse([
                    "hookSpecificOutput": [
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "allow",
                        "permissionDecisionReason": "Auto-approved by Murmur"
                    ] as [String: Any]
                ]))
            } else {
                // Fall through to normal interactive prompt. Return "ask" so
                // Claude Code's own permission UI surfaces.
                return (200, MurmurHTTPServer.jsonResponse([
                    "hookSpecificOutput": [
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "ask"
                    ] as [String: Any]
                ]))
            }
        }

        // GET /api/v1/debug/state — snapshot of the recap queue + audio-busy
        // flags, for diagnosing "hook got 200 but no TTS played" cases. Handy
        // to curl from another machine when the recap pipeline appears stuck.
        server.get("/api/v1/debug/state") { [weak self] _ in
            let state: [String: Any] = await MainActor.run {
                guard let self = self else { return ["error": "no delegate"] }
                var activeText: String? = nil
                if let mgr = self.readAloudManager {
                    activeText = String(mgr.fullText.prefix(120))
                }
                return [
                    "queueDepth": self.recapQueue.count,
                    "isAudioBusy": self.isAudioBusy(),
                    "readAloudActive": self.readAloudManager != nil,
                    "sttPushToTalkActive": self.sttPushToTalkActive,
                    "audioManagerRecording": self.audioManager.isRecording,
                    "openClawRecording": self.openClawRecordingManager?.isRecording ?? false,
                    "openClawProcessing": self.openClawRecordingManager?.isProcessing ?? false,
                    "podcastInterruptActive": self.podcastInterruptActive,
                    "draftEditInterruptActive": self.draftEditInterruptActive,
                    "activeSessionPreview": activeText ?? "",
                    "pendingAutoRecordAfterReadAloud": self.pendingAutoRecordAfterReadAloud
                ]
            }
            return (200, MurmurHTTPServer.jsonResponse(state))
        }

        // POST /api/v1/debug/reset-recap — recovery hatch for a clogged queue.
        // Tears down any active read-aloud or STT session, clears the pending
        // queue, and disarms pending auto-record. Returns what it flushed.
        server.post("/api/v1/debug/reset-recap") { [weak self] _ in
            let result: [String: Any] = await MainActor.run {
                guard let self = self else { return ["error": "no delegate"] }
                let dropped = self.recapQueue.count
                let wasReading = self.readAloudManager != nil
                let wasRecording = self.audioManager.isRecording

                self.recapQueue.removeAll()
                if self.readAloudManager?.isActive == true {
                    self.readAloudManager?.stop()
                }
                self.readAloudOverlay?.dismiss()
                self.readAloudManager = nil
                self.readAloudOverlay = nil
                self.readAloudInterruptActive = false
                self.stopWaveformAnimation()

                if self.audioManager.isRecording {
                    self.audioManager.cancelRecording()
                }

                self.pendingAutoRecordAfterReadAloud = false
                self.recapTargetApp = nil
                self.recapTargetWindow = nil
                self.sttAutoRecordAfterRecap = false
                self.sttSilenceTimeoutTimer?.invalidate()
                self.sttSilenceTimeoutTimer = nil

                NSLog("[Recap] Reset via /debug/reset-recap — dropped=\(dropped), wasReading=\(wasReading), wasRecording=\(wasRecording)")
                return [
                    "ok": true,
                    "droppedFromQueue": dropped,
                    "wasReading": wasReading,
                    "wasRecording": wasRecording
                ]
            }
            return (200, MurmurHTTPServer.jsonResponse(result))
        }

        do {
            let binding: MurmurHTTPServer.BindingMode = UserDefaults.standard.bool(forKey: "claude.exposeToLan")
                ? .allInterfaces
                : .localhostOnly
            try server.start(binding: binding)
            httpServer = server
        } catch {
            NSLog("[HTTP] Failed to start server: \(error)")
        }

        // Restart the HTTP listener whenever the user toggles LAN exposure
        // in the Claude settings tab, so the change takes effect without an
        // app restart.
        NotificationCenter.default.addObserver(
            forName: .claudeExposeToLanDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let binding: MurmurHTTPServer.BindingMode = UserDefaults.standard.bool(forKey: "claude.exposeToLan")
                ? .allInterfaces
                : .localhostOnly
            NSLog("[HTTP] Toggle changed — restarting on \(binding == .allInterfaces ? "0.0.0.0" : "127.0.0.1")")
            self?.httpServer?.restart(binding: binding)
        }
    }

    /// Short, readable preview of a PreToolUse tool_input payload for history
    /// logging. We special-case the common tools so the history shows actual
    /// commands / file paths, not a dump of the JSON blob.
    private static func previewForToolInput(toolName: String, input: [String: Any]) -> String {
        let cap = 300
        func truncate(_ s: String) -> String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count > cap ? String(trimmed.prefix(cap)) + "…" : trimmed
        }
        switch toolName {
        case "Bash":
            return truncate((input["command"] as? String) ?? "")
        case "Edit", "Write", "Read":
            let path = (input["file_path"] as? String) ?? ""
            return truncate(path)
        case "WebFetch":
            return truncate((input["url"] as? String) ?? "")
        case "WebSearch":
            return truncate((input["query"] as? String) ?? "")
        default:
            // Generic fallback: serialize the input compactly
            if let data = try? JSONSerialization.data(withJSONObject: input, options: []),
               let s = String(data: data, encoding: .utf8) {
                return truncate(s)
            }
            return ""
        }
    }
}
