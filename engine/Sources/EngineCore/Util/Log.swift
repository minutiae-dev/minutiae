import Darwin
import Foundation

/// Writes all of `data` to `fd` with a POSIX `write(2)` loop, retrying short
/// writes and EINTR. Returns false if the write could not be completed.
///
/// Deliberately not `FileHandle.write(_:)`: that method raises an Objective-C
/// `NSFileHandleOperationException` when the pipe is gone (EPIPE), and Swift
/// cannot catch an ObjC exception — it goes straight to `std::terminate` and
/// aborts the process with SIGABRT. The core closing the pipe while we still
/// have a transcript event, level tick or log line in flight is routine (app
/// quit, supervisor restart), so a broken pipe has to be a silent no-op.
/// Note this is what makes the `signal(SIGPIPE, SIG_IGN)` in main.swift do what
/// its comment claims: ignoring SIGPIPE only turns the signal into an EPIPE
/// errno, which still has to be handled rather than raised.
@discardableResult
func writeAll(_ data: Data, to fd: Int32) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        guard var ptr = raw.baseAddress else { return true }
        var remaining = raw.count
        while remaining > 0 {
            let n = Darwin.write(fd, ptr, remaining)
            if n > 0 {
                ptr = ptr.advanced(by: n)
                remaining -= n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}

/// Human-readable logs go to stderr ONLY. stdout is reserved for the NDJSON protocol.
public func log(_ message: String) {
    let line = "[minutiae-engine] \(message)\n"
    writeAll(Data(line.utf8), to: STDERR_FILENO)
}
