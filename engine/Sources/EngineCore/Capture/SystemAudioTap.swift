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
///
/// The aggregate is anchored to the device media actually plays through (the
/// default *output* device). The tap captures the mix destined for that device,
/// so if the default output changes mid-session (user unplugs a headset), we
/// re-anchor to the new device via a `kAudioHardwarePropertyDefaultOutputDevice`
/// listener — otherwise capture would silently go dead. The format presented to
/// the consumer stays fixed for the whole session (converting internally if a
/// later device's native format differs), so the writer/ASR feed never see a
/// mid-session format change.
public final class SystemAudioTap: @unchecked Sendable {
    public typealias BufferHandler = (AVAudioPCMBuffer, _ hostTime: UInt64) -> Void

    private var tapID: AudioObjectID = 0
    private var aggregateDeviceID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.minutiae.engine.system-tap", qos: .userInitiated)

    /// Format presented to the consumer for the whole session (established by
    /// the first anchored device); buffers from a re-anchored device are
    /// converted into it.
    private(set) public var tapFormat: AVAudioFormat?

    private var onBuffer: BufferHandler?
    private var currentOutputUID: String?
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?
    /// Held so add/remove use the same block reference (CoreAudio matches the
    /// listener by block identity).
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var running = false

    public init() {}

    /// 'nope' — what Core Audio returns when the TCC system-audio grant is missing.
    private static let permissionDeniedStatus: OSStatus = 0x6E6F7065

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    public func start(onBuffer: @escaping BufferHandler) throws {
        guard !running else { return }
        self.onBuffer = onBuffer

        let outputUID = try AudioDevices.defaultOutputDeviceUID()
        try buildTap(anchoredTo: outputUID)
        // The first device establishes the session format the consumer sees.
        tapFormat = nativeFormat
        installDefaultOutputListener()

        running = true
        log("system tap started — anchored to \(Self.describe(outputUID)) "
            + "(format: \(tapFormat.map(String.init(describing:)) ?? "?"))")
    }

    public func stop() {
        running = false
        removeDefaultOutputListener()
        teardownTap()
        onBuffer = nil
        log("system tap stopped")
    }

    // MARK: - Tap lifecycle

    /// Native format of the currently-anchored tap (may differ from the stable
    /// session `tapFormat` after a re-anchor).
    private var nativeFormat: AVAudioFormat?

    /// Create the tap + aggregate + IOProc anchored to `outputUID` and start it.
    /// Leaves the device-change listener untouched (used for both initial start
    /// and re-anchoring).
    private func buildTap(anchoredTo outputUID: String) throws {
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
            nativeFormat = format

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
                [weak self] inNow, inInputData, inInputTime, _, _ in
                guard let self, let format = self.nativeFormat,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                    bufferListNoCopy: inInputData,
                                                    deallocator: nil) else { return }
                let hostTime = inInputTime.pointee.mHostTime != 0
                    ? inInputTime.pointee.mHostTime
                    : inNow.pointee.mHostTime
                self.deliver(buffer, hostTime: hostTime)
            }
            guard err == noErr else {
                throw CaptureError.tapFailed("AudioDeviceCreateIOProcIDWithBlock failed: \(err)")
            }

            err = AudioDeviceStart(aggregateDeviceID, ioProcID)
            guard err == noErr else {
                throw CaptureError.tapFailed("AudioDeviceStart failed: \(err)")
            }
        } catch {
            teardownTap()
            throw error
        }

        currentOutputUID = outputUID
    }

    /// Deliver one tap buffer, converting to the stable session format if the
    /// (re-anchored) device's native format differs.
    private func deliver(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        guard let onBuffer, let sessionFormat = tapFormat else { return }
        if buffer.format == sessionFormat {
            onBuffer(buffer, hostTime)
            return
        }
        guard let converted = convert(buffer, to: sessionFormat) else { return }
        onBuffer(converted, hostTime)
    }

    /// Convert a native-format buffer into the session format (handles sample
    /// rate + channel-count changes from a hot-switched output device). The
    /// converter is reused across calls so its resampler state stays continuous.
    private func convert(_ input: AVAudioPCMBuffer, to outFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        if converter == nil || converterSource != input.format {
            converter = AVAudioConverter(from: input.format, to: outFormat)
            converterSource = input.format
        }
        guard let converter else { return nil }

        let ratio = outFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }

        var supplied = false
        var convError: NSError?
        converter.convert(to: output, error: &convError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard convError == nil, output.frameLength > 0 else { return nil }
        return output
    }

    /// Tear down tap + aggregate + IOProc, leaving the listener and stored
    /// `onBuffer`/`tapFormat` intact so the tap can be rebuilt on re-anchor.
    private func teardownTap() {
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

    // MARK: - Re-anchoring on default-output change

    private func installDefaultOutputListener() {
        guard listenerBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDefaultOutputChange()
        }
        let err = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, queue, block)
        if err == noErr {
            listenerBlock = block
        } else {
            log("failed to observe default-output changes (OSStatus \(err)); tap won't follow device switches")
        }
    }

    private func removeDefaultOutputListener() {
        guard let block = listenerBlock else { return }
        let err = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress, queue, block)
        if err != noErr { log("AudioObjectRemovePropertyListenerBlock failed: \(err)") }
        listenerBlock = nil
    }

    /// Default output device changed: rebuild the tap anchored to the new device
    /// so capture keeps following where media actually plays. Runs on `queue`.
    private func handleDefaultOutputChange() {
        guard running else { return }
        guard let newUID = try? AudioDevices.defaultOutputDeviceUID() else { return }
        guard newUID != currentOutputUID else { return }

        log("default output changed → re-anchoring system tap to \(Self.describe(newUID))")
        teardownTap()
        do {
            try buildTap(anchoredTo: newUID)
        } catch {
            // Capture goes silent until the next change, but the session (and
            // the mic channel) keep running.
            log("re-anchor to \(Self.describe(newUID)) failed: \(error)")
        }
    }

    private static func describe(_ uid: String) -> String {
        if let name = AudioDevices.deviceName(forUID: uid) { return "\(name) [\(uid)]" }
        return uid
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

    deinit {
        removeDefaultOutputListener()
        teardownTap()
    }
}
