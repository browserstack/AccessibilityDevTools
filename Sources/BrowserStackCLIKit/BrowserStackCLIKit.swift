import Foundation

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

// MARK: - Public orchestration entry
//
// All of the download / extract / run logic lives here in a plain library so it can be
// unit-tested directly (the SwiftPM command plugin that ships this cannot link a library
// target, so it delegates to the `browserstack-accessibility-runner` executable which calls
// into this function). Tests live in Sources/cli-kit-tests (`swift run cli-kit-tests`).

/// Runs the BrowserStack accessibility CLI: ensures the binary is downloaded/extracted into
/// the user cache (enforcing the DEVA11Y-484 size/entry guards) and executes it. Returns the
/// process exit code to propagate. Never calls `exit()` itself.
public func runBrowserStackCLI(
    workingDirectory: URL,
    arguments: [String],
    environment: [String: String],
    log: @escaping (String) -> Void
) async -> Int32 {
    do {
        let parsed = parseArguments(arguments)
        let forceDownload = parsed.forceDownload || isTruthy(environment["BROWSERSTACK_A11Y_CLI_FORCE_DOWNLOAD"])
        let overrideDownloadURL = try parseOverride(
            urlString: parsed.downloadURL ?? environment["BROWSERSTACK_A11Y_CLI_DOWNLOAD_URL"]
        )

        let cacheRoot = try packageCacheRoot(environment: environment)
        let downloader = BrowserStackCLIDownloader(
            overrideURL: overrideDownloadURL,
            forceDownload: forceDownload,
            cacheRoot: cacheRoot,
            log: log
        )
        let artifact = try await downloader.ensureArtifact()

        log("BrowserStackAccessibilityLint: Using CLI \(artifact.version) at \(artifact.executableURL.path)")

        let finalArguments = ["a11y"] + sanitizeArguments(parsed.passthrough)
        return try runCLI(executableURL: artifact.executableURL, arguments: finalArguments, workingDirectory: workingDirectory)
    } catch let exit as CLIExit {
        if !exit.message.isEmpty {
            FileHandle.standardError.write(Data((exit.message + "\n").utf8))
        }
        return exit.code
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        return 1
    }
}

// MARK: - Errors

/// Thrown to request process termination with a specific code/message. The executable maps
/// it to `exit()`; the library never exits the process itself.
public struct CLIExit: Error {
    public let code: Int32
    public let message: String
    public init(_ code: Int32, _ message: String) { self.code = code; self.message = message }
}

struct PluginError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

// MARK: - Argument parsing

public struct ParsedArguments {
    public var downloadURL: String?
    public var forceDownload: Bool
    public var passthrough: [String]
}

/// Minimal parser matching the plugin's previous ArgumentExtractor usage: pulls
/// `--download-url <value>` (last wins) and the `--force-download` flag, treating everything
/// else — including everything after `--` — as passthrough to the CLI.
public func parseArguments(_ arguments: [String]) -> ParsedArguments {
    var downloadURL: String?
    var forceDownload = false
    var passthrough: [String] = []
    var index = 0
    var afterSeparator = false

    while index < arguments.count {
        let arg = arguments[index]
        if afterSeparator {
            passthrough.append(arg)
            index += 1
            continue
        }
        switch arg {
        case "--":
            // Preserve the separator in passthrough so the CLI still receives it
            // (matches the previous ArgumentExtractor behavior).
            afterSeparator = true
            passthrough.append(arg)
        case "--force-download":
            forceDownload = true
        case "--download-url":
            if index + 1 < arguments.count {
                downloadURL = arguments[index + 1]
                index += 1
            }
        default:
            if arg.hasPrefix("--download-url=") {
                downloadURL = String(arg.dropFirst("--download-url=".count))
            } else {
                passthrough.append(arg)
            }
        }
        index += 1
    }
    return ParsedArguments(downloadURL: downloadURL, forceDownload: forceDownload, passthrough: passthrough)
}

func isTruthy(_ value: String?) -> Bool {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else {
        return false
    }
    return ["1", "true", "yes"].contains(value)
}

/// Only HTTPS download URLs are accepted (DEVA11Y-479). Returns nil when no override is set.
public func parseOverride(urlString: String?) throws -> URL? {
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

public func sanitizeArguments(_ arguments: [String]) -> [String] {
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
            continue
        }
        result.append(argument)
    }
    return result
}

// MARK: - Cache location

func packageCacheRoot(environment env: [String: String]) throws -> URL {
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

    let fm = FileManager.default
    do {
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        if !fm.isWritableFile(atPath: target.path) {
            throw CLIExit(2, "Unable to access cache directory. Please add \"--allow-writing-to-directory ~/.cache/\" directive in the linter’s build phase command.")
        }
        let probe = target.appendingPathComponent(".write-probe-\(UUID().uuidString)")
        do {
            try "probe".data(using: .utf8)?.write(to: probe, options: [.atomic, .completeFileProtection])
            try? fm.removeItem(at: probe)
        } catch {
            throw CLIExit(2, "Unable to access cache directory. Please include directive \"--allow-writing-to-directory ~/.cache/\" where you are invoking the Swift package")
        }
    } catch let exit as CLIExit {
        throw exit
    } catch {
        throw CLIExit(2, "Unable to access cache directory. Please include directive \"--allow-writing-to-directory ~/.cache/\" where you are invoking the Swift package")
    }

    return target
}

