import Foundation

/// Human-readable logs go to stderr ONLY. stdout is reserved for the NDJSON protocol.
public func log(_ message: String) {
    let line = "[minutiae-engine] \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
}
