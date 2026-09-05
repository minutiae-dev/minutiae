// minutiae-engine — Swift sidecar for the Minutiae app.
// NDJSON protocol on stdio (docs/protocol/sidecar-ipc-v1.md); logs on stderr.

import Dispatch
import EngineCore
import Foundation

// Dev diagnostic: `minutiae-engine --probe-system-audio` starts only the system
// tap, counts buffers for a few seconds, and prints a verdict. Run it directly
// from the terminal you launch `pnpm dev` in — TCC attributes the system-audio
// prompt to that terminal app, which then covers the sidecar it spawns.
if CommandLine.arguments.contains("--probe-system-audio") {
    fputs("probing system-audio tap — play something with sound now…\n", stderr)
    let tap = SystemAudioTap()
    var buffers = 0
    var frames = 0
    do {
        try tap.start { buffer, _ in
            buffers += 1
            frames += Int(buffer.frameLength)
        }
    } catch {
        fputs("FAIL: tap.start threw: \(error)\n", stderr)
        exit(2)
    }
    Thread.sleep(forTimeInterval: 4.0)
    tap.stop()
    if buffers > 0 {
        fputs("PASS: received \(buffers) buffers, \(frames) frames. System audio capture works.\n", stderr)
        exit(0)
    } else {
        fputs("FAIL: tap started but delivered 0 buffers in 4s — permission not granted or no prompt fired.\n", stderr)
        exit(1)
    }
}

// Dev diagnostic: `minutiae-engine --probe-output-route` prints what the engine
// thinks the far end is playing out of. This drives the pre-recording headset
// hint, and misreading it is the most likely cause of a wrong (or missing) hint
// in a field report — plug/unplug and re-run to see it change.
if CommandLine.arguments.contains("--probe-output-route") {
    let route = AudioDevices.outputRoute()
    fputs("output device : \(route.name)\n", stderr)
    fputs("transport     : \(route.transport)\n", stderr)
    fputs("route         : \(route.route.rawValue)\n", stderr)
    switch route.route {
    case .speakers:
        fputs("→ the far end is in the room; the UI suggests a headset.\n", stderr)
    case .headphones:
        fputs("→ no acoustic path; no hint shown.\n", stderr)
    case .unknown:
        fputs("→ can't tell; the UI stays quiet on purpose.\n", stderr)
    }
    exit(0)
}

let controller = EngineController()

// SIGINT/SIGTERM → same graceful path as stdin EOF / shutdown message.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
// Broken pipe on stdout (core died) must not kill us mid-write; EOF on stdin
// will arrive and drive the clean shutdown. This only downgrades the signal to
// an EPIPE errno — `writeAll` (Log.swift) is what actually handles it.
signal(SIGPIPE, SIG_IGN)

let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSource.setEventHandler { controller.requestShutdown() }
sigintSource.resume()

let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler { controller.requestShutdown() }
sigtermSource.resume()

log("minutiae-engine starting (pid \(ProcessInfo.processInfo.processIdentifier))")
controller.run()

dispatchMain()
