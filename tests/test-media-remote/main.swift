// swift run TestMediaRemote
//
// Standalone lab for exploring how to send pause/play to whatever app
// owns macOS Now Playing. No dependency on Murmur — loads
// MediaRemote.framework directly and tries every known approach so we
// can see which one actually moves the needle on macOS 15+.
//
// Workflow: start playing media in Safari/Spotify/Music/etc., then run
// this and try each command. After each attempt, hit `s` to see whether
// the playback state actually changed.
//
// Commands (single key, no Enter):
//   s   show Now Playing state (info dict + IsPlaying boolean)
//
//   1   F8 via NSEvent.systemDefined → CGEvent.post(.cghidEventTap)
//   2   F8 via NSEvent.systemDefined → CGEvent.post(.cgSessionEventTap)
//   3   F8 via NSEvent.systemDefined → CGEvent.post(.cgAnnotatedSessionEventTap)
//   4   F8 via NSEvent.systemDefined → 1 + 2 + 3 (all three taps)
//   5   kVK_F8 keyboard event via CGEvent (regular keystroke, not media)
//
//   6   MRMediaRemoteSendCommand(0)  — Play
//   7   MRMediaRemoteSendCommand(1)  — Pause
//   8   MRMediaRemoteSendCommand(2)  — TogglePlayPause
//
//   q   quit

import Foundation
import AppKit
import CoreGraphics

// MARK: - MediaRemote symbols

fileprivate typealias SendCommandFn = @convention(c) (Int, AnyObject?) -> Bool
fileprivate typealias IsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
fileprivate typealias GetNowPlayingInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]?) -> Void) -> Void

private let nowPlayingInfoPlaybackRateKey = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
private let nowPlayingInfoTitleKey = "kMRMediaRemoteNowPlayingInfoTitle"
private let nowPlayingInfoArtistKey = "kMRMediaRemoteNowPlayingInfoArtist"

// HID media-key constants from <IOKit/hidsystem/ev_keymap.h>.
private let nxSubtypeAuxControlButtons: Int16 = 8
private let nxKeyTypePlay: Int = 16
private let nxKeyDown: Int = 0xA
private let nxKeyUp: Int = 0xB
private let mediaKeyModifierFlags = NSEvent.ModifierFlags(rawValue: 0xA00)

// kVK_F8 = 100 (regular keyboard scancode)
private let kVK_F8: CGKeyCode = 100

// MARK: - Framework loader

struct MediaRemote {
    fileprivate let sendCommand: SendCommandFn?
    fileprivate let isPlaying: IsPlayingFn?
    fileprivate let getInfo: GetNowPlayingInfoFn?

    static func load() -> MediaRemote {
        let url = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        guard let bundle = CFBundleCreate(kCFAllocatorDefault, url as CFURL),
              CFBundleLoadExecutable(bundle) else {
            print("ERROR: failed to load MediaRemote.framework")
            return MediaRemote(sendCommand: nil, isPlaying: nil, getInfo: nil)
        }
        let send = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString)
            .map { unsafeBitCast($0, to: SendCommandFn.self) }
        let playing = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString)
            .map { unsafeBitCast($0, to: IsPlayingFn.self) }
        let info = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString)
            .map { unsafeBitCast($0, to: GetNowPlayingInfoFn.self) }
        print("MediaRemote.framework loaded:")
        print("  MRMediaRemoteSendCommand:                       \(send != nil ? "✓" : "✗")")
        print("  MRMediaRemoteGetNowPlayingApplicationIsPlaying: \(playing != nil ? "✓" : "✗")")
        print("  MRMediaRemoteGetNowPlayingInfo:                 \(info != nil ? "✓" : "✗")")
        return MediaRemote(sendCommand: send, isPlaying: playing, getInfo: info)
    }
}

// MARK: - State queries

