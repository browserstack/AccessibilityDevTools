import Foundation
import PackagePlugin

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(ucrt)
import ucrt
#endif

@main
struct BrowserStackAccessibilityLintPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        var extractor = ArgumentExtractor(arguments)
        let overrideDownloadURLString = extractor.extractOption(named: "download-url").last
        let forceDownloadFlag = extractor.extractFlag(named: "force-download") > 0
        let passthrough = extractor.remainingArguments

        let environment = ProcessInfo.processInfo.environment
        let forceDownload = forceDownloadFlag || isTruthy(environment["BROWSERSTACK_A11Y_CLI_FORCE_DOWNLOAD"])
        let overrideDownloadURL = try parseOverride(urlString: overrideDownloadURLString ?? environment["BROWSERSTACK_A11Y_CLI_DOWNLOAD_URL"])

    let cacheRoot = packageCacheRoot()
        let artifact = try await BrowserStackCLIArtifact.ensureLatestBinary(
            overrideURL: overrideDownloadURL,
            forceDownload: forceDownload,
            cacheRoot: cacheRoot
        )

        Diagnostics.remark("BrowserStackAccessibilityLint: Using CLI \(artifact.version) at \(artifact.executableURL.path)")

        let sanitizedArguments = sanitizeArguments(passthrough)
        let finalArguments = ["a11y"] + sanitizedArguments

        try await runCLI(
            executableURL: artifact.executableURL,
            arguments: finalArguments,
            workingDirectory: context.package.directory
        )
    }
}

private func isTruthy(_ value: String?) -> Bool {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else {
        return false
    }
    return ["1", "true", "yes"].contains(value)
}

private func packageCacheRoot() -> URL {
    // NOTE: Ignoring the package directory for caching; using a global user cache folder.
    // Order of precedence:
    // 1. XDG_CACHE_HOME if set
    // 2. HOME/.cache
    // 3. NSHomeDirectory()/.cache (fallback)
    let env = ProcessInfo.processInfo.environment
    let baseCache: URL = {
        if let xdg = env["XDG_CACHE_HOME"], !xdg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true)
        }
        if let home = env["HOME"], !home.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".cache", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".cache", isDirectory: true)
    }()

    let target = baseCache
        .appendingPathComponent("browserstack", isDirectory: true)
        .appendingPathComponent("devtools", isDirectory: true)
        .appendingPathComponent("spm-plugin", isDirectory: true)

    // Verify write access to cache directory (exit code 2 if not writable)
    let fm = FileManager.default
    do {
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        if !fm.isWritableFile(atPath: target.path) {
            forwardExit(code: 2, message: "Unable to access cache directory. Please add \"--allow-writing-to-directory ~/.cache/\" directive in the linter’s build phase command.")
        }
        let probe = target.appendingPathComponent(".write-probe-\(UUID().uuidString)")
        do {
            try "probe".data(using: .utf8)?.write(to: probe, options: [.atomic, .completeFileProtection])
            try? fm.removeItem(at: probe)
        } catch {
            forwardExit(code: 2, message: "Unable to access cache directory. Please include directive \"--allow-writing-to-directory ~/.cache/\" where you are invoking the Swift package")
        }
    } catch {
        forwardExit(code: 2, message: "Unable to access cache directory. Please include directive \"--allow-writing-to-directory ~/.cache/\" where you are invoking the Swift package")
    }

    return target
}

// MARK: - URL / Argument helpers

private func parseOverride(urlString: String?) throws -> URL? {
    guard let urlString = urlString, !urlString.isEmpty else {
        return nil
    }
    guard let url = URL(string: urlString), let scheme = url.scheme else {
        throw PluginError("Invalid download URL: \(urlString). Only HTTPS URLs are supported.")
    }
    guard scheme.lowercased() == "https" else {
        throw PluginError("Unsupported URL scheme '\(scheme)' in download URL. Only HTTPS is allowed.")
    }
    return url
}

private func sanitizeArguments(_ arguments: [String]) -> [String] {
    var result: [String] = []
    var skipNext = false
    var passthroughMode = false

    for argument in arguments {
        if passthroughMode {
            result.append(argument)
            continue
        }

        if skipNext {
            skipNext = false
            continue
        }

        if argument == "--" {
            passthroughMode = true
            result.append(argument)
            continue
        }

        if argument == "--output-format" || argument == "-o" {
            skipNext = true
            continue
        }

        if argument.hasPrefix("--output-format=") {
            continue
        }

        if argument.count > 2, argument.hasPrefix("-o"), argument != "-o" {
            // Handle short-form like "-oxcode".
            continue
        }

        result.append(argument)
    }

    return result
}

