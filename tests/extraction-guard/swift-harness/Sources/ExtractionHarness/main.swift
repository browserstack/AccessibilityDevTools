import Foundation

// Driver that reproduces the SPM plugin's extraction paths (extractRemoteArchive /
// extractLocalArchive) using the SHARED guard in Guard.swift, so the watchdog's
// terminate + report behaviour is exercised against real curl/bsdtar processes.
//
// Usage:
//   ExtractionHarness remote <url>  <destDir> <maxBytes> <maxEntries> [maxCompressed]
//   ExtractionHarness local  <path> <destDir> <maxBytes> <maxEntries>
//
// Emits a single JSON line describing the outcome so the shell test can assert on it:
//   {"exceeded":true,"reason":"...","bsdtarStatus":15,"curlStatus":0,"bytes":N,"entries":N,"elapsedMs":N}

struct Outcome: Encodable {
    var exceeded: Bool
    var reason: String
    var bsdtarStatus: Int32
    var curlStatus: Int32
    var bytes: Int64
    var entries: Int
    var elapsedMs: Int
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func emit(_ outcome: Outcome) {
    let data = try! JSONEncoder().encode(outcome)
    print(String(data: data, encoding: .utf8)!)
}

// Monotonic-ish elapsed time without Date (avoids wall-clock dependence).
func milliseconds(since start: UInt64) -> Int {
    let now = DispatchTime.now().uptimeNanoseconds
    return Int((now - start) / 1_000_000)
}

func extractRemote(url: String, into directory: URL, maxBytes: Int64, maxEntries: Int, maxCompressed: Int) -> Outcome {
    let start = DispatchTime.now().uptimeNanoseconds
    let pipe = Pipe()

    let curl = Process()
    curl.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    curl.arguments = ["curl", "-fsSL", "--max-filesize", String(maxCompressed), url]
    curl.standardOutput = pipe
    let curlError = Pipe()
    curl.standardError = curlError

    let bsdtar = Process()
    bsdtar.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    bsdtar.arguments = ["bsdtar", "-xpf", "-", "-C", directory.path]
    bsdtar.standardInput = pipe
    let tarError = Pipe()
    bsdtar.standardError = tarError

    do { try bsdtar.run() } catch { fail("bsdtar launch failed: \(error)") }

    let limitState = startExtractionWatchdog(on: bsdtar, directory: directory, maxBytes: maxBytes, maxEntries: maxEntries)

    do {
        try curl.run()
    } catch {
        bsdtar.terminate(); bsdtar.waitUntilExit(); fail("curl launch failed: \(error)")
    }

    curl.waitUntilExit()
    pipe.fileHandleForWriting.closeFile()
    bsdtar.waitUntilExit()

    let footprint = extractionFootprint(at: directory)
    if !limitState.exceeded, let reason = footprintExceeded(at: directory, maxBytes: maxBytes, maxEntries: maxEntries) {
        limitState.markExceeded(reason)
    }
    if limitState.exceeded {
        try? FileManager.default.removeItem(at: directory)
    }
    return Outcome(
        exceeded: limitState.exceeded,
        reason: limitState.reason,
        bsdtarStatus: bsdtar.terminationStatus,
        curlStatus: curl.terminationStatus,
        bytes: footprint.bytes,
        entries: footprint.entries,
        elapsedMs: milliseconds(since: start)
    )
}

func extractLocal(path: String, into directory: URL, maxBytes: Int64, maxEntries: Int) -> Outcome {
    let start = DispatchTime.now().uptimeNanoseconds
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["bsdtar", "-xpf", path, "-C", directory.path]
    let errorPipe = Pipe()
    process.standardError = errorPipe

    let limitState: ExtractionLimitState
    do {
        try process.run()
        limitState = startExtractionWatchdog(on: process, directory: directory, maxBytes: maxBytes, maxEntries: maxEntries)
        process.waitUntilExit()
    } catch {
        fail("bsdtar launch failed: \(error)")
    }

    let footprint = extractionFootprint(at: directory)
    if !limitState.exceeded, let reason = footprintExceeded(at: directory, maxBytes: maxBytes, maxEntries: maxEntries) {
        limitState.markExceeded(reason)
    }
    if limitState.exceeded {
        try? FileManager.default.removeItem(at: directory)
    }
    return Outcome(
        exceeded: limitState.exceeded,
        reason: limitState.reason,
        bsdtarStatus: process.terminationStatus,
        curlStatus: 0,
        bytes: footprint.bytes,
        entries: footprint.entries,
        elapsedMs: milliseconds(since: start)
    )
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 5 else {
    fail("usage: ExtractionHarness <remote|local> <urlOrPath> <destDir> <maxBytes> <maxEntries> [maxCompressed]")
}
let mode = args[0]
let source = args[1]
let destDir = URL(fileURLWithPath: args[2], isDirectory: true)
guard let maxBytes = Int64(args[3]), let maxEntries = Int(args[4]) else {
    fail("maxBytes and maxEntries must be integers")
}
try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

switch mode {
case "remote":
    let maxCompressed = args.count >= 6 ? (Int(args[5]) ?? 104857600) : 104857600
    emit(extractRemote(url: source, into: destDir, maxBytes: maxBytes, maxEntries: maxEntries, maxCompressed: maxCompressed))
case "local":
    emit(extractLocal(path: source, into: destDir, maxBytes: maxBytes, maxEntries: maxEntries))
default:
    fail("unknown mode: \(mode)")
}
