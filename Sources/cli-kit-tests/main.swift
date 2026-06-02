import Foundation
import BrowserStackCLIKit

// Executable test harness for the real BrowserStackCLIKit logic. Plain Swift (no XCTest) so it
// runs under Command Line Tools as well as Xcode/CI. Exercises the actual shipped code paths —
// extractLocalArchive/extractRemoteArchive, the watchdog, locateExecutable, and arg parsing —
// against live bsdtar and crafted archives. Everything is bounded so a regressed guard cannot
// exhaust the disk. Exits non-zero if any check fails.

var pass = 0, fail = 0
func ok(_ m: String) { pass += 1; print("  \u{001B}[32mPASS\u{001B}[0m \(m)") }
func bad(_ m: String) { fail += 1; print("  \u{001B}[31mFAIL\u{001B}[0m \(m)") }
func check(_ cond: Bool, _ m: String) { cond ? ok(m) : bad(m) }
func checkThrows(_ m: String, _ body: () throws -> Void) {
    do { try body(); bad("\(m) (expected throw)") } catch { ok("\(m) — threw \(type(of: error))") }
}

let fm = FileManager.default
let work = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("bsk-kit-tests-\(UUID().uuidString)", isDirectory: true)
try! fm.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: work) }

func freshDir() -> URL {
    let d = work.appendingPathComponent("d-\(UUID().uuidString)", isDirectory: true)
    try? fm.removeItem(at: d)
    return d
}
func writeZeros(_ url: URL, megabytes: Int) {
    fm.createFile(atPath: url.path, contents: nil)
    let h = try! FileHandle(forWritingTo: url)
    let chunk = Data(count: 1024 * 1024)
    for _ in 0..<megabytes { h.write(chunk) }
    try? h.close()
}
func makeArchive(_ dest: URL, _ populate: (URL) -> Void) {
    let stage = freshDir(); try! fm.createDirectory(at: stage, withIntermediateDirectories: true)
    populate(stage)
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["bsdtar", "-czf", dest.path, "-C", stage.path, "."]
    try! p.run(); p.waitUntilExit()
    try? fm.removeItem(at: stage)
}
func downloader() -> BrowserStackCLIDownloader {
    BrowserStackCLIDownloader(overrideURL: nil, forceDownload: true, cacheRoot: work)
}
let MB = 1024 * 1024

print("── BrowserStackCLIKit unit tests (real bsdtar, bounded fixtures) ──")

// 1. parseOverride — HTTPS only
do { check(try parseOverride(urlString: nil) == nil, "parseOverride(nil) → nil") } catch { bad("parseOverride(nil) threw \(error)") }
do { check(try parseOverride(urlString: "https://x/y.tgz")?.scheme == "https", "parseOverride accepts https") } catch { bad("parseOverride(https) threw \(error)") }
checkThrows("parseOverride rejects http") { _ = try parseOverride(urlString: "http://x/y.tgz") }
checkThrows("parseOverride rejects file") { _ = try parseOverride(urlString: "file:///etc/passwd") }
checkThrows("parseOverride rejects bare path") { _ = try parseOverride(urlString: "/tmp/evil.tgz") }

// 2. parseArguments
let pa = parseArguments(["--force-download", "--download-url", "https://x/y.tgz", "scan", "--", "--download-url", "raw"])
check(pa.forceDownload, "parseArguments: force-download flag")
check(pa.downloadURL == "https://x/y.tgz", "parseArguments: download-url value")
check(pa.passthrough == ["scan", "--", "--download-url", "raw"], "parseArguments: passthrough preserves post-`--`")
check(parseArguments(["--download-url=https://a/b.tgz"]).downloadURL == "https://a/b.tgz", "parseArguments: --download-url= form")

// 3. sanitizeArguments
check(sanitizeArguments(["--output-format", "xcode", "a"]) == ["a"], "sanitize strips --output-format <v>")
check(sanitizeArguments(["-o", "json", "b"]) == ["b"], "sanitize strips -o <v>")
check(sanitizeArguments(["--output-format=sonar", "c"]) == ["c"], "sanitize strips --output-format=")
check(sanitizeArguments(["-oxcode", "d"]) == ["d"], "sanitize strips -o<short>")
check(sanitizeArguments(["--", "--output-format", "x"]) == ["--", "--output-format", "x"], "sanitize leaves post-`--` intact")

// 4. extractVersion
check(extractVersion(from: URL(string: "https://x/binary-macos-arm64-1.34.4.zip")!) == "1.34.4", "extractVersion parses version")
check(extractVersion(from: URL(string: "https://x/binary.zip")!) == nil, "extractVersion nil when absent")