// MARK: - CLI artifact management

private struct BrowserStackCLIArtifact {
    let version: String
    let executableURL: URL

    static func ensureLatestBinary(overrideURL: URL?, forceDownload: Bool, cacheRoot: URL) async throws -> BrowserStackCLIArtifact {
        let downloader = BrowserStackCLIDownloader(overrideURL: overrideURL, forceDownload: forceDownload, cacheRoot: cacheRoot)
        return try await downloader.ensureArtifact()
    }
}

private struct BrowserStackCLIDownloader {
    let overrideURL: URL?
    let forceDownload: Bool
    let cacheRoot: URL

    private var fileManager: FileManager { .default }

    func ensureArtifact() async throws -> BrowserStackCLIArtifact {
        if let overrideURL {
            let info = try await resolveOverrideArtifact(from: overrideURL)
            return try await prepareArtifact(using: info)
        }

        let defaultURL = try defaultDownloadURL()
        let info = try await resolveRemoteArtifact(from: defaultURL)
        return try await prepareArtifact(using: info)
    }

    private func ensureCacheRootExists() throws -> URL {
        do {
            try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileWriteNoPermission.rawValue {
            throw PluginError("Permission denied writing to cache directory at \(cacheRoot.path). Rerun the plugin with --allow-writing-to-package-directory.")
        } catch {
            throw error
        }
        return cacheRoot
    }

    private func prepareArtifact(using info: ArtifactInfo) async throws -> BrowserStackCLIArtifact {
        let cacheRoot = try ensureCacheRootExists()
        let versionDirectory = cacheRoot.appendingPathComponent(info.version, isDirectory: true)
        let executableName = info.executableName
        let expectedExecutableURL = versionDirectory.appendingPathComponent(executableName, isDirectory: false)

        if !forceDownload, fileManager.isExecutableFile(atPath: expectedExecutableURL.path) {
            return BrowserStackCLIArtifact(version: info.version, executableURL: expectedExecutableURL)
        }

        // Extract into a unique staging directory and atomically publish it to the final
        // version directory (DEVA11Y-482). The previous check-delete-recreate sequence was
        // a TOCTOU: two concurrent builds sharing ~/.cache could both fall through the
        // isExecutableFile check, then one instance's removeItem/createDirectory would wipe
        // the other's in-progress extraction, corrupting the binary or leaving a partial
        // file that locateExecutable's fallback would happily run. Staging + rename means a
        // version directory only ever becomes visible fully-formed, and a loser of the
        // publish race reuses the winner's binary instead of clobbering it.
        let stagingDirectory = cacheRoot.appendingPathComponent(
            ".tmp.\(info.version).\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: stagingDirectory) }
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        Diagnostics.remark("BrowserStackAccessibilityLint: Downloading CLI \(info.version)...")

        #if os(Windows)
        let archiveURL = stagingDirectory.appendingPathComponent("browserstack-cli.zip")
        try await download(from: info.resolvedURL, to: archiveURL)
        Diagnostics.remark("BrowserStackAccessibilityLint: Extracting CLI \(info.version)...")
        try unzip(archive: archiveURL, into: stagingDirectory)
        try? fileManager.removeItem(at: archiveURL)
        #else
        try extractWithBsdtar(from: info.resolvedURL, into: stagingDirectory)
        #endif

        // Normalise the binary to the expected name *inside* the staging directory so the
        // published version directory is always structurally complete before it is renamed.
        // Compare full paths, not just the last component: locateExecutable recurses, so a
        // binary that already has the right name can still sit in a nested subdirectory
        // (e.g. a versioned tarball folder). Relocating it to the top-level staged path
        // unless it is already exactly there guarantees stagedExecutableURL exists before
        // we set permissions and publish.
        let locatedBinary = try locateExecutable(in: stagingDirectory, preferredName: executableName)
        let stagedExecutableURL = stagingDirectory.appendingPathComponent(executableName, isDirectory: false)
        if locatedBinary.standardizedFileURL != stagedExecutableURL.standardizedFileURL {
            if fileManager.fileExists(atPath: stagedExecutableURL.path) {
                try fileManager.removeItem(at: stagedExecutableURL)
            }
            try fileManager.moveItem(at: locatedBinary, to: stagedExecutableURL)
        }
        try ensureExecutablePermissions(at: stagedExecutableURL)

        try publishVersionDirectory(from: stagingDirectory, to: versionDirectory, expectedExecutableURL: expectedExecutableURL)
        return BrowserStackCLIArtifact(version: info.version, executableURL: expectedExecutableURL)
    }

    /// Publishes a fully-prepared staging directory to its final version directory. When
    /// the destination does not yet exist the move is a single atomic rename on the shared
    /// cache filesystem (staging and version dir are both children of cacheRoot), so
    /// concurrent builds never observe a half-formed version directory. When it already
    /// exists — another build won the race, or `forceDownload` is refreshing a stale copy —
    /// a valid published binary is reused, otherwise the stale directory is replaced and the
    /// rename retried once. The replace path is deliberate last-writer-wins and is *not*
    /// atomic; it tolerates a peer removing or republishing the directory concurrently
    /// rather than failing the build.
    private func publishVersionDirectory(from stagingDirectory: URL, to versionDirectory: URL, expectedExecutableURL: URL) throws {
        do {
            try fileManager.moveItem(at: stagingDirectory, to: versionDirectory)
            return
        } catch {
            if !forceDownload, fileManager.isExecutableFile(atPath: expectedExecutableURL.path) {
                // A concurrent build already published a valid binary; reuse it.
                return
            }
            // Stale/incomplete destination, or a forced refresh: replace and retry once.
            // removeItem is best-effort so a peer deleting the directory first does not
            // turn into an ENOENT crash mid-race.
            try? fileManager.removeItem(at: versionDirectory)
            do {
                try fileManager.moveItem(at: stagingDirectory, to: versionDirectory)
            } catch {
                // A peer republished the version directory between our remove and move. If
                // it now holds a valid binary, treat that as success rather than failing a
                // build that already has the artifact it needs.
                if fileManager.isExecutableFile(atPath: expectedExecutableURL.path) {
                    return
                }
                throw error
            }
        }
    }

#if !os(Windows)
    private func extractWithBsdtar(from url: URL, into directory: URL) throws {
        if url.isFileURL {
            try extractLocalArchive(at: url, into: directory)
        } else {
            try extractRemoteArchive(from: url, into: directory)
        }
    }

    private func extractRemoteArchive(from url: URL, into directory: URL) throws {
        let pipe = Pipe()

        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        curl.arguments = ["curl", "-fsSL", url.absoluteString]
        curl.standardOutput = pipe
        let curlError = Pipe()
        curl.standardError = curlError

        let bsdtar = Process()
        bsdtar.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        bsdtar.arguments = ["bsdtar", "-xpf", "-", "-C", directory.path]
        bsdtar.standardInput = pipe
        let tarError = Pipe()
        bsdtar.standardError = tarError

        do {
            try bsdtar.run()
        } catch {
            throw PluginError("Unable to launch bsdtar: \(error.localizedDescription)")
        }

        do {
            try curl.run()
        } catch {
            bsdtar.terminate()
            bsdtar.waitUntilExit()
            throw PluginError("Unable to launch curl: \(error.localizedDescription)")
        }

        curl.waitUntilExit()
        pipe.fileHandleForWriting.closeFile()
        bsdtar.waitUntilExit()

        if curl.terminationStatus != 0 {
            let message = String(data: curlError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            forwardExit(code: curl.terminationStatus, message: message)
        }

        guard bsdtar.terminationReason == .exit, bsdtar.terminationStatus == 0 else {
            let message = String(data: tarError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            forwardExit(code: bsdtar.terminationStatus, message: message.isEmpty ? "bsdtar failed to extract BrowserStack CLI." : message)
        }
    }

    private func extractLocalArchive(at archiveURL: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bsdtar", "-xpf", archiveURL.path, "-C", directory.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw PluginError("Failed to launch bsdtar: \(error.localizedDescription)")
        }

        if process.terminationReason != .exit || process.terminationStatus != 0 {
            // Fall back to copying the file directly if it's already an executable.
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if fileManager.isExecutableFile(atPath: archiveURL.path) {
                let destination = directory.appendingPathComponent(archiveURL.lastPathComponent)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: archiveURL, to: destination)
            } else {
                forwardExit(code: process.terminationStatus, message: message.isEmpty ? "bsdtar failed to extract BrowserStack CLI." : message)
            }
        }
    }
    #endif

    private func resolveOverrideArtifact(from url: URL) async throws -> ArtifactInfo {
        let resolvedURL: URL
        if url.isFileURL {
            resolvedURL = url
        } else {
            resolvedURL = try await followRedirects(for: url)
        }
        let version = extractVersion(from: resolvedURL) ?? "override"
        return ArtifactInfo(version: version, resolvedURL: resolvedURL, executableName: executableFileName())
    }

    private func resolveRemoteArtifact(from url: URL) async throws -> ArtifactInfo {
        let resolvedURL = try await followRedirects(for: url)
        guard let version = extractVersion(from: resolvedURL) else {
            throw PluginError("Unable to determine BrowserStack CLI version from \(resolvedURL.absoluteString)")
        }
        return ArtifactInfo(version: version, resolvedURL: resolvedURL, executableName: executableFileName())
    }

    private func defaultDownloadURL() throws -> URL {
        let os = try currentOSName()
        let arch = try currentArchName()
        guard let url = URL(string: "https://api.browserstack.com/sdk/v1/download_cli?os=\(os)&os_arch=\(arch)") else {
            throw PluginError("Failed to create download URL for \(os) \(arch).")
        }
        return url
    }

    private func currentOSName() throws -> String {
        #if os(macOS)
        return "macos"
        #elseif os(Linux)
        return isAlpineLinux() ? "alpine" : "linux"
        #elseif os(Windows)
        return "windows"
        #else
        throw PluginError("Unsupported operating system for BrowserStack CLI.")
        #endif
    }

    private func currentArchName() throws -> String {
        let machine = try hardwareIdentifier()
        switch machine.lowercased() {
        case "arm64", "aarch64":
            return "arm64"
        case "x86_64", "amd64":
            return "x64"
        default:
            throw PluginError("Unsupported architecture '\(machine)' for BrowserStack CLI.")
        }
    }


    private func followRedirects(for url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 30

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 405 || http.statusCode == 501 {
                    return try await followWithGet(for: url)
                }
                if let location = http.value(forHTTPHeaderField: "Location"),
                   let redirectURL = URL(string: location, relativeTo: url)?.absoluteURL {
                    return redirectURL
                }
            }
            if let finalURL = response.url {
                return finalURL
            }
        } catch let error as URLError where error.code == .badServerResponse || error.code == .unsupportedURL {
            return try await followWithGet(for: url)
        } catch let error as URLError where error.code == .cannotConnectToHost {
            throw PluginError("Network connection failed for \(url.absoluteString): \(error.localizedDescription)")
        } catch {
            throw error
        }

        throw PluginError("Failed to resolve redirect for \(url.absoluteString).")
    }

