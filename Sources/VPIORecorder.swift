import CoreAudio
import AudioToolbox

/// Manages system audio volume ducking during recording.
/// Lowers system volume when recording starts, restores it when recording stops.
/// This is a lightweight alternative to VPIO echo cancellation — it doesn't
/// filter speaker output from mic input, but reduces bleed by lowering volume.
class AudioDucker {
    static let shared = AudioDucker()

    private var savedVolume: Float32?
    private let duckLevel: Float32 = 0.08  // ~8% volume during recording

    private init() {}

    /// Lower system volume and save the original level.
    func duck() {
        guard savedVolume == nil else { return }  // Already ducked
        guard let deviceID = defaultOutputDevice() else { return }

        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else {
            print("AudioDucker: failed to get volume: \(status)")
            return
        }

        savedVolume = volume
        var newVolume = duckLevel
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &newVolume)
        print("AudioDucker: ducked from \(String(format: "%.0f%%", volume * 100)) to \(String(format: "%.0f%%", duckLevel * 100))")
    }

    /// Restore system volume to the saved level.
    func restore() {
        guard let volume = savedVolume else { return }
        guard let deviceID = defaultOutputDevice() else { return }

        let size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var restoreVolume = volume
        AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &restoreVolume)
        print("AudioDucker: restored volume to \(String(format: "%.0f%%", volume * 100))")
        savedVolume = nil
    }

    private func defaultOutputDevice() -> AudioObjectID? {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : nil
    }
}
