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

    /// Human-readable name for a device UID (for logs); nil if gone.
    public static func deviceName(forUID uid: String) -> String? {
        guard let id = deviceID(forUID: uid) else { return nil }
        return try? CoreAudioProps.getString(id, selector: kAudioObjectPropertyName)
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

    /// UID of the device that *media* (YouTube, music, calls) plays through —
    /// `kAudioHardwarePropertyDefaultOutputDevice`. The tap's aggregate must be
    /// anchored here so it captures what's actually playing.
    ///
    /// NOT `kAudioHardwarePropertyDefaultSystemOutputDevice`: that is the device
    /// for UI/alert beeps, which macOS lets you set independently (e.g. media →
    /// USB headset, alerts → built-in speakers). Anchoring to it captures
    /// silence whenever the two differ.
    static func defaultOutputDeviceUID() throws -> String {
        let id: AudioDeviceID = try CoreAudioProps.get(
            AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            defaultValue: AudioDeviceID(0))
        guard id != 0 else { throw CaptureError.internalError("no default output device") }
        return try CoreAudioProps.getString(id, selector: kAudioDevicePropertyDeviceUID)
    }

    /// Human-readable transport of the current media output device
    /// ("built-in", "bluetooth", "usb", …).
    ///
    /// Diagnostics ONLY — never a gate for echo suppression. Transport does not
    /// determine whether an acoustic echo path exists: headphones in the
    /// built-in jack report "built-in", and USB/HDMI desk speakers report
    /// "usb"/"hdmi". Only envelope correlation can tell (see `EchoAnalyzer`).
    /// It is logged so that field reports say what the user was listening on.
    static func defaultOutputTransportDescription() -> String {
        guard let id: AudioDeviceID = try? CoreAudioProps.get(
                AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDefaultOutputDevice,
                defaultValue: AudioDeviceID(0)),
              id != 0,
              let raw: UInt32 = try? CoreAudioProps.get(
                id, selector: kAudioDevicePropertyTransportType, defaultValue: UInt32(0))
        else { return "unknown" }

        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "virtual"
        default: return "other"
        }
    }

    /// Best guess at whether the far end is reaching the room — i.e. whether the
    /// mic will also pick up what the `them` tap captures electronically.
    ///
    /// ADVISORY ONLY. This never gates echo suppression: as the note on
    /// `defaultOutputTransportDescription` says, transport alone cannot decide
    /// whether an acoustic path exists, and only `EchoAnalyzer`'s envelope
    /// correlation can. This exists so the UI can suggest a headset *before*
    /// recording, when there is no far-end audio to correlate yet.
    ///
    /// Deliberately biased toward saying nothing: a wrong "you're on speakers"
    /// on every launch would train the user to ignore the hint, so anything
    /// ambiguous reports `.unknown` and the UI stays quiet.
    public static func outputRoute() -> OutputDeviceInfo {
        guard let id: AudioDeviceID = try? CoreAudioProps.get(
                AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDefaultOutputDevice,
                defaultValue: AudioDeviceID(0)),
              id != 0
        else {
            return OutputDeviceInfo(name: "Unknown", transport: "unknown", route: .unknown)
        }

        let name = (try? CoreAudioProps.getString(id, selector: kAudioObjectPropertyName)) ?? "Unknown"
        let transport = defaultOutputTransportDescription()
        // A device that also captures is a headset (AirPods, USB/wired headset),
        // not a loudspeaker — the single most reliable signal we have here.
        let isHeadsetShaped = hasInputStreams(id)

        let route: OutputRoute
        switch transport {
        case "built-in":
            // The jack and the internal speaker are the same Core Audio device;
            // only the data source distinguishes them, so plugged-in headphones
            // are not mistaken for speakers.
            switch builtInOutputDataSource(id) {
            case .headphones: route = .headphones
            case .internalSpeaker: route = .speakers
            case .unknown: route = .unknown
            }
        case "bluetooth":
            // AirPods expose a mic; a Bluetooth speaker does not.
            route = isHeadsetShaped ? .headphones : .speakers
        case "hdmi", "displayport", "airplay":
            route = .speakers // a TV/monitor/remote speaker is always in the room
        case "usb":
            // A USB headset has a mic. Without one this is either desk speakers
            // or a headphone DAC, and we can't tell — so say nothing.
            route = isHeadsetShaped ? .headphones : .unknown
        default:
            route = .unknown // virtual/aggregate (loopback devices) and anything else
        }
        return OutputDeviceInfo(name: name, transport: transport, route: route)
    }

    /// Which physical output the built-in device is driving. macOS models the
    /// headphone jack as a *data source* on the same device as the speakers.
    private static func builtInOutputDataSource(_ id: AudioDeviceID) -> BuiltInOutput {
        guard let raw: UInt32 = try? CoreAudioProps.get(
            id,
            selector: kAudioDevicePropertyDataSource,
            scope: kAudioObjectPropertyScopeOutput,
            defaultValue: UInt32(0)) else { return .unknown }
        switch raw {
        case fourCharCode("hdpn"): return .headphones
        case fourCharCode("ispk"): return .internalSpeaker
        default: return .unknown
        }
    }

    private enum BuiltInOutput {
        case headphones
        case internalSpeaker
        case unknown
    }

    /// Core Audio identifies data sources by four-character code.
    private static func fourCharCode(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