    private func followWithGet(for url: URL) async throws -> URL {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 60

        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           let location = http.value(forHTTPHeaderField: "Location"),
           let redirectURL = URL(string: location, relativeTo: url)?.absoluteURL {
            return redirectURL
        }
        guard let finalURL = response.url else {
            throw PluginError("Failed to resolve redirect for \(url.absoluteString).")
        }
        return finalURL
    }

    #if os(Windows)
    private func download(from url: URL, to destination: URL) async throws {
        if url.isFileURL {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: url, to: destination)
            return
        }

        let (tempURL, response) = try await URLSession.shared.download(from: url)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw PluginError("Failed to download BrowserStack CLI (HTTP \(httpResponse.statusCode)).")
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: tempURL, to: destination)
    }

    private func unzip(archive: URL, into destination: URL) throws {
        let powershell = Process()
        powershell.executableURL = URL(fileURLWithPath: "powershell")
        powershell.arguments = [
            "-NoProfile",
            "-Command",
            "Expand-Archive -LiteralPath \"\(archive.path)\" -DestinationPath \"\(destination.path)\" -Force"
        ]
        try run(process: powershell, errorDescription: "Unable to extract BrowserStack CLI archive.")
    }
#endif

    private func locateExecutable(in directory: URL, preferredName: String) throws -> URL {
        let preferredURL = directory.appendingPathComponent(preferredName, isDirectory: false)
        if fileManager.isExecutableFile(atPath: preferredURL.path) {
            return preferredURL
        }

        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
            options: [.skipsHiddenFiles]
        )

        var fallback: URL?

        while let element = enumerator?.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: element.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }

            if element.lastPathComponent == preferredName {
                return element
            }

            if fileManager.isExecutableFile(atPath: element.path) {
                return element
            }

            if fallback == nil {
                fallback = element
            }
        }

        if let fallback {
            return fallback
        }

        throw PluginError("Extracted archive does not contain a binary payload.")
    }

    private func ensureExecutablePermissions(at url: URL) throws {
        #if os(Windows)
        _ = url
        #else
        var attributes = [FileAttributeKey: Any]()
        attributes[.posixPermissions] = 0o755
        try fileManager.setAttributes(attributes, ofItemAtPath: url.path)
        #endif
    }

    private func run(process: Process, errorDescription: String) throws {
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        process.standardInput = FileHandle.standardInput
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit else {
            forwardExit(code: 1, message: errorDescription)
        }
        let status = process.terminationStatus
        guard status == 0 else {
            forwardExit(code: status, message: errorDescription)
        }
    }

    private func executableFileName() -> String {
        #if os(Windows)
        return "browserstack-cli.exe"
        #else
        return "browserstack-cli"
        #endif
    }
}

