// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AccessibilityDevTools",
    // Matches the async URLSession APIs the downloader already used as a plugin.
    platforms: [.macOS(.v12)],
    products: [
        .plugin(
            name: "a11y-scan",
            targets: ["a11y-scan"]
        )
    ],
    targets: [
        // All download / extract / guard / run logic. Pure Foundation so it can be unit-tested.
        .target(name: "BrowserStackCLIKit"),

        // Thin executable the command plugin invokes (plugins can't link library targets).
        .executableTarget(
            name: "browserstack-accessibility-runner",
            dependencies: ["BrowserStackCLIKit"]
        ),

        // Executable test harness (not XCTest, so it runs under Command Line Tools as well as
        // Xcode/CI). Exercises the real BrowserStackCLIKit code against live bsdtar + bombs.
        // Run with: swift run cli-kit-tests
        .executableTarget(
            name: "cli-kit-tests",
            dependencies: ["BrowserStackCLIKit"]
        ),

        .plugin(
            name: "a11y-scan",
            capability: .command(
                intent: .custom(
                    verb: "scan",
                    description: "Scans your iOS project for accessibility issues"
                ),
                permissions: [
                    .allowNetworkConnections(
                        scope: .all(ports: [80, 443]),
                        reason: "Please allow network connection permission to authenticate and run accessibility rules."
                    ),
                    .writeToPackageDirectory(reason: "Please allow writing to package directory for logging.")
                ]
            ),
            dependencies: ["browserstack-accessibility-runner"]
        )
    ]
)
