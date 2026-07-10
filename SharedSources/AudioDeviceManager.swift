import Foundation
import AVFoundation
import CoreAudio

public struct AudioDevice: Equatable {
    public let uid: String
    public let name: String
    public let isInput: Bool
    public let isOutput: Bool
    
    public static let systemDefault = AudioDevice(
        uid: "system_default",
        name: "System Default",
        isInput: false,
        isOutput: false
    )
}

public class AudioDeviceManager: ObservableObject {
    public static let shared = AudioDeviceManager()
    
    @Published public var availableInputDevices: [AudioDevice] = []
    @Published public var availableOutputDevices: [AudioDevice] = []
    @Published public var useSystemDefaultInput: Bool = true
    @Published public var useSystemDefaultOutput: Bool = true
    @Published public var selectedInputDeviceUID: String?
    @Published public var selectedOutputDeviceUID: String?
    
    private let userDefaults = UserDefaults.standard
    private let inputDeviceKey = "AudioDeviceManager.selectedInputDevice"
    private let outputDeviceKey = "AudioDeviceManager.selectedOutputDevice"
    private let useSystemInputKey = "AudioDeviceManager.useSystemDefaultInput"
    private let useSystemOutputKey = "AudioDeviceManager.useSystemDefaultOutput"
    
    init() {
        loadPreferences()
        refreshDeviceList()
        setupNotifications()
    }

