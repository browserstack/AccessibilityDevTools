import XCTest

@testable import A11yDemoLib

final class A11yDemoLibTests: XCTestCase {
    /// Sanity check that the sample target builds and links.
    func testLibraryIdentity() {
        XCTAssertEqual(A11yDemoLib.name, "A11yScanSPMConsumer")
    }

    /// End-to-end check that the `a11y-scan` command plugin runs against this
    /// package and reports the intentional issues in `SampleViews.swift`.
    ///
    /// Skipped by default: the plugin downloads the BrowserStack CLI and makes
    /// authenticated network calls, so it only runs when `RUN_A11Y_SCAN=1` and
    /// BrowserStack credentials are present in the environment.
    func testA11yScanPluginRuns() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["RUN_A11Y_SCAN"] == "1" else {
            throw XCTSkip("Set RUN_A11Y_SCAN=1 (with BrowserStack creds) to run the plugin end-to-end.")
        }
        // Treat an empty value as absent: CI exposes an unset secret as "" (present,
        // not nil), and running the scan with empty credentials fails at auth rather
        // than skipping.
        guard env["BROWSERSTACK_USERNAME"]?.isEmpty == false,
              env["BROWSERSTACK_ACCESS_KEY"]?.isEmpty == false else {
            throw XCTSkip("BROWSERSTACK_USERNAME / BROWSERSTACK_ACCESS_KEY are required for the scan.")
        }

        // tests/spm/Tests/A11yDemoLibTests/<thisFile> -> tests/spm
        let packageDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = packageDir.appendingPathComponent("scripts/run-a11y-scan.sh")

        // Run the scan twice and use the tool's own exit-code contract to prove it
        // not only ran but actually detected the intentional issues in
        // SampleViews.swift:
        //   * --non-strict -> exit 0    (CLI downloaded, authenticated, ran cleanly;
        //                                issues do not fail the run)
        //   * strict       -> exit != 0 (issues were found; strict fails on issues)
        // Asserting only the non-strict exit 0 would also pass if the scan
        // authenticated but found nothing -- a silent no-op. Requiring the strict
        // run to fail closes that gap.
        let clean = try runScan(script: script, packageDir: packageDir, strict: false)
        XCTAssertEqual(
            clean.status, 0,
            "a11y-scan did not run cleanly in --non-strict mode (exit \(clean.status)).\n\(clean.output)")

        let strict = try runScan(script: script, packageDir: packageDir, strict: true)
        XCTAssertNotEqual(
            strict.status, 0,
            "a11y-scan ran but reported no issues against SampleViews.swift (strict exit 0) -- possible silent no-op or engine regression.\n\(strict.output)")
    }

    /// Runs `scripts/run-a11y-scan.sh` (optionally strict) and returns its exit
    /// status plus combined stdout/stderr. Draining to EOF before `waitUntilExit`
    /// avoids a full-pipe-buffer deadlock without a background reader.
    private func runScan(script: URL, packageDir: URL, strict: Bool) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = strict ? [script.path] : [script.path, "--non-strict"]
        process.currentDirectoryURL = packageDir

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let collected = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return (process.terminationStatus, String(data: collected, encoding: .utf8) ?? "")
    }
}
