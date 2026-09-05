import Foundation

/// Dispatches CoreMessages to actions. The message loop is serial, but long
/// operations (model load, generation) run in detached Tasks so the loop keeps
/// answering `ping`/`cancel` mid-generation. One generation runs at a time;
/// `currentGeneration` is guarded by a lock since the detached Task clears it.
final class LLMController: @unchecked Sendable {
    private let transport: StdioTransport
    private let runner = ModelRunner()

    private let genLock = NSLock()
    private var currentGeneration: (id: String, task: Task<Void, Never>)?

    private var messageContinuation: AsyncStream<CoreMessage>.Continuation?

    init(transport: StdioTransport = StdioTransport()) {
        self.transport = transport
    }

    /// Starts the stdin reader and the serial handling loop. Returns
    /// immediately; the process exits from inside the loop on EOF/shutdown.
    func run() {
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
            self?.cleanupAndExit()
        }
    }

    /// Same path as stdin EOF / `shutdown`; also used for SIGINT/SIGTERM.
    func requestShutdown() {
        messageContinuation?.finish()
    }

    private func cleanupAndExit() {
        cancelCurrent(matching: nil)
        log("shutting down")
        exit(0)
    }

    private func handle(_ msg: CoreMessage) async {
        switch msg {
        case .hello(let id):
            let loaded = await runner.currentModel
            transport.send(.helloAck(id: id, protocolVersion: protocolVersion,
                                     runtime: "mlx", loadedModel: loaded))
        case .prepareModel(let id, let model):
            handlePrepareModel(id: id, model: model)
        case .enhance(let id, let model, let prompt, let system, let options):
            handleEnhance(id: id, model: model, prompt: prompt, system: system, options: options)
        case .cancel(_, let requestId):
            cancelCurrent(matching: requestId)
        case .ping(let id):
            transport.send(.pong(id: id))
        case .shutdown:
            break // handled in run()
        case .unknown(let type):
            log("ignoring unknown message type: \(type)")
        }
    }

    /// Pre-warm: download (if needed) and load a model, streaming progress, then
    /// reply `model_ready`. Detached so the loop stays responsive during a
    /// multi-minute download.
    private func handlePrepareModel(id: String, model: String) {
        let transport = self.transport
        let runner = self.runner
        Task.detached {
            do {
                try await runner.ensureLoaded(model) { pct, stage in
                    transport.send(.modelProgress(pct: pct * 100, stage: stage))
                }
                transport.send(.modelReady(id: id, model: model))
            } catch {
                transport.send(.error(code: .modelLoadFailed,
                                      message: "model load failed: \(error)",
                                      fatal: false, requestId: id))
            }
        }
    }

    /// Run one streamed completion. Rejects if a generation is already active.
    private func handleEnhance(id: String, model: String, prompt: String,
                               system: String?, options: EnhanceOptions) {
        genLock.lock()
        let busy = currentGeneration != nil
        genLock.unlock()
        if busy {
            transport.send(.error(code: .badRequest,
                                  message: "a generation is already in progress",
                                  fatal: false, requestId: id))
            return
        }

        let transport = self.transport
        let runner = self.runner
        let start = Date()
        let task = Task { [weak self] in
            do {
                let (finish, completion) = try await runner.generate(
                    model: model, system: system, prompt: prompt, options: options,
                    progress: { pct, stage in
                        transport.send(.modelProgress(pct: pct * 100, stage: stage))
                    },
                    onToken: { text in
                        transport.send(.llmToken(id: id, text: text))
                    })
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                let tps = ms > 0 ? Double(completion) / (Double(ms) / 1000.0) : 0
                transport.send(.llmDone(id: id, finishReason: finish,
                                        stats: Stats(promptTokens: 0,
                                                     completionTokens: completion,
                                                     durationMs: ms, tokensPerS: tps)))
            } catch is CancellationError {
                transport.send(.llmDone(id: id, finishReason: .cancelled,
                                        stats: Stats(promptTokens: 0, completionTokens: 0,
                                                     durationMs: 0, tokensPerS: 0)))
            } catch {
                transport.send(.error(code: .generationFailed,
                                      message: "generation failed: \(error)",
                                      fatal: false, requestId: id))
            }
            self?.clearGeneration(id: id)
        }

        genLock.lock()
        currentGeneration = (id, task)
        genLock.unlock()
    }

    /// Cancel the active generation. `matching == nil` cancels whatever is
    /// running (shutdown); otherwise only if its id matches `request_id`.
    private func cancelCurrent(matching requestId: String?) {
        genLock.lock()
        let current = currentGeneration
        genLock.unlock()
        guard let current else { return }
        if let requestId, current.id != requestId { return }
        current.task.cancel()
    }

    private func clearGeneration(id: String) {
        genLock.lock()
        if currentGeneration?.id == id { currentGeneration = nil }
        genLock.unlock()
    }
}
