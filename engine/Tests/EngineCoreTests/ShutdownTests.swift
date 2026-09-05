import XCTest

@testable import EngineCore

/// The engine must survive losing its stdio pipes.
///
/// When the app quits, its ends of the sidecar's pipes close before the engine
/// finishes shutting down. `FileHandle.write` raises an Objective-C
/// `NSFileHandleOperationException` on EPIPE, which Swift cannot catch — it
/// terminates the process with SIGABRT. That aborted *before* `cleanupAndExit`
/// could stop the session, so the recording was never finalized, and the core
/// reported an ordinary quit to the user as "the transcription engine stopped".
///
/// This drives the real binary because the bug only exists at the process
/// boundary: it needs a genuinely closed pipe, not a mocked writer.
final class ShutdownTests: XCTestCase {
    /// The executable built alongside this test bundle.
    private func engineBinary() throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // EngineCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // engine
            .appendingPathComponent(".build/debug/minutiae-engine")
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: url.path),
            "engine binary not built at \(url.path)")
        return url
    }

    /// Closes the parent's pipe ends, then stdin, and reports how the engine died.
    private func exitStatusAfterClosing(stderr closeStderr: Bool, stdout closeStdout: Bool) throws
        -> Int32
    {
        let process = Process()
        process.executableURL = try engineBinary()
        let stdin = Pipe(), out = Pipe(), err = Pipe()
        process.standardInput = stdin
        process.standardOutput = out
        process.standardError = err
        try process.run()

        // Handshake first, so shutdown runs from a fully started engine.
        let hello = #"{"v":1,"type":"hello","id":"01H"}"# + "\n"
        stdin.fileHandleForWriting.write(Data(hello.utf8))
        Thread.sleep(forTimeInterval: 1.0)

        if closeStdout { try out.fileHandleForReading.close() }
        if closeStderr { try err.fileHandleForReading.close() }
        try stdin.fileHandleForWriting.close()  // EOF ⇒ graceful shutdown

        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            XCTFail("engine did not exit after stdin EOF")
            return -1
        }
        // Non-zero terminationReason ⇒ uncaught signal; expose which one.
        return process.terminationReason == .uncaughtSignal
            ? -process.terminationStatus : process.terminationStatus
    }

    func testExitsCleanlyWhenStderrPipeIsClosed() throws {
        // The exact crash in the field: `log("shutting down")` is the first line
        // of `cleanupAndExit`, and it writes to stderr.
        XCTAssertEqual(try exitStatusAfterClosing(stderr: true, stdout: false), 0)
    }

    func testExitsCleanlyWhenStdoutPipeIsClosed() throws {
        XCTAssertEqual(try exitStatusAfterClosing(stderr: false, stdout: true), 0)
    }

    func testExitsCleanlyWhenBothPipesAreClosed() throws {
        XCTAssertEqual(try exitStatusAfterClosing(stderr: true, stdout: true), 0)
    }
}
