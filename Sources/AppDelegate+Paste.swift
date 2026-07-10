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
    func pasteLastTranscription() {
        // Get the most recent transcription from history
        guard let lastEntry = TranscriptionHistory.shared.getEntries().first else {
            AppNotifier.notify(title: "No Transcription Available", body: "No transcription history found")
            print("⚠️ No transcription history to paste")
            return
        }

        // Paste the last transcription at cursor
        pasteTextAtCursor(lastEntry.text)

        AppNotifier.notify(title: "Pasted Last Transcription", body: lastEntry.text.prefix(100) + (lastEntry.text.count > 100 ? "..." : ""))
        print("📋 Pasted last transcription: \(lastEntry.text.prefix(50))...")
    }

    func getSelectedTextViaAccessibility() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        if result != .success {
            NSLog("Accessibility: failed to get focused element (error: \(result.rawValue))")
        }
        guard result == .success, let element = focusedElement else { return nil }

        var selectedText: AnyObject?
        let textResult = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedText)
        if textResult != .success {
            NSLog("Accessibility: failed to get selected text (error: \(textResult.rawValue))")
        }
        guard textResult == .success, let text = selectedText as? String, !text.isEmpty else { return nil }
        NSLog("Accessibility: got selected text (\(text.count) chars)")
        return text
    }

    /// Simulate Cmd+C to copy the current selection to clipboard, then read it.
    func getSelectedTextViaCopy() -> String? {
        // Save current clipboard content
        let pasteboard = NSPasteboard.general
        let previousContent = pasteboard.string(forType: .string)
        let previousChangeCount = pasteboard.changeCount

        // Simulate Cmd+C
        let src = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true) // 'c' key
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)

        // Wait briefly for the copy to complete
        usleep(100_000) // 100ms

        // Check if clipboard changed
        if pasteboard.changeCount != previousChangeCount,
           let text = pasteboard.string(forType: .string), !text.isEmpty {
            NSLog("Accessibility: got selected text via Cmd+C simulation (\(text.count) chars)")
            return text
        }

        NSLog("Accessibility: Cmd+C simulation did not produce new clipboard content")
        return nil
    }

    /// Paste text into a specific target app/window, switching to it if needed and switching back afterward.
    /// If the target app is no longer running, falls back to the current frontmost window without sending Return.
    func pasteTextIntoApp(_ text: String, targetApp: NSRunningApplication?, targetWindow: AXUIElement? = nil, shouldSendReturn: Bool) {
        let currentFrontmost = NSWorkspace.shared.frontmostApplication
        // Capture current focused window so we can switch back to it
        var currentWindow: AXUIElement?
        if let currentPid = currentFrontmost?.processIdentifier {
            let currentAppElement = AXUIElementCreateApplication(currentPid)
            var windowValue: AnyObject?
            if AXUIElementCopyAttributeValue(currentAppElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success {
                currentWindow = (windowValue as! AXUIElement)
            }
        }

        // Check if target app is still running
        if let target = targetApp, target.isTerminated {
            print("⚠️ Target app \(target.localizedName ?? "Unknown") is no longer running — falling back to frontmost")
            pasteTextAtCursor(text)
            // No Return key on fallback — let user review the pasted text
            return
        }

        // Determine if we need to switch: either different app or different window within same app
        var needsSwitch = false
        if let target = targetApp {
            if target.processIdentifier != currentFrontmost?.processIdentifier {
                // Different app entirely
                needsSwitch = true
            } else if let targetWin = targetWindow, let curWin = currentWindow {
                // Same app — check if it's a different window
                needsSwitch = !CFEqual(targetWin, curWin)
            }
        }

        if needsSwitch, let target = targetApp {
            print("🔀 Switching to target window in: \(target.localizedName ?? "Unknown") for paste")
            if let targetWin = targetWindow {
                Self.focusWindow(targetWin)
            }
            target.activate(options: [.activateAllWindows])

            // Wait for activation — 0.3s gives deeply backgrounded apps
            // (e.g. Ghostty spaces away) time to come forward before we paste.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                // Verify the target actually came forward. If activation
                // failed (another app stole focus, Mission Control was open,
                // etc.), don't blast Cmd+V into the wrong window.
                let nowFrontmost = NSWorkspace.shared.frontmostApplication
                if nowFrontmost?.processIdentifier != target.processIdentifier {
                    print("⚠️ Target \(target.localizedName ?? "?") didn't come forward — frontmost is \(nowFrontmost?.localizedName ?? "?"). Skipping paste; text is on the clipboard.")
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                    self?.notifyPasteSkipped(target: target.localizedName ?? "the target window")
                    return
                }

                // Verify the right WINDOW is focused, not just the right app.
                // In multi-window apps (Ghostty, Terminal), AXRaiseAction
                // alone doesn't always transfer key-window status — the
                // previously-active window can remain main. If we detect a
                // mismatch, re-focus the target once and give it 150ms before
                // pasting.
                if let targetWin = targetWindow,
                   Self.focusedWindow(forAppPid: target.processIdentifier).map({ !CFEqual($0, targetWin) }) ?? false {
                    let wantTitle = Self.axTitle(targetWin) ?? "?"
                    let gotTitle = Self.focusedWindow(forAppPid: target.processIdentifier).flatMap(Self.axTitle) ?? "?"
                    print("⚠️ Wrong window focused after activate — want \"\(wantTitle)\", got \"\(gotTitle)\". Retrying focus.")
                    Self.focusWindow(targetWin)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        self?.finishPaste(text: text, shouldSendReturn: shouldSendReturn, returnTo: currentFrontmost, returnWindow: currentWindow)
                    }
                    return
                }

                self?.finishPaste(text: text, shouldSendReturn: shouldSendReturn, returnTo: currentFrontmost, returnWindow: currentWindow)
            }
        } else {
            // Target is already frontmost or no target captured — paste directly
            pasteTextAtCursor(text)
            if shouldSendReturn { sendReturnKey() }
        }
    }

    /// Common tail for the switching paste path — handles the actual paste,
    /// optional Return, and switch-back. Broken out so the no-retry and the
    /// retry-after-wrong-window paths share it.
    private func finishPaste(text: String, shouldSendReturn: Bool, returnTo: NSRunningApplication?, returnWindow: AXUIElement?) {
        pasteTextAtCursor(text)
        if shouldSendReturn {
            sendReturnKey()
        }
        // Switch back after paste + Return have been processed
        // pasteTextAtCursor restores clipboard at 0.7s, sendReturnKey fires at 0.5s
        let switchBackDelay = shouldSendReturn ? 0.8 : 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + switchBackDelay) {
            if let returnTo = returnTo, !returnTo.isTerminated {
                print("🔀 Switching back to: \(returnTo.localizedName ?? "Unknown")")
                if let curWin = returnWindow {
                    Self.focusWindow(curWin)
                }
                returnTo.activate()
            }
        }
    }

    /// Apply the full focus trio to a window: mark it main, mark it focused,
    /// and raise it in z-order. Each signal nudges a different piece of the
    /// key-window state. Some apps only respond to one, some to all — doing
    /// all three is safe and much more reliable than RaiseAction alone.
    private static func focusWindow(_ win: AXUIElement) {
        AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
    }

    /// Currently focused window of the given app, or nil.
    private static func focusedWindow(forAppPid pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &raw) == .success,
              let v = raw, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func axTitle(_ el: AXUIElement) -> String? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    /// file:// path exposed by a window's AXDocument attribute, or nil. For
    /// Ghostty / Terminal this is the shell's current working directory.
    private static func axDocumentPath(_ el: AXUIElement) -> String? {
        var raw: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXDocumentAttribute as CFString, &raw) == .success,
              let s = raw as? String,
              let url = URL(string: s) else { return nil }
        return url.path
    }

    /// Compact, user-facing description of a window for the recording overlay
    /// footer. Prefers the window title; appends a "~/…/project" suffix when
    /// a cwd is available. Returns nil if we can't describe the window — the
    /// footer is hidden entirely in that case.
    static func targetWindowDetail(for window: AXUIElement?) -> String? {
        guard let w = window else { return nil }
        let rawTitle = axTitle(w)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (rawTitle?.isEmpty ?? true) ? nil : rawTitle

        let cwdShort: String? = {
            guard let path = axDocumentPath(w), !path.isEmpty else { return nil }
            let home = NSHomeDirectory()
            if path == home { return "~" }
            if path.hasPrefix(home + "/") {
                return "~" + path.dropFirst(home.count)
            }
            return path
        }()

        switch (title, cwdShort) {
        case let (t?, c?): return "\(t) · \(c)"
        case let (t?, nil): return t
        case let (nil, c?): return c
        default: return nil
        }
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
            // Keep .maskCommand on key-up so Ghostty/other strict apps don't
            // leak a phantom Cmd into the next synthesized key (e.g. Return).
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cghidEventTap)
        }
        
        print("✅ Paste command sent")
        
        // After a delay, check if paste might have failed
        // and show history window for easy manual copying
        // (1s to ensure the target app has processed the Cmd+V before we restore the clipboard)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
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
                // Leave the transcription on the clipboard so the
                // notification's "Text is on the clipboard" stays true —
                // restoring here would wipe it right after the user reads it.
                return
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
        // Previously auto-opened the history window, which was disruptive
        // during voice workflows. Now we just drop a notification — the text
        // is already on the clipboard for the user to paste manually.
        AppNotifier.notify(title: "Paste target unavailable", body: "Text is on the clipboard.")
        print("📋 Paste target unreachable — text left on clipboard, user notified")
    }

    func notifyPasteSkipped(target: String) {
        AppNotifier.notify(
            title: "Couldn't paste into \(target)",
            body: "The window didn't come forward. Text is on the clipboard."
        )
    }

    private func sendReturnKey() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let source = CGEventSource(stateID: .hidSystemState)
            var carriageReturn: UniChar = 0x0D
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true) {
                keyDown.flags = []
                keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &carriageReturn)
                keyDown.post(tap: .cghidEventTap)
            }
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false) {
                keyUp.flags = []
                keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &carriageReturn)
                keyUp.post(tap: .cghidEventTap)
            }
            print("STT PTT: sent Return key")
        }
    }
}
