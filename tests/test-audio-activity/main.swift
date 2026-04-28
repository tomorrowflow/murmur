// swift run TestAudioActivity
//
// Standalone lab for detecting "is anything actually playing right now"
// on macOS 26 (Tahoe), where MediaRemote read APIs are gated for
// third-party apps. We need a reliable system-wide detector so Murmur
// can decide whether to send the Pause command.
//
// Workflow: vary what's playing (Spotify, Apple Music, Safari/YouTube,
// nothing) and after each change press the relevant key to see what each
// signal reports. The signal that correctly distinguishes "playing now"
// from "stream open but paused" is the one we want.
//
// Commands (single key, no Enter):
//
//   1   CoreAudio HAL: kAudioDevicePropertyDeviceIsRunningSomewhere
//       on the default output device. (Known false positives — apps that
//       hold the stream open while paused report true.)
//
//   2   Enumerate per-process audio objects via
//       kAudioHardwarePropertyProcessObjectList (macOS 14.2+) and read
//       kAudioProcessPropertyIsRunningOutput for each. Show pid, bundle
//       ID, and whether each is running output right now. Looking for a
//       signal that flips when an app pauses.
//
//   3   Same as 2 but only show processes whose IsRunningOutput is true,
//       so you see at a glance who's actually producing audio.
//
//   4   AppleScript: ask Spotify/Music/Podcasts/TV for `player state`.
//       Per-app, reliable for those apps that publish a scripting
//       interface. Returns "playing", "paused", "stopped", or "(not
//       running)".
//
//   q   quit

import Foundation
import AppKit
import CoreAudio

// MARK: - Approach 1: HAL device-is-running-somewhere

func checkOutputDeviceRunning() {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var defaultAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let s1 = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &defaultAddr, 0, nil, &size, &deviceID
    )
    guard s1 == noErr, deviceID != 0 else {
        print("  could not resolve default output device (status \(s1))")
        return
    }

    // Resolve device name for context.
    let name = stringProperty(of: deviceID, selector: kAudioObjectPropertyName) ?? "?"

    var isRunning: UInt32 = 0
    var isRunningSize = UInt32(MemoryLayout<UInt32>.size)
    var runningAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let s2 = AudioObjectGetPropertyData(
        deviceID, &runningAddr, 0, nil, &isRunningSize, &isRunning
    )
    guard s2 == noErr else {
        print("  IsRunningSomewhere query failed (status \(s2))")
        return
    }
    print("  device: \(name) (id=\(deviceID))")
    print("  kAudioDevicePropertyDeviceIsRunningSomewhere = \(isRunning != 0)")
}

// MARK: - Approach 2/3: per-process audio objects

/// Process-level CoreAudio properties (CoreAudio.AudioHardware,
/// macOS 14.2+). FourCC codes from <CoreAudio/AudioHardware.h>; pulled
/// in raw because Swift's CoreAudio module-map exposure of these
/// constants varies between SDK versions.
private func fourCC(_ s: StaticString) -> AudioObjectPropertySelector {
    precondition(s.utf8CodeUnitCount == 4, "FourCC must be 4 bytes")
    return s.withUTF8Buffer { buf -> AudioObjectPropertySelector in
        (UInt32(buf[0]) << 24) | (UInt32(buf[1]) << 16) | (UInt32(buf[2]) << 8) | UInt32(buf[3])
    }
}

let kAudioHardwarePropertyProcessObjectList_RAW: AudioObjectPropertySelector = fourCC("prs#")
let kAudioProcessPropertyIsRunningOutput_RAW: AudioObjectPropertySelector   = fourCC("piro")
let kAudioProcessPropertyIsRunningInput_RAW: AudioObjectPropertySelector    = fourCC("piri")
let kAudioProcessPropertyIsRunning_RAW: AudioObjectPropertySelector         = fourCC("pir?")
let kAudioProcessPropertyPID_RAW: AudioObjectPropertySelector               = fourCC("ppid")
let kAudioProcessPropertyBundleID_RAW: AudioObjectPropertySelector          = fourCC("pbid")

