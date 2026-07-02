// TestProcessTap — standalone smoke test for the Core Audio process-tap
// capture path used by CallCaptureManager (Phase B1).
//
//   swift run TestProcessTap [bundleIdOrAlias] [seconds]
//
// Defaults: first running known app (slack/teams/zoom), 10 seconds.
// Captures the target app's audio OUTPUT to a WAV in the scratch dir, then
// asserts the file is non-empty and not all-silence (prints the peak level).
//
// Requires the target app to be actively playing audio during the capture
// window. macOS will prompt for "System Audio Recording" permission on first
// run — if run headless this may block; grant it in System Settings and retry.

import Foundation
import AVFoundation
import CoreAudio
import AppKit

// MARK: - Known apps

let knownApps: [(alias: String, bundleID: String, name: String)] = [
    ("slack", "com.tinyspeck.slackmacgap", "Slack"),
    ("teams", "com.microsoft.teams2", "Microsoft Teams"),
    ("zoom", "us.zoom.xos", "Zoom")
]

func bundleID(fromArg arg: String) -> String? {
    if let known = knownApps.first(where: { $0.alias == arg.lowercased() }) { return known.bundleID }
    if arg.contains(".") { return arg }
    return nil
}

// MARK: - Core Audio helpers

func processObject(forPID pid: pid_t) -> AudioObjectID? {
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

func readTapFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var asbd = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd) == noErr else { return nil }
    return asbd
}

// MARK: - Argument parsing

let args = CommandLine.arguments
var targetArg: String? = nil
var seconds: Double = 10

if args.count > 1 { targetArg = args[1] }
if args.count > 2, let s = Double(args[2]) { seconds = s }

// Resolve the target bundle id.
var resolvedBundleID: String?
if let targetArg {
    resolvedBundleID = bundleID(fromArg: targetArg)
    if resolvedBundleID == nil {
        print("❌ Unknown app \"\(targetArg)\". Use slack/teams/zoom or a bundle id.")
        exit(2)
    }
} else {
    // Find the first running known app.
    for app in knownApps {
        if NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first != nil {
            resolvedBundleID = app.bundleID
            break
        }
    }
    if resolvedBundleID == nil {
        print("""
        ❌ No known call app (Slack / Teams / Zoom) is running.
           Start one and play some audio (e.g. a call, a huddle, or a video),
           then re-run:  swift run TestProcessTap [slack|teams|zoom] [seconds]
        """)
        exit(2)
    }
}

let bundle = resolvedBundleID!
let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
guard !runningApps.isEmpty else {
    print("❌ \(bundle) is not running. Start it and play audio, then retry.")
    exit(2)
}

var processIDs: [AudioObjectID] = []
for app in runningApps {
    if let obj = processObject(forPID: app.processIdentifier) { processIDs.append(obj) }
}
guard !processIDs.isEmpty else {
    print("""
    ❌ \(bundle) is running but has no active Core Audio process object yet.
       It must produce audio before it can be tapped — start playback and retry.
    """)
    exit(2)
}

print("🎧 Target: \(bundle)  (\(processIDs.count) audio process object(s))")
print("⏱  Capturing for \(seconds)s — make sure the app is playing audio...")

// MARK: - Build the tap + aggregate device

let tapDescription = CATapDescription(stereoMixdownOfProcesses: processIDs)
tapDescription.uuid = UUID()
tapDescription.name = "TestProcessTap"
tapDescription.muteBehavior = .unmuted
tapDescription.isPrivate = true

var tapID = AudioObjectID(kAudioObjectUnknown)
let tapErr = AudioHardwareCreateProcessTap(tapDescription, &tapID)
guard tapErr == noErr, tapID != kAudioObjectUnknown else {
    print("""
    ❌ AudioHardwareCreateProcessTap failed (OSStatus \(tapErr)).
       This is usually the System Audio Recording permission being denied.
       Grant Murmur/your terminal under System Settings > Privacy & Security >
       Screen & System Audio Recording, then retry.
    """)
    exit(1)
}

guard var asbd = readTapFormat(tapID), let format = AVAudioFormat(streamDescription: &asbd) else {
    print("❌ Could not read the tap format.")
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}
print("📐 Tap format: \(format.sampleRate) Hz, \(format.channelCount) ch, \(asbd.mBitsPerChannel)-bit")