    deinit {
        if let block = listenerBlock {
            var devicesAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddr,
                nil,
                block
            )
        }
    }
    
    private func loadPreferences() {
        useSystemDefaultInput = userDefaults.object(forKey: useSystemInputKey) as? Bool ?? true
        useSystemDefaultOutput = userDefaults.object(forKey: useSystemOutputKey) as? Bool ?? true
        selectedInputDeviceUID = userDefaults.string(forKey: inputDeviceKey)
        selectedOutputDeviceUID = userDefaults.string(forKey: outputDeviceKey)
    }
    
    public func savePreferences() {
        userDefaults.set(useSystemDefaultInput, forKey: useSystemInputKey)
        userDefaults.set(useSystemDefaultOutput, forKey: useSystemOutputKey)
        userDefaults.set(selectedInputDeviceUID, forKey: inputDeviceKey)
        userDefaults.set(selectedOutputDeviceUID, forKey: outputDeviceKey)
    }
    
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    private func setupNotifications() {
        // Use CoreAudio property listener — much more reliable than AVAudioEngine
        // notifications for detecting Bluetooth / AirPods connections
        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.refreshDeviceList()
            }
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddr,
            nil,
            block
        )
    }
    
    public func refreshDeviceList() {
        let allDevices = getAllAudioDevices()
        availableInputDevices = [AudioDevice.systemDefault] + allDevices.filter { $0.isInput }
        availableOutputDevices = [AudioDevice.systemDefault] + allDevices.filter { $0.isOutput }

        // Fall back to system default if selected device was removed
        if !useSystemDefaultInput,
           let uid = selectedInputDeviceUID,
           !allDevices.contains(where: { $0.uid == uid && $0.isInput }) {
            useSystemDefaultInput = true
            savePreferences()
        }
        if !useSystemDefaultOutput,
           let uid = selectedOutputDeviceUID,
           !allDevices.contains(where: { $0.uid == uid && $0.isOutput }) {
            useSystemDefaultOutput = true
            savePreferences()
        }
    }
    
    private func getAllAudioDevices() -> [AudioDevice] {
        var devices: [AudioDevice] = []
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        
        guard status == noErr else { return devices }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var audioDevices = [AudioDeviceID](repeating: 0, count: deviceCount)
        
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &audioDevices
        )
        
        guard status == noErr else { return devices }
        
        for deviceID in audioDevices {
            if let device = getDeviceInfo(deviceID: deviceID) {
                devices.append(device)
            }
        }
        
        return devices
    }
    
    private func getDeviceInfo(deviceID: AudioDeviceID) -> AudioDevice? {
        let uid = getDeviceUID(deviceID: deviceID) ?? ""
        let name = getDeviceName(deviceID: deviceID) ?? "Unknown Device"
        let isInput = hasInputChannels(deviceID: deviceID)
        let isOutput = hasOutputChannels(deviceID: deviceID)

        guard !uid.isEmpty && (isInput || isOutput) else { return nil }

        // Filter out virtual aggregate devices (e.g. CADefaultDeviceAggregate)
        // that macOS creates internally — they don't appear in System Settings
        let transport = getTransportType(deviceID: deviceID)
        if transport == kAudioDeviceTransportTypeAggregate {
            return nil
        }

        return AudioDevice(uid: uid, name: name, isInput: isInput, isOutput: isOutput)
    }

    private func getTransportType(deviceID: AudioDeviceID) -> UInt32 {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID, &propertyAddress, 0, nil, &dataSize, &transportType
        )
        guard status == noErr else { return 0 }
        return transportType
    }
    
    private func getDeviceUID(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = UInt32(MemoryLayout<CFString>.size)
        var uid: CFString?
        
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &uid
        )
        
        guard status == noErr, let uid = uid else { return nil }
        return uid as String
    }
    
    private func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = UInt32(MemoryLayout<CFString>.size)
        var name: CFString?
        
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &name
        )
        
        guard status == noErr, let name = name else { return nil }
        return name as String
    }
    
    private func hasInputChannels(deviceID: AudioDeviceID) -> Bool {
        hasChannels(deviceID: deviceID, scope: kAudioDevicePropertyScopeInput)
    }

    private func hasOutputChannels(deviceID: AudioDeviceID) -> Bool {
        hasChannels(deviceID: deviceID, scope: kAudioDevicePropertyScopeOutput)
    }

    private func hasChannels(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr, dataSize > 0 else { return false }

        // Allocate the full property size: a stream configuration holds one
        // AudioBuffer per stream, and CoreAudio writes dataSize bytes — a
        // fixed single-AudioBufferList allocation overflows on multi-stream
        // devices (USB interfaces, aggregates).
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)

        let getStatus = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            bufferList
        )

        guard getStatus == noErr else { return false }

        return UnsafeMutableAudioBufferListPointer(bufferList).contains { $0.mNumberChannels > 0 }
    }
    
    public func getCurrentInputDevice() -> AudioDevice? {
        if useSystemDefaultInput {
            return nil
        }
        
        guard let uid = selectedInputDeviceUID else { return nil }
        return availableInputDevices.first { $0.uid == uid }
    }
    
    public func getCurrentOutputDevice() -> AudioDevice? {
        if useSystemDefaultOutput {
            return nil
        }
        
        guard let uid = selectedOutputDeviceUID else { return nil }
        return availableOutputDevices.first { $0.uid == uid }
    }
    
    public func getSystemDefaultInputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    public func getSystemDefaultOutputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    // MARK: - Default input device override

    /// The system default input that was in effect before
    /// `applyInputDeviceOverrideIfNeeded()` replaced it, kept so the override
    /// can be undone when recording ends instead of permanently hijacking the
    /// user's default microphone for every other app.
    private var savedDefaultInputDeviceID: AudioDeviceID?

    /// If the user picked a dedicated input device, set it as the system
    /// default (AVAudioEngine on macOS records from the default input),
    /// remembering the previous default. Returns the name of the device the
    /// override applied, or nil when no override was needed.
    @discardableResult
    public func applyInputDeviceOverrideIfNeeded() -> String? {
        guard !useSystemDefaultInput,
              let selectedUID = selectedInputDeviceUID,
              let deviceID = getAudioDeviceID(for: selectedUID) else { return nil }

        let current = getSystemDefaultInputDeviceID()
        guard current != deviceID else { return nil }  // already the default

        guard setSystemDefaultInputDevice(deviceID) else { return nil }
        // Keep the oldest saved default across repeated applies so nested
        // calls (e.g. config-change restarts) still restore the original.
        if savedDefaultInputDeviceID == nil {
            savedDefaultInputDeviceID = current
        }
        return availableInputDevices.first { $0.uid == selectedUID }?.name ?? selectedUID
    }

    /// Restore the system default input device replaced by
    /// `applyInputDeviceOverrideIfNeeded()`. Safe to call when no override is
    /// active.
    public func restoreDefaultInputDeviceIfOverridden() {
        guard let saved = savedDefaultInputDeviceID else { return }
        savedDefaultInputDeviceID = nil
        if setSystemDefaultInputDevice(saved) {
            print("Restored previous system default input device")
        }
    }

    private func setSystemDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceIDValue = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceIDValue
        )
        return status == noErr
    }

    /// Returns true if the given device uses Bluetooth transport.
    private func isBluetoothTransport(deviceID: AudioDeviceID) -> Bool {
        let transport = getTransportType(deviceID: deviceID)
        return transport == kAudioDeviceTransportTypeBluetooth ||
               transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Returns true if the current input device uses Bluetooth transport
    /// (e.g. AirPods, Bluetooth headsets). These devices need extra warmup
    /// time before the microphone is ready to capture audio.
    public func isCurrentInputDeviceBluetooth() -> Bool {
        let deviceID: AudioDeviceID?
        if !useSystemDefaultInput,
           let selectedUID = selectedInputDeviceUID {
            deviceID = getAudioDeviceID(for: selectedUID)
        } else {
            deviceID = getSystemDefaultInputDeviceID()
        }
        guard let id = deviceID else { return false }
        return isBluetoothTransport(deviceID: id)
    }

    /// Returns true if the current output device uses Bluetooth transport.
    public func isCurrentOutputDeviceBluetooth() -> Bool {
        let deviceID: AudioDeviceID?
        if !useSystemDefaultOutput,
           let selectedUID = selectedOutputDeviceUID {
            deviceID = getAudioDeviceID(for: selectedUID)
        } else {
            deviceID = getSystemDefaultOutputDeviceID()
        }
        guard let id = deviceID else { return false }
        return isBluetoothTransport(deviceID: id)
    }

    public func getAudioDeviceID(for uid: String) -> AudioDeviceID? {
        // First, iterate through all devices to find matching UID
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )
        
        guard status == noErr else { return nil }
        
        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var audioDevices = [AudioDeviceID](repeating: 0, count: deviceCount)
        
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &audioDevices
        )
        
        guard status == noErr else { return nil }
        
        // Check each device's UID
        for deviceID in audioDevices {
            if let deviceUID = getDeviceUID(deviceID: deviceID), deviceUID == uid {
                return deviceID
            }
        }
        
        return nil
    }
}