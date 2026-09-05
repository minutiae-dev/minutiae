// minutiae-llm — Swift LLM sidecar for the Minutiae app.
// NDJSON protocol on stdio (docs/protocol/llm-ipc-v1.md); logs on stderr.

import Dispatch
import Foundation

let controller = LLMController()

// SIGINT/SIGTERM → same graceful path as stdin EOF / shutdown message.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
// Broken pipe on stdout (core died) must not kill us mid-write; EOF on stdin
// will arrive and drive the clean shutdown.
signal(SIGPIPE, SIG_IGN)

let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler { controller.requestShutdown() }
sigintSource.resume()

let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler { controller.requestShutdown() }
sigtermSource.resume()

log("minutiae-llm starting (pid \(ProcessInfo.processInfo.processIdentifier))")
controller.run()

dispatchMain()