// MARK: - CLI artifact management

struct BrowserStackCLIArtifact {
    let version: String
    let executableURL: URL
}

struct ArtifactInfo {
    let version: String
    let resolvedURL: URL
    let executableName: String
}

public struct BrowserStackCLIDownloader {
    public let overrideURL: URL?
    public let forceDownload: Bool
    public let cacheRoot: URL
    public var log: (String) -> Void = { _ in }

    public init(overrideURL: URL?, forceDownload: Bool, cacheRoot: URL, log: @escaping (String) -> Void = { _ in }) {
        self.overrideURL = overrideURL
        self.forceDownload = forceDownload
        self.cacheRoot = cacheRoot
        self.log = log
    }

    private var fileManager: FileManager { .default }

    // Decompression-bomb guards (DEVA11Y-484). The CLI binary is a few tens of MB; these
    // ceilings leave generous headroom while bounding a malicious archive's footprint.
    public static let maxCompressedBytes = 100 * 1024 * 1024          // 100 MB on the wire
    public static let maxDecompressedBytes: Int64 = 200 * 1024 * 1024 // 200 MB on disk
    public static let maxArchiveEntries = 10_000

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

    func prepareArtifact(using info: ArtifactInfo) async throws -> BrowserStackCLIArtifact {
        let cacheRoot = try ensureCacheRootExists()
        let versionDirectory = cacheRoot.appendingPathComponent(info.version, isDirectory: true)
        let executableName = info.executableName
        let expectedExecutableURL = versionDirectory.appendingPathComponent(executableName, isDirectory: false)

        if !forceDownload, fileManager.isExecutableFile(atPath: expectedExecutableURL.path) {
            return BrowserStackCLIArtifact(version: info.version, executableURL: expectedExecutableURL)
        }

        if fileManager.fileExists(atPath: versionDirectory.path) {
            try fileManager.removeItem(at: versionDirectory)
        }
        try fileManager.createDirectory(at: versionDirectory, withIntermediateDirectories: true)

        log("BrowserStackAccessibilityLint: Downloading CLI \(info.version)...")

        #if os(Windows)
        let archiveURL = versionDirectory.appendingPathComponent("browserstack-cli.zip")
        try await download(from: info.resolvedURL, to: archiveURL)
        log("BrowserStackAccessibilityLint: Extracting CLI \(info.version)...")
        try unzip(archive: archiveURL, into: versionDirectory)
        try? fileManager.removeItem(at: archiveURL)
        #else
        try extractWithBsdtar(from: info.resolvedURL, into: versionDirectory)
        #endif

        // Platform-agnostic backstop (DEVA11Y-484). The bsdtar paths already abort mid-stream
        // via the watchdog; this also covers the Windows Expand-Archive path, which has no
        // streaming guard — it can't bound peak disk during extraction, but it rejects and
        // cleans up a bomb before the binary is ever used.
        if let reason = footprintExceeded(at: versionDirectory, maxBytes: Self.maxDecompressedBytes, maxEntries: Self.maxArchiveEntries) {
            try? fileManager.removeItem(at: versionDirectory)
            throw CLIExit(1, "BrowserStack CLI archive rejected: \(reason). Aborting to prevent disk exhaustion.")
        }

        let locatedBinary = try locateExecutable(in: versionDirectory, preferredName: executableName)
        let finalBinaryURL: URL
        if locatedBinary.lastPathComponent == executableName {
            finalBinaryURL = locatedBinary
        } else {
            finalBinaryURL = expectedExecutableURL
            if fileManager.fileExists(atPath: finalBinaryURL.path) {
                try fileManager.removeItem(at: finalBinaryURL)
            }
            try fileManager.moveItem(at: locatedBinary, to: finalBinaryURL)
        }

        try ensureExecutablePermissions(at: finalBinaryURL)
        return BrowserStackCLIArtifact(version: info.version, executableURL: finalBinaryURL)
    }

#if !os(Windows)
    public func extractWithBsdtar(from url: URL, into directory: URL) throws {
        if url.isFileURL {
            try extractLocalArchive(at: url, into: directory)
        } else {
            try extractRemoteArchive(from: url, into: directory)
        }
    }

