import Foundation

/// NDJSON over stdio. Requests arrive on stdin (read line-by-line on a dedicated
/// thread); responses/events leave on stdout, serialized through a lock because
/// transcript events, levels and pongs originate on different threads/queues.
public final class StdioTransport: @unchecked Sendable {
    private let writeLock = NSLock()
    private var readerThread: Thread?
    /// Set once stdout is gone (EPIPE) so we stop trying — and stop logging —
    /// for every subsequent event.
    private var pipeClosed = false

    public init() {}

    /// Starts the stdin reader thread. `onMessage` is called for every parsed
    /// line; `onEOF` when stdin closes (graceful-shutdown signal per protocol).
    /// Unparseable lines are logged to stderr and skipped — never crash.
    public func start(onMessage: @escaping @Sendable (CoreMessage) -> Void,
                      onEOF: @escaping @Sendable () -> Void) {
        let thread = Thread {
            while let line = readLine(strippingNewline: true) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                do {
                    let msg = try Wire.decodeCore(Data(trimmed.utf8))
                    onMessage(msg)
                } catch {
                    log("failed to parse incoming line: \(error)")
                }
            }
            onEOF()
        }
        thread.name = "stdin-reader"
        thread.start()
        readerThread = thread
    }

    public func send(_ msg: EngineMessage) {
        let data: Data
        do {
            data = try Wire.encode(msg)
        } catch {
            log("failed to encode outgoing message: \(error)")
            return
        }
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !pipeClosed else { return }
        var out = data
        out.append(0x0A) // "\n"
        if !writeAll(out, to: STDOUT_FILENO) {
            // The core is gone. Say so once, then go quiet: stdin EOF is already
            // on its way and will drive the clean shutdown.
            pipeClosed = true
            log("stdout closed (errno \(errno)); stopping event writes")
        }
    }
}
