import Foundation

/// Logs go to stderr only — stdout is the NDJSON protocol channel.
func log(_ message: String) {
    FileHandle.standardError.write(Data("[minutiae-llm] \(message)\n".utf8))
}
