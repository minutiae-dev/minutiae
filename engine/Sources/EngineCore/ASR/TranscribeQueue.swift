import Foundation

/// Runs submitted work strictly one at a time by chaining each submission onto
/// the previous one's completion.
///
/// An actor is not enough on its own: actors are re-entrant across `await`, so
/// two callers can interleave inside a single method body. Both capture
/// channels run their own `WindowedTranscriber` against one shared engine, and
/// an interleaved decode corrupts the underlying manager's state — for Nemotron
/// a `reset()` landing inside the other channel's in-flight window, for Parakeet
/// two decodes sharing one `AsrManager`'s CoreML buffers.
public actor TranscribeQueue {
    private var tail: Task<Void, Never>?

    public init() {}

    public func run<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, Error> {
            if let previous { await previous.value }
            return try await body()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}
