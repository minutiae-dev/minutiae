import Foundation

/// Dispatches CoreMessages to actions. All message handling runs on one async
/// loop (serial), so session state needs no extra locking; events emitted from
/// capture/ASR threads go straight to the transport, which serializes writes.
public final class EngineController: @unchecked Sendable {
    private let transport: StdioTransport
    private var session: CaptureSession?
    private var activeStopId: String?
    private var asrEngine: FluidAudioEngine?
    private var asrLanguage = "en"

    private var messageContinuation: AsyncStream<CoreMessage>.Continuation?

    public init(transport: StdioTransport = StdioTransport()) {
        self.transport = transport
    }

    /// Starts the stdin reader and the serial handling loop. Returns
    /// immediately; the process exits from inside the loop on EOF/shutdown.
    public func run() {
        let (stream, continuation) = AsyncStream.makeStream(of: CoreMessage.self)
        messageContinuation = continuation
        transport.start(
            onMessage: { [weak self] msg in self?.messageContinuation?.yield(msg) },
            onEOF: { [weak self] in self?.requestShutdown() })

        Task { [weak self] in
            for await msg in stream {
                guard let self else { break }
                if case .shutdown = msg { break }
                await self.handle(msg)
            }
            await self?.cleanupAndExit()
        }
    }

    /// Same path as stdin EOF / `shutdown` message; also used for SIGINT/SIGTERM.
    public func requestShutdown() {
        messageContinuation?.finish()
    }

    private func cleanupAndExit() async {
        log("shutting down")
        if let session {
            let (audio, stats) = await session.stop()
            transport.send(.sessionStopped(id: activeStopId ?? "", sessionId: session.sessionId,
                                           audio: audio, stats: stats))
            self.session = nil
        }
        exit(0)
    }

    private func handle(_ msg: CoreMessage) async {
        switch msg {
        case .hello(let id):
            handleHello(id: id)
        case .listDevices(let id):
            handleListDevices(id: id)
        case .startSession(let id, let sessionId, let dir, let micDeviceUid, let engine, let language):
            handleStartSession(id: id, sessionId: sessionId, dir: dir,
                               micDeviceUid: micDeviceUid, engine: engine, language: language)
        case .stopSession(let id):
            await handleStopSession(id: id)
        case .ping(let id):
            transport.send(.pong(id: id))
        case .shutdown:
            break // handled in run()
        case .unknown(let type):
            // Forward compatibility: ignore unknown message types.
            log("ignoring unknown message type: \(type)")
        }
    }

    private func handleHello(id: String) {
        let ready = FluidAudioEngine.modelsCached()
        transport.send(.helloAck(id: id,
                                 protocolVersion: protocolVersion,
                                 engineVersions: ["parakeet-tdt-v3": FluidAudioEngine.version],
                                 modelsReady: ready))
        // Preload models at hello time when cached so start_session stays <1 s.
        // First-run download is deferred to start_session (model_progress UX).
        if ready {
            let engine = engineFor(language: asrLanguage)
            let transport = self.transport
            Task.detached {
                do {
                    try await engine.prepare { pct, stage in
                        transport.send(.modelProgress(pct: pct * 100,
                                                      stage: stage == "compiling" ? .compiling : .downloading))
                    }
                    log("ASR models preloaded")
                } catch {
                    log("ASR preload failed: \(error)")
                }
            }
        }
    }

    private func handleListDevices(id: String) {
        do {
            let items = try AudioDevices.listInputDevices()
            transport.send(.devices(id: id, items: items))
        } catch {
            transport.send(.devices(id: id, items: []))
            transport.send(.error(code: .internal,
                                  message: "device enumeration failed: \(error)",
                                  fatal: false, sessionId: nil))
        }
    }

    private func handleStartSession(id: String, sessionId: String, dir: String,
                                    micDeviceUid: String, engine: String, language: String) {
        guard session == nil else {
            transport.send(.error(code: .sessionAlreadyActive,
                                  message: "a session is already active",
                                  fatal: false, sessionId: sessionId))
            return
        }
        guard engine == "parakeet-tdt-v3" else {
            transport.send(.error(code: .badRequest,
                                  message: "unknown engine id: \(engine)",
                                  fatal: false, sessionId: sessionId))
            return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            transport.send(.error(code: .badRequest,
                                  message: "session dir does not exist or is not a directory: \(dir)",
                                  fatal: false, sessionId: sessionId))
            return
        }

        let asr = engineFor(language: language)
        let transport = self.transport
        let newSession = CaptureSession(sessionId: sessionId,
                                        dir: URL(fileURLWithPath: dir),
                                        micDeviceUid: micDeviceUid,
                                        asrEngine: asr) { msg in
            transport.send(msg)
        }
        do {
            try newSession.start()
            session = newSession
            transport.send(.sessionStarted(id: id, sessionId: sessionId,
                                           t0EpochMs: newSession.t0EpochMs))
        } catch let err as CaptureError {
            transport.send(.error(code: err.protocolCode, message: err.description,
                                  fatal: false, sessionId: sessionId))
        } catch {
            transport.send(.error(code: .internal, message: "session start failed: \(error)",
                                  fatal: false, sessionId: sessionId))
        }
    }

    private func handleStopSession(id: String) async {
        guard let session else {
            transport.send(.error(code: .noActiveSession,
                                  message: "no active session to stop",
                                  fatal: false, sessionId: nil))
            return
        }
        activeStopId = id
        let (audio, stats) = await session.stop()
        transport.send(.sessionStopped(id: id, sessionId: session.sessionId,
                                       audio: audio, stats: stats))
        self.session = nil
        activeStopId = nil
    }

    private func engineFor(language: String) -> FluidAudioEngine {
        if let asrEngine, asrLanguage == language {
            return asrEngine
        }
        let engine = FluidAudioEngine(language: language)
        asrEngine = engine
        asrLanguage = language
        return engine
    }
}
