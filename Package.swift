// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AccessibilityDevTools",
    products: [
        .plugin(
            name: "a11y-scan",
            targets: ["a11y-scan"]
        )
    ],
    targets: [
        .plugin(
            name: "a11y-scan",
            capability: .command(
                intent: .custom(
                    verb: "scan",
                    description: "Scans your iOS project for accessibility issues"
                ),
                permissions: [
                    .allowNetworkConnections(
                        // scope: .all(ports: []),
                        scope: .all(),
                        reason: "Please allow network connection permission to authenticate and run accessibility rules."
                    ),
                    .writeToPackageDirectory(reason: "Please allow writing to package directory for logging.")
                ]
            )
        )
    ]
)