    public func extractRemoteArchive(from url: URL, into directory: URL) throws {
        let pipe = Pipe()

        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // --max-filesize caps the *compressed* download as a coarse first line of defense
        // against a malicious endpoint streaming an unbounded body.
        curl.arguments = ["curl", "-fsSL", "--max-filesize", String(Self.maxCompressedBytes), url.absoluteString]
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

        // See the DEVA11Y-484 EXTRACTION GUARD block below for the rationale.
        let limitState = startExtractionWatchdog(on: bsdtar, directory: directory, maxBytes: Self.maxDecompressedBytes, maxEntries: Self.maxArchiveEntries)

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

        // Catch a bomb that completed within a single watchdog poll interval (fast disk).
        if !limitState.exceeded, let reason = footprintExceeded(at: directory, maxBytes: Self.maxDecompressedBytes, maxEntries: Self.maxArchiveEntries) {
            limitState.markExceeded(reason)
        }
        if limitState.exceeded {
            try? fileManager.removeItem(at: directory)
            throw CLIExit(1, "BrowserStack CLI archive rejected: \(limitState.reason). Aborting to prevent disk exhaustion.")
        }

        if curl.terminationStatus != 0 {
            let message = String(data: curlError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CLIExit(curl.terminationStatus, message)
        }

        guard bsdtar.terminationReason == .exit, bsdtar.terminationStatus == 0 else {
            let message = String(data: tarError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CLIExit(bsdtar.terminationStatus, message.isEmpty ? "bsdtar failed to extract BrowserStack CLI." : message)
        }
    }

    public func extractLocalArchive(at archiveURL: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bsdtar", "-xpf", archiveURL.path, "-C", directory.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe

        let limitState: ExtractionLimitState
        do {
            try process.run()
            // Decompressed-size/entry guard (DEVA11Y-484): same rationale as the remote path.
            limitState = startExtractionWatchdog(on: process, directory: directory, maxBytes: Self.maxDecompressedBytes, maxEntries: Self.maxArchiveEntries)
            process.waitUntilExit()
        } catch {
            throw PluginError("Failed to launch bsdtar: \(error.localizedDescription)")
        }

        // Catch a bomb that completed within a single watchdog poll interval (fast disk).
        if !limitState.exceeded, let reason = footprintExceeded(at: directory, maxBytes: Self.maxDecompressedBytes, maxEntries: Self.maxArchiveEntries) {
            limitState.markExceeded(reason)
        }
        if limitState.exceeded {
            try? fileManager.removeItem(at: directory)
            throw CLIExit(1, "BrowserStack CLI archive rejected: \(limitState.reason). Aborting to prevent disk exhaustion.")
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
                throw CLIExit(process.terminationStatus, message.isEmpty ? "bsdtar failed to extract BrowserStack CLI." : message)
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

    public func locateExecutable(in directory: URL, preferredName: String) throws -> URL {
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
        var scanned = 0

        while let element = enumerator?.nextObject() as? URL {
            scanned += 1
            if scanned > Self.maxArchiveEntries {
                // Bound enumeration so an archive packed with millions of entries can't turn
                // locateExecutable into a CPU/IO drain (DEVA11Y-484).
                throw PluginError("Extracted archive contains more than \(Self.maxArchiveEntries) entries; refusing to continue.")
            }

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
            throw CLIExit(1, errorDescription)
        }
        let status = process.terminationStatus
        guard status == 0 else {
            throw CLIExit(status, errorDescription)
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

// MARK: - System helpers

func hardwareIdentifier() throws -> String {
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

public func extractVersion(from url: URL) -> String? {
    let filename = url.deletingPathExtension().lastPathComponent
    if let range = filename.range(of: "-", options: .backwards) {
        let version = filename[range.upperBound...]
        return version.isEmpty ? nil : String(version)
    }
    return nil
}

#if os(Linux)
func isAlpineLinux() -> Bool {
    guard let contents = try? String(contentsOfFile: "/etc/os-release") else {
        return false
    }
    return contents.contains("ID=alpine")
}
#else
func isAlpineLinux() -> Bool { false }
#endif

// MARK: - CLI invocation

func runCLI(executableURL: URL, arguments: [String], workingDirectory: URL) throws -> Int32 {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError

    try process.run()
    process.waitUntilExit()

    guard process.terminationReason == .exit else {
        throw CLIExit(1, "browserstack-cli terminated abnormally.")
    }
    return process.terminationStatus
}

// === DEVA11Y-484 EXTRACTION GUARD ===
// Unit-tested directly in Sources/cli-kit-tests against real bsdtar + crafted bombs.
//
// Rationale: bsdtar writes decompressed bytes straight to disk, so a cap on the
// curl→bsdtar pipe would only bound the *compressed* size — useless against a
// decompression bomb. Instead we poll the destination directory while bsdtar runs
// and terminate it if the decompressed footprint crosses a byte OR entry ceiling
// (the entry ceiling stops a "millions of tiny files" bomb that stays small on disk).

/// Thread-safe flag shared between the extraction watchdog and the main flow.
public final class ExtractionLimitState {
    private let lock = NSLock()
    private var didExceed = false
    private var why = ""

    public func markExceeded(_ reason: String) {
        lock.lock()
        if !didExceed {
            didExceed = true
            why = reason
        }
        lock.unlock()
    }

    public var exceeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didExceed
    }

    public var reason: String {
        lock.lock()
        defer { lock.unlock() }
        return why
    }
}

/// Total bytes and entry count of all regular files under `url`.
public func extractionFootprint(at url: URL) -> (bytes: Int64, entries: Int) {
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
public func footprintExceeded(at directory: URL, maxBytes: Int64, maxEntries: Int) -> String? {
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
public func startExtractionWatchdog(on process: Process, directory: URL, maxBytes: Int64, maxEntries: Int) -> ExtractionLimitState {
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