let aggUID = "com.murmur.testprocesstap.\(tapDescription.uuid.uuidString)"
let aggDescription: [String: Any] = [
    kAudioAggregateDeviceNameKey: "TestProcessTap",
    kAudioAggregateDeviceUIDKey: aggUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [],
    kAudioAggregateDeviceTapListKey: [
        [kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
         kAudioSubTapDriftCompensationKey: true]
    ]
]
var aggID = AudioObjectID(kAudioObjectUnknown)
let aggErr = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &aggID)
guard aggErr == noErr, aggID != kAudioObjectUnknown else {
    print("❌ AudioHardwareCreateAggregateDevice failed (OSStatus \(aggErr)).")
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}

// MARK: - Output file + IOProc

let outURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("test-process-tap-\(Int(Date().timeIntervalSince1970)).wav")

var audioFile: AVAudioFile?
do {
    audioFile = try AVAudioFile(
        forWriting: outURL,
        settings: format.settings,
        commonFormat: format.commonFormat,
        interleaved: format.isInterleaved
    )
} catch {
    print("❌ Could not create output WAV: \(error.localizedDescription)")
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}

let ioQueue = DispatchQueue(label: "com.murmur.testprocesstap.io")
var framesWritten: Int64 = 0

var procID: AudioDeviceIOProcID?
let procErr = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, ioQueue) { _, inInputData, _, _, _ in
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil) else { return }
    do {
        try audioFile?.write(from: buffer)
        framesWritten += Int64(buffer.frameLength)
    } catch {
        // best-effort; the assertion below covers total capture
    }
}
guard procErr == noErr, let procID else {
    print("❌ AudioDeviceCreateIOProcIDWithBlock failed (OSStatus \(procErr)).")
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}

let startErr = AudioDeviceStart(aggID, procID)
guard startErr == noErr else {
    print("❌ AudioDeviceStart failed (OSStatus \(startErr)).")
    AudioDeviceDestroyIOProcID(aggID, procID)
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID)
    exit(1)
}

Thread.sleep(forTimeInterval: seconds)

// MARK: - Teardown

AudioDeviceStop(aggID, procID)
ioQueue.sync {}
AudioDeviceDestroyIOProcID(aggID, procID)
AudioHardwareDestroyAggregateDevice(aggID)
AudioHardwareDestroyProcessTap(tapID)

// Release the write handle so AVAudioFile finalizes the WAV header (frame
// count) on dealloc — otherwise reopening for reading sees 0 frames.
audioFile = nil

print("💾 Wrote \(framesWritten) frames to \(outURL.path)")

// MARK: - Assertions: non-empty + non-silent

func peakLevel(of url: URL) -> (peak: Float, frames: AVAudioFramePosition)? {
    guard let file = try? AVAudioFile(forReading: url) else { return nil }
    let processingFormat = file.processingFormat
    let frameCount = AVAudioFrameCount(file.length)
    guard frameCount > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCount) else {
        return (0, file.length)
    }
    do { try file.read(into: buffer) } catch { return (0, file.length) }
    guard let channelData = buffer.floatChannelData else { return (0, file.length) }
    var peak: Float = 0
    let channels = Int(buffer.format.channelCount)
    let frames = Int(buffer.frameLength)
    for c in 0..<channels {
        let samples = channelData[c]
        for i in 0..<frames { peak = max(peak, abs(samples[i])) }
    }
    return (peak, file.length)
}

let attrs = try? FileManager.default.attributesOfItem(atPath: outURL.path)
let fileSize = (attrs?[.size] as? Int) ?? 0

guard fileSize > 44 else {  // 44 = minimal WAV header
    print("❌ FAIL: output file is empty (\(fileSize) bytes).")
    exit(1)
}

guard let (peak, frames) = peakLevel(of: outURL) else {
    print("❌ FAIL: could not read back the WAV to check levels.")
    exit(1)
}

let peakDb = 20 * log10(max(peak, 0.00001))
print(String(format: "📊 Peak level: %.4f  (%.1f dB), %lld frames, %d bytes", peak, peakDb, frames, fileSize))

let silenceThreshold: Float = 0.0005  // ~ -66 dB
if peak < silenceThreshold {
    print("""
    ❌ FAIL: captured audio is silent (peak \(peak)).
       \(framesWritten > 0
         ? "The tap delivered \(framesWritten) frames but they are all zero — the app was not playing audible audio (check that it's actually playing and that system output is not muted / at zero volume; a muted output taps as silence)."
         : "No frames were delivered — was the app actually playing audio during the capture window?")
    """)
    exit(1)
}

print("✅ PASS: captured non-empty, non-silent audio from \(bundle).")
exit(0)