func showState(_ mr: MediaRemote) async {
    print("---- Now Playing state ----")

    // IsPlaying boolean
    if let isPlaying = mr.isPlaying {
        let playing = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            isPlaying(.main) { cont.resume(returning: $0) }
        }
        print("IsPlaying boolean: \(playing)")
    } else {
        print("IsPlaying boolean: <symbol unavailable>")
    }

    // Info dict
    if let getInfo = mr.getInfo {
        let info: [String: Any]? = await withCheckedContinuation { cont in
            getInfo(.main) { cont.resume(returning: $0) }
        }
        if let info = info {
            if info.isEmpty {
                print("Info dict: <empty>")
            } else {
                let title = info[nowPlayingInfoTitleKey] as? String ?? "<no title>"
                let artist = info[nowPlayingInfoArtistKey] as? String ?? ""
                let rate = (info[nowPlayingInfoPlaybackRateKey] as? NSNumber)?.doubleValue
                print("Title:  \(title)\(artist.isEmpty ? "" : " — \(artist)")")
                print("Rate:   \(rate.map { String($0) } ?? "<missing>")")
                print("Keys (\(info.count)):")
                for k in info.keys.sorted() { print("  \(k)") }
            }
        } else {
            print("Info dict: <nil>")
        }
    } else {
        print("Info dict: <symbol unavailable>")
    }
    print("---------------------------")
}

// MARK: - Approach 1-4: NSEvent.systemDefined media key

enum Tap {
    case hid, session, annotatedSession
    var cgTap: CGEventTapLocation {
        switch self {
        case .hid: return .cghidEventTap
        case .session: return .cgSessionEventTap
        case .annotatedSession: return .cgAnnotatedSessionEventTap
        }
    }
    var label: String {
        switch self {
        case .hid: return ".cghidEventTap"
        case .session: return ".cgSessionEventTap"
        case .annotatedSession: return ".cgAnnotatedSessionEventTap"
        }
    }
}

func sendF8MediaKey(via taps: [Tap]) {
    let tapList = taps.map(\.label).joined(separator: ", ")
    print("→ NSEvent.systemDefined NX_KEYTYPE_PLAY (down + up) on [\(tapList)]")
    postSystemDefined(keyState: nxKeyDown, taps: taps)
    postSystemDefined(keyState: nxKeyUp, taps: taps)
}

func postSystemDefined(keyState: Int, taps: [Tap]) {
    let data1 = (nxKeyTypePlay << 16) | (keyState << 8)
    guard let event = NSEvent.otherEvent(
        with: .systemDefined,
        location: NSPoint.zero,
        modifierFlags: mediaKeyModifierFlags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        subtype: nxSubtypeAuxControlButtons,
        data1: data1,
        data2: -1
    ) else {
        print("  failed to construct NSEvent")
        return
    }
    guard let cg = event.cgEvent else {
        print("  NSEvent has no underlying CGEvent")
        return
    }
    for tap in taps {
        cg.post(tap: tap.cgTap)
    }
}

// MARK: - Approach 5: regular keyboard F8 keystroke

