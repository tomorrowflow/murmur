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
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
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
        
        let bufferCount = Int(dataSize) / MemoryLayout<AudioBuffer>.size
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferList.deallocate() }
        
        bufferList.pointee.mNumberBuffers = UInt32(bufferCount)
        
        let getStatus = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            bufferList
        )
        
        guard getStatus == noErr else { return false }
        
        for i in 0..<Int(bufferList.pointee.mNumberBuffers) {
            let buffer = withUnsafePointer(to: &bufferList.pointee.mBuffers) { ptr in
                UnsafeRawPointer(ptr).assumingMemoryBound(to: AudioBuffer.self)[i]
            }
            if buffer.mNumberChannels > 0 {
                return true
            }
        }
        
        return false
    }
    
    private func hasOutputChannels(deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
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
        
        let bufferCount = Int(dataSize) / MemoryLayout<AudioBuffer>.size
        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        defer { bufferList.deallocate() }
        
        bufferList.pointee.mNumberBuffers = UInt32(bufferCount)
        
        let getStatus = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize,
            bufferList
        )
        
        guard getStatus == noErr else { return false }
        
        for i in 0..<Int(bufferList.pointee.mNumberBuffers) {
            let buffer = withUnsafePointer(to: &bufferList.pointee.mBuffers) { ptr in
                UnsafeRawPointer(ptr).assumingMemoryBound(to: AudioBuffer.self)[i]
            }
            if buffer.mNumberChannels > 0 {
                return true
            }
        }
        
        return false
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