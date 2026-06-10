import CoreAudio
import Foundation

/// Typed capture errors mapping to protocol error codes.
public enum CaptureError: Error, CustomStringConvertible {
    case tccDeniedMic(String)
    case tccDeniedSystem(String)
    case tapFailed(String)
    case deviceGone(String)
    case internalError(String)

    public var description: String {
        switch self {
        case .tccDeniedMic(let m): return m
        case .tccDeniedSystem(let m): return m
        case .tapFailed(let m): return m
        case .deviceGone(let m): return m
        case .internalError(let m): return m
        }
    }

    public var protocolCode: ErrorCode {
        switch self {
        case .tccDeniedMic: return .tccDeniedMic
        case .tccDeniedSystem: return .tccDeniedSystem
        case .tapFailed: return .tapFailed
        case .deviceGone: return .deviceGone
        case .internalError: return .internal
        }
    }
}

// MARK: - Core Audio property helpers

enum CoreAudioProps {
    static func getPropertyDataSize(_ objectID: AudioObjectID,
                                    _ address: inout AudioObjectPropertyAddress) throws -> UInt32 {
        var size: UInt32 = 0
        let err = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard err == noErr else {
            throw CaptureError.internalError("AudioObjectGetPropertyDataSize failed: \(err)")
        }
        return size
    }

    static func get<T>(_ objectID: AudioObjectID,
                       selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                       defaultValue: T) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var size = UInt32(MemoryLayout<T>.size)
        var value = defaultValue
        let err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
        }
        guard err == noErr else {
            throw CaptureError.internalError("AudioObjectGetPropertyData(\(selector)) failed: \(err)")
        }
        return value
    }

    static func getString(_ objectID: AudioObjectID,
                          selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
        }
        guard err == noErr, let str = value else {
            throw CaptureError.internalError("AudioObjectGetPropertyData(string \(selector)) failed: \(err)")
        }
        return str as String
    }

    static func getArray<T>(_ objectID: AudioObjectID,
                            selector: AudioObjectPropertySelector,
                            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [T] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = try getPropertyDataSize(objectID, &address)
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var values = [T](unsafeUninitializedCapacity: count) { _, initialized in initialized = count }
        let err = values.withUnsafeMutableBufferPointer { buf in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buf.baseAddress!)
        }
        guard err == noErr else {
            throw CaptureError.internalError("AudioObjectGetPropertyData(array \(selector)) failed: \(err)")
        }
        return values
    }
}

// MARK: - Device enumeration

public enum AudioDevices {
    /// All devices with at least one input stream, for the `devices` response.
    public static func listInputDevices() throws -> [DeviceInfo] {
        let deviceIDs: [AudioDeviceID] = try CoreAudioProps.getArray(
            AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices)

        let defaultInput: AudioDeviceID = (try? CoreAudioProps.get(
            AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultInputDevice,
            defaultValue: AudioDeviceID(0))) ?? 0

        var items: [DeviceInfo] = []
        for id in deviceIDs {
            guard hasInputStreams(id) else { continue }
            guard let uid = try? CoreAudioProps.getString(id, selector: kAudioDevicePropertyDeviceUID) else { continue }
            let name = (try? CoreAudioProps.getString(id, selector: kAudioObjectPropertyName)) ?? "Unknown"
            let rate = (try? CoreAudioProps.get(id,
                                                selector: kAudioDevicePropertyNominalSampleRate,
                                                defaultValue: Double(0))) ?? 0
            items.append(DeviceInfo(uid: uid, name: name, sampleRate: rate, isDefault: id == defaultInput))
        }
        return items
    }

    static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let err = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        return err == noErr && size > 0
    }

    /// Resolves a device UID to its AudioDeviceID; nil if the device is gone.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard let deviceIDs: [AudioDeviceID] = try? CoreAudioProps.getArray(
            AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices) else { return nil }
        for id in deviceIDs {
            if let devUID = try? CoreAudioProps.getString(id, selector: kAudioDevicePropertyDeviceUID),
               devUID == uid {
                return id
            }
        }
        return nil
    }

    static func defaultSystemOutputDeviceUID() throws -> String {
        let id: AudioDeviceID = try CoreAudioProps.get(
            AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            defaultValue: AudioDeviceID(0))
        guard id != 0 else { throw CaptureError.internalError("no default system output device") }
        return try CoreAudioProps.getString(id, selector: kAudioDevicePropertyDeviceUID)
    }
}