func sendF8KeyboardEvent() {
    print("→ kVK_F8 (100) keyboard event via CGEvent on .cghidEventTap")
    let src = CGEventSource(stateID: .hidSystemState)
    guard let down = CGEvent(keyboardEventSource: src, virtualKey: kVK_F8, keyDown: true),
          let up = CGEvent(keyboardEventSource: src, virtualKey: kVK_F8, keyDown: false) else {
        print("  failed to construct CGEvent")
        return
    }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

// MARK: - Approach 6-8: MRMediaRemoteSendCommand

func sendMRCommand(_ mr: MediaRemote, command: Int, label: String) {
    guard let send = mr.sendCommand else {
        print("→ MRMediaRemoteSendCommand: <symbol unavailable>")
        return
    }
    let ok = send(command, nil)
    print("→ MRMediaRemoteSendCommand(\(command) /* \(label) */) returned \(ok)")
    if ok {
        print("  (note: returns true even when macOS 15+ silently drops it for third-party apps)")
    }
}

// MARK: - Approach 9-11: AppleScript routes

func runAppleScript(_ source: String, label: String) {
    print("→ AppleScript: \(label)")
    print("  source: \(source)")
    guard let script = NSAppleScript(source: source) else {
        print("  failed to compile")
        return
    }
    var error: NSDictionary?
    script.executeAndReturnError(&error)
    if let error = error {
        let msg = error[NSAppleScript.errorMessage] as? String ?? "<unknown>"
        let num = error[NSAppleScript.errorNumber] as? Int ?? 0
        print("  ERROR (\(num)): \(msg)")
        if num == -1743 {
            print("  → Murmur lacks Automation permission for the target app.")
            print("    Grant via System Settings → Privacy & Security → Automation.")
        }
    } else {
        print("  no AppleScript error returned")
    }
}

// MARK: - Main loop

func printMenu() {
    print("")
    print("NOTE: on macOS 26 (Tahoe) the Now Playing read APIs are gated for")
    print("third-party apps — `s` will report IsPlaying=false / Info=nil even")
    print("while media is actively playing. Verify whether each send approach")
    print("works by listening to / watching the media app itself, not by `s`.")
    print("")
    print("Commands:")
    print("  s   show Now Playing state (broken on macOS 26)")
    print("  1   F8 systemDefined → cghidEventTap")
    print("  2   F8 systemDefined → cgSessionEventTap")
    print("  3   F8 systemDefined → cgAnnotatedSessionEventTap")
    print("  4   F8 systemDefined → all three taps")
    print("  5   kVK_F8 keyboard event")
    print("  6   MRMediaRemoteSendCommand(0)  Play  (gated on macOS 15.4+)")
    print("  7   MRMediaRemoteSendCommand(1)  Pause (gated on macOS 15.4+)")
    print("  8   MRMediaRemoteSendCommand(2)  Toggle (gated on macOS 15.4+)")
    print("  9   AppleScript: System Events → key code 100 (F8)")
    print("  o   AppleScript: tell application \"Spotify\" to playpause")
    print("  m   AppleScript: tell application \"Music\" to playpause")
    print("  q   quit")
    print("")
}

@main
struct TestMediaRemote {
    static func main() async {
        print("== TestMediaRemote ==")
        print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("")
        let mr = MediaRemote.load()
        printMenu()
        await showState(mr)

        // Raw single-key input.
        var raw = termios()
        tcgetattr(STDIN_FILENO, &raw)
        let original = raw
        raw.c_lflag &= ~UInt(ICANON | ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        defer {
            var restore = original
            tcsetattr(STDIN_FILENO, TCSANOW, &restore)
        }

        while true {
            print("> ", terminator: "")
            var byte: UInt8 = 0
            let n = read(STDIN_FILENO, &byte, 1)
            guard n == 1 else { break }
            let ch = Character(UnicodeScalar(byte))
            if byte != 0x0A && byte != 0x0D { print(ch) }

            switch ch {
            case "s": await showState(mr)
            case "1": sendF8MediaKey(via: [.hid])
            case "2": sendF8MediaKey(via: [.session])
            case "3": sendF8MediaKey(via: [.annotatedSession])
            case "4": sendF8MediaKey(via: [.hid, .session, .annotatedSession])
            case "5": sendF8KeyboardEvent()
            case "6": sendMRCommand(mr, command: 0, label: "Play")
            case "7": sendMRCommand(mr, command: 1, label: "Pause")
            case "8": sendMRCommand(mr, command: 2, label: "TogglePlayPause")
            case "9": runAppleScript("tell application \"System Events\" to key code 100",
                                     label: "System Events → key code 100 (F8)")
            case "o": runAppleScript("tell application \"Spotify\" to playpause",
                                     label: "Spotify playpause")
            case "m": runAppleScript("tell application \"Music\" to playpause",
                                     label: "Music playpause")
            case "?", "h": printMenu()
            case "q": print("bye"); return
            case "\n", "\r": continue
            default: print("(unknown — try ? for help)")
            }
            print("")
        }
    }
}
