import Foundation
import PackagePlugin

// Thin command plugin. SwiftPM command plugins cannot link a library target, so all of the
// download / extract / guard / run logic lives in the BrowserStackCLIKit library and is
// exercised by the `browserstack-accessibility-runner` executable (which this plugin builds
// and invokes). This keeps the security-sensitive logic in a directly unit-tested module.
@main
struct BrowserStackAccessibilityLintPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let runner = try context.tool(named: "browserstack-accessibility-runner")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: runner.path.string)
        process.arguments = ["--working-directory", context.package.directory.string] + arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        do {
            try process.run()
        } catch {
            forwardExit(code: 1, message: "Unable to launch BrowserStack accessibility runner: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        guard process.terminationReason == .exit else {
            forwardExit(code: 1, message: "BrowserStack accessibility runner terminated abnormally.")
        }
        if process.terminationStatus != 0 {
            // Propagate the runner's exit code without an extra message (it already reported).
            forwardExit(code: process.terminationStatus, message: "")
        }
    }
}

private func forwardExit(code: Int32, message: String) -> Never {
    if !message.isEmpty, let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
    exit(code)
}