private struct ArtifactInfo {
    let version: String
    let resolvedURL: URL
    let executableName: String
}

// MARK: - System helpers

private func hardwareIdentifier() throws -> String {
    #if os(Windows)
    if let arch = ProcessInfo.processInfo.environment["PROCESSOR_ARCHITECTURE"]?.lowercased() {
        return arch
    }
    throw PluginError("Unable to detect CPU architecture.")
    #else
    var systemInfo = utsname()
    guard uname(&systemInfo) == 0 else {
        throw PluginError("uname() failed to determine CPU architecture.")
    }

    let capacity = MemoryLayout.size(ofValue: systemInfo.machine)
    let identifier = withUnsafePointer(to: &systemInfo.machine) { ptr -> String in
        return ptr.withMemoryRebound(to: CChar.self, capacity: capacity) {
            String(cString: $0)
        }
    }.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
    return identifier
    #endif
}

private func extractVersion(from url: URL) -> String? {
    let filename = url.deletingPathExtension().lastPathComponent
    if let range = filename.range(of: "-", options: .backwards) {
        let version = String(filename[range.upperBound...])
        if version.isEmpty { return nil }
        // Reject path traversal and non-semver characters
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-+"))
        guard version.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard !version.contains("..") else { return nil }
        return version
    }
    return nil
}

