import Foundation

/// Dispatches CoreMessages to actions. All message handling runs on one async
/// loop (serial), so session state needs no extra locking; events emitted from
/// capture/ASR threads go straight to the transport, which serializes writes.
public final class EngineController: @unchecked Sendable {
    private let transport: StdioTransport
    private var session: CaptureSession?
    private var activeStopId: String?
    private var asrEngine: AsrEngine?
    /// Engine id of the cached `asrEngine`; the default (Parakeet TDT v3)
    /// until a `prepare_models`/`start_session` selects otherwise.
    private var asrEngineId = AsrEngineRegistry.defaultId
    /// Language the cached engine was built for. Parakeet takes a language
    /// hint at construction, so a change has to rebuild it.
    private var asrLanguage = "auto"

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
            onMessage: { [weak self] msg in
                guard let self else { return }
                // Heartbeat liveness must not depend on the async handling loop
                // draining. Under sustained ASR load the cooperative thread pool
                // can delay the loop's continuation past the supervisor's
                // pong deadline (2 missed pings ≈ 10–15 s) and get the engine
                // killed mid-recording even though it is perfectly alive. Answer
                // pings here, on the dedicated stdin-reader thread, so a pong
                // proves the process is up regardless of transcription backlog.
                if case .ping(let id) = msg {
                    self.transport.send(.pong(id: id))
                    return
                }
                self.messageContinuation?.yield(msg)
            },
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
        case .hello(let id, let engine):
            handleHello(id: id, engine: engine)
        case .prepareModels(let id, let engine, let language):
            handlePrepareModels(id: id, engine: engine, language: language)
        case .listDevices(let id):
            handleListDevices(id: id)
        case .startSession(let id, let sessionId, let dir, let micDeviceUid, let engine, let language, let themSource):
            handleStartSession(id: id, sessionId: sessionId, dir: dir,
                               micDeviceUid: micDeviceUid, engine: engine, language: language,
                               themSource: themSource)
        case .stopSession(let id):
            await handleStopSession(id: id)
        case .ping(let id):
            // Normally answered on the reader thread (see run()); this is a
            // defensive fallback should a ping ever reach the handling loop.
            transport.send(.pong(id: id))
        case .shutdown:
            break // handled in run()
        case .unknown(let type):
            // Forward compatibility: ignore unknown message types.
            log("ignoring unknown message type: \(type)")
        }
    }

    private func handleHello(id: String, engine engineId: String?) {
        // Answer for the variant the core actually intends to use. Reporting on
        // the default instead would let a cached default mask a missing selected
        // model, deferring its download to the first start_session.
        if let engineId, AsrEngineRegistry.isKnown(engineId) {
            asrEngineId = engineId
        }
        let ready = AsrEngineRegistry.modelsCached(id: asrEngineId)
        transport.send(.helloAck(id: id,
                                 protocolVersion: protocolVersion,
                                 engineVersions: AsrEngineRegistry.engineVersions,
                                 modelsReady: ready))
        // Preload models at hello time when cached so start_session stays <1 s.
        // This is a SILENT optimization: models are already ready (hello_ack said
        // so), and this path sends no `models_ready`, so it must not stream
        // `model_progress` either — doing so leaves the UI's prep bar stuck at
        // "compiling 100%" with nothing to clear it. The first-run prep UX lives
        // in handlePrepareModels, which does end with `models_ready`.
        if ready {
            let engine = engineFor(engineId: asrEngineId, language: asrLanguage)
            Task.detached {
                do {
                    try await engine.prepare { _, _ in }
                    log("ASR models preloaded")
                } catch {
                    log("ASR preload failed: \(error)")
                }
            }
        }
    }

    /// Download (if needed), compile and load the ASR models, streaming
    /// progress, then reply `models_ready`. Runs detached so the serial
    /// message loop keeps answering pings during a multi-minute download.
    /// prepare() is idempotent and coalesces, so this is safe to call more
    /// than once and alongside a later start_session.
    private func handlePrepareModels(id: String, engine engineId: String?, language: String?) {
        let engine = engineFor(engineId: engineId ?? asrEngineId,
                               language: language ?? asrLanguage)
        let transport = self.transport
        Task.detached {
            do {
                try await engine.prepare { pct, stage in
                    transport.send(.modelProgress(pct: pct * 100,
                                                  stage: stage == "compiling" ? .compiling : .downloading))
                }
                transport.send(.modelsReady(id: id))
                log("ASR models ready")
            } catch {
                transport.send(.error(code: .modelDownloadFailed,
                                      message: "model download/compile failed: \(error)",
                                      fatal: false, sessionId: nil))
            }
        }
    }

    private func handleListDevices(id: String) {
        do {
            let items = try AudioDevices.listInputDevices()
            transport.send(.devices(id: id, items: items, output: AudioDevices.outputRoute()))
        } catch {
            transport.send(.devices(id: id, items: [], output: nil))
            transport.send(.error(code: .internal,
                                  message: "device enumeration failed: \(error)",
                                  fatal: false, sessionId: nil))
        }
    }

    private func handleStartSession(id: String, sessionId: String, dir: String,
                                    micDeviceUid: String, engine: String, language: String,
                                    themSource: String) {
        guard session == nil else {
            transport.send(.error(code: .sessionAlreadyActive,
                                  message: "a session is already active",
                                  fatal: false, sessionId: sessionId))
            return
        }
        guard AsrEngineRegistry.isKnown(engine) else {
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

        let asr = engineFor(engineId: engine, language: language)
        let transport = self.transport
        let newSession = CaptureSession(sessionId: sessionId,
                                        dir: URL(fileURLWithPath: dir),
                                        micDeviceUid: micDeviceUid,
                                        themSource: themSource,
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

    /// Returns the cached engine for `engineId`, rebuilding when the selected
    /// model or language changes. Unknown ids fall back to the default
    /// (start_session validates ids up front; hello/prepare default sensibly).
    private func engineFor(engineId: String, language: String) -> AsrEngine {
        if let asrEngine, asrEngineId == engineId, asrLanguage == language {
            return asrEngine
        }
        let engine = AsrEngineRegistry.make(id: engineId, language: language)
        asrEngine = engine
        asrEngineId = engineId
        asrLanguage = language
        return engine
    }
}
