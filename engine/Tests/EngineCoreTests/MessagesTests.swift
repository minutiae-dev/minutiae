import XCTest
@testable import EngineCore

/// Wire-format guard for docs/protocol/sidecar-ipc-v1.md. The exact-JSON
/// assertions use hand-written literals from the protocol doc (sorted keys —
/// Wire.encode uses .sortedKeys for byte-stable output).
final class MessagesTests: XCTestCase {

    private func encodeString(_ msg: EngineMessage) throws -> String {
        String(data: try Wire.encode(msg), encoding: .utf8)!
    }

    private func roundTrip(_ msg: EngineMessage) throws {
        let data = try Wire.encode(msg)
        let back = try JSONDecoder().decode(EngineMessage.self, from: data)
        XCTAssertEqual(back, msg)
    }

    private func roundTrip(_ msg: CoreMessage) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try enc.encode(msg)
        let back = try Wire.decodeCore(data)
        XCTAssertEqual(back, msg)
    }

    // MARK: Round-trips — every message type

    func testCoreMessageRoundTrips() throws {
        try roundTrip(CoreMessage.hello(id: "1"))
        try roundTrip(CoreMessage.listDevices(id: "2"))
        try roundTrip(CoreMessage.startSession(
            id: "3", sessionId: "01J9XYZ", dir: "/tmp/sessions/x",
            micDeviceUid: "BuiltInMicrophoneDevice", engine: "parakeet-tdt-v3", language: "en"))
        try roundTrip(CoreMessage.stopSession(id: "4"))
        try roundTrip(CoreMessage.ping(id: "5"))
        try roundTrip(CoreMessage.shutdown)
    }

    func testEngineMessageRoundTrips() throws {
        try roundTrip(EngineMessage.helloAck(
            id: "1", protocolVersion: 1,
            engineVersions: ["parakeet-tdt-v3": "0.15.2"], modelsReady: true))
        try roundTrip(EngineMessage.devices(id: "2", items: [
            DeviceInfo(uid: "uid-1", name: "MacBook Pro Microphone", sampleRate: 48000, isDefault: true),
            DeviceInfo(uid: "uid-2", name: "AirPods Pro", sampleRate: 24000, isDefault: false),
        ]))
        try roundTrip(EngineMessage.sessionStarted(id: "3", sessionId: "01J9XYZ", t0EpochMs: 1765432100123))
        try roundTrip(EngineMessage.modelProgress(pct: 42.5, stage: .downloading))
        try roundTrip(EngineMessage.modelProgress(pct: 99.5, stage: .compiling))
        try roundTrip(EngineMessage.transcript(
            sessionId: "01J9XYZ",
            segment: Segment(idx: 42, channel: .them, t0: 12.5, t1: 17.25, text: "hello",
                             confidence: 0.5, isFinal: true, engine: "parakeet-tdt-v3")))
        try roundTrip(EngineMessage.levels(sessionId: "01J9XYZ", meDb: -42.5, themDb: -120))
        try roundTrip(EngineMessage.sessionStopped(
            id: "4", sessionId: "01J9XYZ",
            audio: [AudioFileInfo(channel: .me, path: "/tmp/x/audio-me.caf", codec: "opus",
                                  container: "caf", durationS: 2621.5, sampleRate: 24000)],
            stats: SessionStats(segments: 31, droppedWindows: 0)))
        try roundTrip(EngineMessage.error(code: .tccDeniedSystem, message: "denied", fatal: false, sessionId: "01J9XYZ"))
        try roundTrip(EngineMessage.error(code: .internal, message: "boom", fatal: true, sessionId: nil))
        try roundTrip(EngineMessage.pong(id: "5"))
    }

    // MARK: Exact wire JSON

    func testTranscriptExactWire() throws {
        let msg = EngineMessage.transcript(
            sessionId: "01J9XYZ",
            segment: Segment(idx: 42, channel: .me, t0: 12.5, t1: 17.25, text: "hello world",
                             confidence: 0.5, isFinal: true, engine: "parakeet-tdt-v3"))
        XCTAssertEqual(
            try encodeString(msg),
            #"{"segment":{"channel":"me","confidence":0.5,"engine":"parakeet-tdt-v3","final":true,"idx":42,"t0":12.5,"t1":17.25,"text":"hello world"},"session_id":"01J9XYZ","type":"transcript","v":1}"#
        )
    }

    func testHelloAckExactWire() throws {
        let msg = EngineMessage.helloAck(
            id: "1", protocolVersion: 1,
            engineVersions: ["parakeet-tdt-v3": "0.15.2"], modelsReady: true)
        XCTAssertEqual(
            try encodeString(msg),
            #"{"engine_versions":{"parakeet-tdt-v3":"0.15.2"},"id":"1","models_ready":true,"protocol_version":1,"type":"hello_ack","v":1}"#
        )
    }

    func testStartSessionExactWireDecode() throws {
        let json = #"{"v":1,"type":"start_session","id":"7","session_id":"01J9XYZ","dir":"/tmp/sessions/x","mic_device_uid":"BuiltInMicrophoneDevice","engine":"parakeet-tdt-v3","language":"en"}"#
        let msg = try Wire.decodeCore(Data(json.utf8))
        XCTAssertEqual(msg, .startSession(
            id: "7", sessionId: "01J9XYZ", dir: "/tmp/sessions/x",
            micDeviceUid: "BuiltInMicrophoneDevice", engine: "parakeet-tdt-v3", language: "en"))
    }

    // MARK: Forward compatibility

    func testUnknownTypeDecodesWithoutCrashing() throws {
        let json = #"{"v":1,"type":"fancy_new_thing","id":"9","whatever":[1,2,3]}"#
        let msg = try Wire.decodeCore(Data(json.utf8))
        XCTAssertEqual(msg, .unknown(type: "fancy_new_thing"))
    }

    func testUnknownFieldsIgnored() throws {
        let json = #"{"v":1,"type":"ping","id":"3","extra_field":"future"}"#
        XCTAssertEqual(try Wire.decodeCore(Data(json.utf8)), .ping(id: "3"))
    }

    func testNoPrettyPrintingOnTheWire() throws {
        let out = try encodeString(.pong(id: "1"))
        XCTAssertFalse(out.contains("\n"))
        XCTAssertEqual(out, #"{"id":"1","type":"pong","v":1}"#)
    }

    func testErrorOmitsNilSessionId() throws {
        let out = try encodeString(.error(code: .badRequest, message: "x", fatal: false, sessionId: nil))
        XCTAssertFalse(out.contains("session_id"))
    }
}