#if os(Linux)
private func isAlpineLinux() -> Bool {
    guard let contents = try? String(contentsOfFile: "/etc/os-release") else {
        return false
    }
    return contents.contains("ID=alpine")
}
#else
private func isAlpineLinux() -> Bool { false }
#endif

// MARK: - RBAC capability gating (ADR-0025)

// The headless CLI performs all WebSocket work — authentication, the
// connect/profile/handshake exchange (where the server ships the
// `capabilities` set + `effectiveRole`), and capability-gating of
// lint/scan/set-config. This SPM plugin is a thin wrapper that downloads
// and invokes that CLI as a subprocess, so it has no WebSocket message-
// decoding path and no Codable response model of its own to gate on:
// capability decisions are read by the CLI from the server's capability set,
// never re-encoded here. The one RBAC signal the wrapper sees is the CLI's
// exit code. `browserstack-cli` exits `PERMISSION_DENIED` (4) on a denied
// action (mirrors ExitCodes.PERMISSION_DENIED in the headless CLI; 3 is
// FUP_EXHAUSTED) and has already written the role-aware "Permission denied: …"
// detail to stderr. Pre-RBAC CLIs (rollout gated by
// LINTER_RBAC_ENFORCEMENT_ENABLED on the server) never emit this code, so the
// default path is unchanged.
private let browserstackCLIPermissionDeniedExitCode: Int32 = 4

// MARK: - CLI invocation

    private func runCLI(executableURL: URL, arguments: [String], workingDirectory: PackagePlugin.Path) async throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory.string, isDirectory: true)
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()

        guard process.terminationReason == .exit else {
            forwardExit(code: 1, message: "browserstack-cli terminated abnormally.")
        }

        let status = process.terminationStatus
        if status == browserstackCLIPermissionDeniedExitCode {
            // Surface the RBAC denial as a clear, role-aware outcome rather than
            // a generic failure. The CLI has already printed the specific
            // "Permission denied: …" reason to stderr; preserve its exit code so
            // CI and the SPM build phase can distinguish a denial from a lint
            // failure (exit 1) or a tooling error (exit 2).
            forwardExit(
                code: status,
                message: "BrowserStack Accessibility: your account's role is not permitted to run this action. See the \"Permission denied\" detail above, or contact your workspace admin to request access."
            )
        }
        guard status == 0 else {
            forwardExit(code: status, message: "")
        }
    }

// MARK: - Error

private struct PluginError: Error, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String { message }
}

private func forwardExit(code: Int32, message: String) -> Never {
    if !message.isEmpty, let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
    exit(code)
}
