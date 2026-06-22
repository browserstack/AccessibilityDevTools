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
        guard env["BROWSERSTACK_USERNAME"] != nil, env["BROWSERSTACK_ACCESS_KEY"] != nil else {
            throw XCTSkip("BROWSERSTACK_USERNAME / BROWSERSTACK_ACCESS_KEY are required for the scan.")
        }

        // tests/spm/Tests/A11yDemoLibTests/<thisFile> -> tests/spm
        let packageDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = packageDir.appendingPathComponent("scripts/run-a11y-scan.sh")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, "--non-strict"]
        process.currentDirectoryURL = packageDir
        try process.run()
        process.waitUntilExit()

        // --non-strict makes the scan exit 0 even when issues are found, so a
        // clean exit means the plugin downloaded, authenticated, and ran.
        XCTAssertEqual(process.terminationStatus, 0, "a11y-scan plugin failed to run")
    }
}