// 5. footprint
do {
    let d = freshDir(); try! fm.createDirectory(at: d, withIntermediateDirectories: true)
    writeZeros(d.appendingPathComponent("a"), megabytes: 3)
    let fp = extractionFootprint(at: d)
    check(fp.entries == 1 && fp.bytes == Int64(3 * MB), "extractionFootprint counts bytes+entries")
    check(footprintExceeded(at: d, maxBytes: Int64(10 * MB), maxEntries: 10) == nil, "footprint within limits → nil")
    check(footprintExceeded(at: d, maxBytes: Int64(MB), maxEntries: 10) != nil, "footprint over bytes → reason")
    check(footprintExceeded(at: d, maxBytes: Int64(10 * MB), maxEntries: 0) != nil, "footprint over entries → reason")
}

// 6. extractLocalArchive — legit binary found and runnable
do {
    let archive = work.appendingPathComponent("legit.tar.gz")
    makeArchive(archive) { stage in try? fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: stage.appendingPathComponent("browserstack-cli")) }
    let dest = freshDir(); try! fm.createDirectory(at: dest, withIntermediateDirectories: true)
    do {
        try downloader().extractLocalArchive(at: archive, into: dest)
        let bin = try downloader().locateExecutable(in: dest, preferredName: "browserstack-cli")
        check(fm.isExecutableFile(atPath: bin.path), "extractLocalArchive(legit): binary extracted + executable")
    } catch { bad("extractLocalArchive(legit) threw \(error)") }
}

// 7. extractLocalArchive — 300 MB bomb rejected + cleaned up (real 200 MB cap)
do {
    let archive = work.appendingPathComponent("bomb.tar.gz")
    makeArchive(archive) { stage in writeZeros(stage.appendingPathComponent("browserstack-cli"), megabytes: 300) }
    let dest = freshDir(); try! fm.createDirectory(at: dest, withIntermediateDirectories: true)
    do {
        try downloader().extractLocalArchive(at: archive, into: dest)
        bad("extractLocalArchive(bomb): expected rejection")
    } catch let e as CLIExit {
        check(e.code == 1 && e.message.contains("decompressed size"), "extractLocalArchive(bomb): CLIExit cites size")
    } catch { bad("extractLocalArchive(bomb): wrong error \(error)") }
    check(!fm.fileExists(atPath: dest.path), "extractLocalArchive(bomb): dir removed")
}

// 8. watchdog terminates oversize extraction mid-stream (400 MB bomb, 20 MB cap)
do {
    let archive = work.appendingPathComponent("bomb400.tar.gz")
    makeArchive(archive) { stage in writeZeros(stage.appendingPathComponent("payload"), megabytes: 400) }
    let dest = freshDir(); try! fm.createDirectory(at: dest, withIntermediateDirectories: true)
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["bsdtar", "-xpf", archive.path, "-C", dest.path]; p.standardError = Pipe()
    try! p.run()
    let state = startExtractionWatchdog(on: p, directory: dest, maxBytes: Int64(20 * MB), maxEntries: 10_000)
    p.waitUntilExit()
    check(state.exceeded, "watchdog(size): flagged")
    check(p.terminationStatus == 15, "watchdog(size): bsdtar SIGTERM'd mid-stream")
    let peakMB = extractionFootprint(at: dest).bytes / Int64(MB)
    check(peakMB < 300, "watchdog(size): peak \(peakMB)MB bounded below 400 MB bomb")
    try? fm.removeItem(at: dest)
}

// 9. watchdog terminates on entry count (20k tiny files, 5k cap)
do {
    let archive = work.appendingPathComponent("many.tar.gz")
    makeArchive(archive) { stage in for i in 0..<20_000 { fm.createFile(atPath: stage.appendingPathComponent("f\(i)").path, contents: nil) } }
    let dest = freshDir(); try! fm.createDirectory(at: dest, withIntermediateDirectories: true)
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["bsdtar", "-xpf", archive.path, "-C", dest.path]; p.standardError = Pipe()
    try! p.run()
    let state = startExtractionWatchdog(on: p, directory: dest, maxBytes: Int64(200 * MB), maxEntries: 5_000)
    p.waitUntilExit()
    check(state.exceeded && state.reason.contains("entries"), "watchdog(entries): flagged on entry count")
    try? fm.removeItem(at: dest)
}

// 10. locateExecutable entry cap
do {
    let d = freshDir(); try! fm.createDirectory(at: d, withIntermediateDirectories: true)
    for i in 0...(BrowserStackCLIDownloader.maxArchiveEntries + 5) {
        fm.createFile(atPath: d.appendingPathComponent("f\(i)").path, contents: Data("x".utf8))
    }
    checkThrows("locateExecutable rejects > \(BrowserStackCLIDownloader.maxArchiveEntries) entries") {
        _ = try downloader().locateExecutable(in: d, preferredName: "browserstack-cli")
    }
}

print("")
if fail == 0 {
    print("\u{001B}[32mALL GREEN\u{001B}[0m  \(pass) passed, 0 failed")
    exit(0)
} else {
    print("\u{001B}[31mFAILURES\u{001B}[0m  \(pass) passed, \(fail) failed")
    exit(1)
}
