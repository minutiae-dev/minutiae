import Foundation

/// NDJSON over stdio. Requests arrive on stdin (read line-by-line on a dedicated
/// thread); responses/events leave on stdout, serialized through a lock because
/// streamed tokens, progress and pongs originate on different tasks/threads.
final class StdioTransport: @unchecked Sendable {
    private let writeLock = NSLock()
    private let stdout = FileHandle.standardOutput
    private var readerThread: Thread?

    init() {}

    /// Starts the stdin reader thread. `onMessage` is called for every parsed
    /// line; `onEOF` when stdin closes (graceful-shutdown signal per protocol).
    /// Unparseable lines are logged to stderr and skipped — never crash.
    func start(onMessage: @escaping @Sendable (CoreMessage) -> Void,
               onEOF: @escaping @Sendable () -> Void) {
        let thread = Thread {
            while let line = readLine(strippingNewline: true) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                do {
                    onMessage(try Wire.decodeCore(Data(trimmed.utf8)))
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

    func send(_ msg: LlmMessage) {
        let data: Data
        do {
            data = try Wire.encode(msg)
        } catch {
            log("failed to encode outgoing message: \(error)")
            return
        }
        writeLock.lock()
        defer { writeLock.unlock() }
        var out = data
        out.append(0x0A) // "\n"
        stdout.write(out)
    }
}
