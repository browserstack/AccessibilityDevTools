import Foundation

// === DEVA11Y-484 EXTRACTION GUARD: shared block ===
// This block is mirrored verbatim in
//   tests/extraction-guard/swift-harness/Sources/ExtractionHarness/Guard.swift
// so the integration harness exercises the real logic. tests/extraction-guard/check_drift.sh
// fails CI if the two copies diverge. Edit both, or neither.
//
// Rationale: bsdtar writes decompressed bytes straight to disk, so a cap on the
// curl→bsdtar pipe would only bound the *compressed* size — useless against a
// decompression bomb. Instead we poll the destination directory while bsdtar runs
// and terminate it if the decompressed footprint crosses a byte OR entry ceiling
// (the entry ceiling stops a "millions of tiny files" bomb that stays small on disk).

/// Thread-safe flag shared between the extraction watchdog and the main flow.
final class ExtractionLimitState {
    private let lock = NSLock()
    private var didExceed = false
    private var why = ""

    func markExceeded(_ reason: String) {
        lock.lock()
        if !didExceed {
            didExceed = true
            why = reason
        }
        lock.unlock()
    }

    var exceeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didExceed
    }

    var reason: String {
        lock.lock()
        defer { lock.unlock() }
        return why
    }
}

/// Total bytes and entry count of all regular files under `url`.
func extractionFootprint(at url: URL) -> (bytes: Int64, entries: Int) {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
        return (0, 0)
    }
    var total: Int64 = 0
    var count = 0
    for case let element as URL in enumerator {
        count += 1
        let values = try? element.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        if values?.isRegularFile == true, let size = values?.fileSize {
            total += Int64(size)
        }
    }
    return (total, count)
}

/// Returns a rejection reason if the footprint under `directory` exceeds either ceiling.
func footprintExceeded(at directory: URL, maxBytes: Int64, maxEntries: Int) -> String? {
    let footprint = extractionFootprint(at: directory)
    if footprint.bytes > maxBytes {
        return "decompressed size exceeds \(maxBytes / (1024 * 1024)) MB"
    }
    if footprint.entries > maxEntries {
        return "archive contains more than \(maxEntries) entries"
    }
    return nil
}

/// Starts a background watchdog that terminates `process` (bsdtar) if the decompressed
/// footprint in `directory` exceeds the byte or entry ceiling.
///
/// This is a SOFT ceiling: bsdtar can write up to one poll interval's worth of data past
/// the limit before it is killed, so peak disk use is roughly `maxBytes + (pollInterval ×
/// disk write rate)`. The goal is to prevent disk *exhaustion* by a multi-GB/TB bomb, not
/// to enforce an exact byte count. The interval is kept short to bound the overshoot.
/// Callers MUST also run `footprintExceeded` once the process exits, to catch a fast bomb
/// that finished within a single poll interval.
func startExtractionWatchdog(on process: Process, directory: URL, maxBytes: Int64, maxEntries: Int) -> ExtractionLimitState {
    let state = ExtractionLimitState()
    let watchdog = Thread {
        while process.isRunning {
            if let reason = footprintExceeded(at: directory, maxBytes: maxBytes, maxEntries: maxEntries) {
                state.markExceeded(reason)
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
    watchdog.start()
    return state
}
// === END DEVA11Y-484 EXTRACTION GUARD ===
