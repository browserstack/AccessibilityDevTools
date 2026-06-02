import Foundation
import BrowserStackCLIKit

// Thin executable wrapper around BrowserStackCLIKit. The SwiftPM command plugin invokes this
// (command plugins can't link a library target), passing `--working-directory <dir>` followed
// by the user's arguments. All real work — and all the tested logic — lives in the library.

var arguments = Array(CommandLine.arguments.dropFirst())
var workingDirectory = FileManager.default.currentDirectoryPath

if let idx = arguments.firstIndex(of: "--working-directory"), idx + 1 < arguments.count {
    workingDirectory = arguments[idx + 1]
    arguments.removeSubrange(idx...(idx + 1))
}

let exitCode = await runBrowserStackCLI(
    workingDirectory: URL(fileURLWithPath: workingDirectory, isDirectory: true),
    arguments: arguments,
    environment: ProcessInfo.processInfo.environment,
    log: { message in FileHandle.standardError.write(Data((message + "\n").utf8)) }
)

exit(exitCode)
