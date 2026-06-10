import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// System-wide audio capture ("them" channel) excluding our own process.
/// Approach ported from AudioCap (insidegui/AudioCap, ProcessTap.swift):
/// CATapDescription → AudioHardwareCreateProcessTap → private aggregate device
/// containing the tap → AudioDeviceCreateIOProcIDWithBlock → AudioDeviceStart.
/// Captures Zoom/Meet/Teams/browser output regardless of output device.
/// Requires macOS 14.4+ and the NSAudioCaptureUsageDescription TCC grant.
public final class SystemAudioTap: @unchecked Sendable {
    public typealias BufferHandler = (AVAudioPCMBuffer, _ hostTime: UInt64) -> Void

    private var tapID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.minutiae.engine.system-tap", qos: .userInitiated)
    private(set) public var tapFormat: AVAudioFormat?
    private var running = false

    public init() {}

    /// 'nope' — what Core Audio returns when the TCC system-audio grant is missing.
    private static let permissionDeniedStatus: OSStatus = 0x6E6F7065

    public func start(onBuffer: @escaping BufferHandler) throws {
        guard !running else { return }

        // Tap every process EXCEPT ourselves (we never want our own output;
        // also avoids feedback if the app ever plays audio).
        var excluded: [AudioObjectID] = []
        if let selfObject = Self.translatePIDToProcessObject(pid_t(ProcessInfo.processInfo.processIdentifier)) {
            excluded.append(selfObject)
        }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.muteBehavior = CATapMuteBehavior.unmuted
        description.isPrivate = true

        var newTapID: AudioObjectID = 0
        var err = AudioHardwareCreateProcessTap(description, &newTapID)
        guard err == noErr else {
            if err == Self.permissionDeniedStatus {
                throw CaptureError.tccDeniedSystem("system audio capture permission denied (OSStatus \(err))")
            }
            throw CaptureError.tapFailed("AudioHardwareCreateProcessTap failed: \(err)")
        }
        tapID = newTapID

        do {
            // Read the tap's stream format — never assume one.
            var asbd: AudioStreamBasicDescription = try CoreAudioProps.get(
                tapID, selector: kAudioTapPropertyFormat,
                defaultValue: AudioStreamBasicDescription())
            guard let format = AVAudioFormat(streamDescription: &asbd) else {
                throw CaptureError.tapFailed("could not build AVAudioFormat from tap stream description")
            }
            tapFormat = format

            let outputUID = try AudioDevices.defaultSystemOutputDeviceUID()
            let aggregateUID = UUID().uuidString
            let aggDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "minutiae-tap",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                    ]
                ],
            ]

            var aggID: AudioObjectID = 0
            err = AudioHardwareCreateAggregateDevice(aggDescription as CFDictionary, &aggID)
            guard err == noErr else {
                throw CaptureError.tapFailed("AudioHardwareCreateAggregateDevice failed: \(err)")
            }
            aggregateDeviceID = aggID

            err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, queue) {
                inNow, inInputData, inInputTime, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                    bufferListNoCopy: inInputData,
                                                    deallocator: nil) else { return }
                let hostTime = inInputTime.pointee.mHostTime != 0
                    ? inInputTime.pointee.mHostTime
                    : inNow.pointee.mHostTime
                onBuffer(buffer, hostTime)
            }
            guard err == noErr else {
                throw CaptureError.tapFailed("AudioDeviceCreateIOProcIDWithBlock failed: \(err)")
            }

            err = AudioDeviceStart(aggregateDeviceID, ioProcID)
            guard err == noErr else {
                throw CaptureError.tapFailed("AudioDeviceStart failed: \(err)")
            }
        } catch {
            teardown()
            throw error
        }

        running = true
        log("system tap started (format: \(tapFormat.map(String.init(describing:)) ?? "?"))")
    }

    public func stop() {
        guard running else {
            teardown()
            return
        }
        running = false
        teardown()
        log("system tap stopped")
    }

    private func teardown() {
        if aggregateDeviceID != 0 {
            if let procID = ioProcID {
                var err = AudioDeviceStop(aggregateDeviceID, procID)
                if err != noErr { log("AudioDeviceStop failed: \(err)") }
                err = AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
                if err != noErr { log("AudioDeviceDestroyIOProcID failed: \(err)") }
                ioProcID = nil
            }
            let err = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if err != noErr { log("AudioHardwareDestroyAggregateDevice failed: \(err)") }
            aggregateDeviceID = 0
        }
        if tapID != 0 {
            let err = AudioHardwareDestroyProcessTap(tapID)
            if err != noErr { log("AudioHardwareDestroyProcessTap failed: \(err)") }
            tapID = 0
        }
    }

    /// PID → Core Audio process object (for the tap exclusion list).
    static func translatePIDToProcessObject(_ pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pidValue = pid
        var objectID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = withUnsafeMutablePointer(to: &pidValue) { pidPtr in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<pid_t>.size), pidPtr,
                                       &size, &objectID)
        }
        guard err == noErr, objectID != 0 else { return nil }
        return objectID
    }

    deinit { teardown() }
}
