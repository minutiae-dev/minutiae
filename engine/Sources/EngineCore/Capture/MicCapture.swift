import AVFoundation
import CoreAudio
import Foundation

/// Microphone capture ("me" channel) via AVAudioEngine.inputNode.
/// INVARIANT: the tap uses the node's NATIVE format (inputFormat(forBus: 0)) —
/// AirPods mics deliver 16/24 kHz and forcing 48 kHz throws. Record native
/// rate; only the ASR feed is resampled.
public final class MicCapture: @unchecked Sendable {
    public typealias BufferHandler = (AVAudioPCMBuffer, _ hostTime: UInt64) -> Void

    private var engine: AVAudioEngine?
    private(set) public var captureFormat: AVAudioFormat?
    private(set) public var deviceName: String = "Microphone"
    private var running = false

    public init() {}

    /// Starts capturing from the device with the given UID (empty string =
    /// system default input).
    public func start(deviceUID: String, onBuffer: @escaping BufferHandler) throws {
        guard !running else { return }

        try Self.ensureMicPermission()

        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Route the input node to the requested device BEFORE reading its
        // native format. Set kAudioOutputUnitProperty_CurrentDevice on the
        // input node's underlying audio unit.
        if !deviceUID.isEmpty {
            guard let deviceID = AudioDevices.deviceID(forUID: deviceUID) else {
                throw CaptureError.deviceGone("no input device with uid \(deviceUID)")
            }
            guard let audioUnit = input.audioUnit else {
                throw CaptureError.internalError("inputNode has no audio unit")
            }
            var devID = deviceID
            let err = AudioUnitSetProperty(audioUnit,
                                           kAudioOutputUnitProperty_CurrentDevice,
                                           kAudioUnitScope_Global,
                                           0,
                                           &devID,
                                           UInt32(MemoryLayout<AudioDeviceID>.size))
            guard err == noErr else {
                throw CaptureError.deviceGone("failed to select input device \(deviceUID): \(err)")
            }
            deviceName = (try? CoreAudioProps.getString(deviceID, selector: kAudioObjectPropertyName)) ?? "Microphone"
        }

        let format = input.inputFormat(forBus: 0) // NATIVE format — never force.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.tapFailed("mic input format unavailable (rate \(format.sampleRate), ch \(format.channelCount))")
        }
        captureFormat = format

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            onBuffer(buffer, when.hostTime)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.tapFailed("AVAudioEngine.start failed: \(error.localizedDescription)")
        }

        self.engine = engine
        running = true
        log("mic capture started (\(deviceName), \(format.sampleRate) Hz, \(format.channelCount) ch)")
    }

    public func stop() {
        guard running else { return }
        running = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        log("mic capture stopped")
    }

    /// Checks (and if undetermined, requests) the microphone TCC grant.
    static func ensureMicPermission() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .denied, .restricted:
            throw CaptureError.tccDeniedMic("microphone permission denied")
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted = ok
                semaphore.signal()
            }
            semaphore.wait()
            if !granted {
                throw CaptureError.tccDeniedMic("microphone permission denied")
            }
        @unknown default:
            throw CaptureError.tccDeniedMic("microphone permission state unknown")
        }
    }
}