func enumerateAudioProcesses(onlyRunningOutput: Bool) {
    var listAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList_RAW,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    let s1 = AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &listAddr, 0, nil, &dataSize
    )
    guard s1 == noErr else {
        print("  ProcessObjectList size query failed (\(s1)) — needs macOS 14.2+")
        return
    }
    let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
    var processIDs = [AudioObjectID](repeating: 0, count: count)
    let s2 = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &listAddr, 0, nil, &dataSize, &processIDs
    )
    guard s2 == noErr else {
        print("  ProcessObjectList read failed (\(s2))")
        return
    }
    print("  \(processIDs.count) audio process object(s):")
    var anyRunningOutput = false
    for objID in processIDs {
        let pid = pidProperty(of: objID) ?? 0
        let bundle = stringProperty(of: objID, selector: kAudioProcessPropertyBundleID_RAW) ?? "?"
        let isRunning = boolProperty(of: objID, selector: kAudioProcessPropertyIsRunning_RAW)
        let isRunningOutput = boolProperty(of: objID, selector: kAudioProcessPropertyIsRunningOutput_RAW)
        let isRunningInput = boolProperty(of: objID, selector: kAudioProcessPropertyIsRunningInput_RAW)
        if onlyRunningOutput && isRunningOutput != true { continue }
        if isRunningOutput == true { anyRunningOutput = true }
        let runStr = isRunning.map { String($0) } ?? "?"
        let outStr = isRunningOutput.map { String($0) } ?? "?"
        let inStr = isRunningInput.map { String($0) } ?? "?"
        print("    pid=\(pid)\tout=\(outStr)\tin=\(inStr)\trun=\(runStr)\tbundle=\(bundle)")
    }
    if onlyRunningOutput && !anyRunningOutput {
        print("    (no process is currently running output)")
    }
}

func boolProperty(of objID: AudioObjectID, selector: AudioObjectPropertySelector) -> Bool? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let s = AudioObjectGetPropertyData(objID, &addr, 0, nil, &size, &value)
    guard s == noErr else { return nil }
    return value != 0
}

func pidProperty(of objID: AudioObjectID) -> pid_t? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyPID_RAW,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: pid_t = 0
    var size = UInt32(MemoryLayout<pid_t>.size)
    let s = AudioObjectGetPropertyData(objID, &addr, 0, nil, &size, &value)
    guard s == noErr else { return nil }
    return value
}

func stringProperty(of objID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var cfStr: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let s = withUnsafeMutablePointer(to: &cfStr) { ptr -> OSStatus in
        ptr.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { rawPtr in
            AudioObjectGetPropertyData(objID, &addr, 0, nil, &size, rawPtr)
        }
    }
    guard s == noErr, let cfStr = cfStr else { return nil }
    return cfStr.takeRetainedValue() as String
}

// MARK: - Approach 4: AppleScript per-app player state

func askPlayerStates() {
    // Only Spotify and Music expose `player state` cleanly. Podcasts and TV
    // have different scripting dictionaries (Podcasts errored with -2740,
    // TV returned inconsistent values), so we skip them. AppleScript is
    // inherently per-app — there's no "ask any media app" call.
    let apps = [
        ("Spotify", "tell application \"Spotify\" to return player state as text"),
        ("Music", "tell application \"Music\" to return player state as text"),
    ]
    for (name, source) in apps {
        let result = runAppleScript(source)
        print("  \(name.padding(toLength: 10, withPad: " ", startingAt: 0)) \(result)")
    }
}

func runAppleScript(_ source: String) -> String {
    guard let script = NSAppleScript(source: source) else { return "(compile failed)" }
    var error: NSDictionary?
    let descriptor = script.executeAndReturnError(&error)
    if let error = error {
        let num = error[NSAppleScript.errorNumber] as? Int ?? 0
        if num == -600 || num == -1728 {
            return "(not running)"
        }
        let msg = error[NSAppleScript.errorMessage] as? String ?? "?"
        return "ERROR \(num): \(msg)"
    }
    return descriptor.stringValue ?? "(no value)"
}

// MARK: - Main loop

func printMenu() {
    print("")
    print("Commands:")
    print("  1   HAL kAudioDevicePropertyDeviceIsRunningSomewhere (default output)")
    print("  2   Enumerate audio processes + IsRunningOutput / IsRunningInput")
    print("  3   Same as 2 but filter to only processes with IsRunningOutput=true")
    print("  4   AppleScript: player state of Spotify / Music / Podcasts / TV")
    print("  q   quit")
    print("")
    print("Suggested workflow: try with (a) nothing playing, (b) Spotify playing,")
    print("(c) Spotify paused with stream still open, (d) Safari/YouTube playing,")
    print("(e) Safari/YouTube paused. The signal we want is one that flips between")
    print("(b) and (c).")
}

@main
struct TestAudioActivity {
    static func main() {
        print("== TestAudioActivity ==")
        print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        printMenu()

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
            case "1":
                print("[1] HAL DeviceIsRunningSomewhere")
                checkOutputDeviceRunning()
            case "2":
                print("[2] All audio processes")
                enumerateAudioProcesses(onlyRunningOutput: false)
            case "3":
                print("[3] Audio processes with IsRunningOutput=true")
                enumerateAudioProcesses(onlyRunningOutput: true)
            case "4":
                print("[4] Per-app player state via AppleScript")
                askPlayerStates()
            case "?", "h": printMenu()
            case "q": print("bye"); return
            case "\n", "\r": continue
            default: print("(unknown — try ? for help)")
            }
            print("")
        }
    }
}
