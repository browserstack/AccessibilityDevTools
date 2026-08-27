// swift-tools-version: 5.9
import PackageDescription

// Integration-test harness: a real SwiftPM package that consumes the
// `a11y-scan` command plugin from this repository.
//
// The dependency is a *path* dependency on the repo root (`../..`) so the
// harness always exercises the local plugin sources rather than a published
// tag. When this lands on `main`, `../..` resolves to the AccessibilityDevTools
// package at the repository root.
//
// NOTE: `a11y-scan` is a *command* plugin (manually invoked), not a build-tool
// plugin. It must therefore NOT be attached to a target's `plugins:` array —
// doing so makes SwiftPM treat it as a build tool and breaks `swift build`.
// Declaring the package dependency is enough to make the command plugin
// available; it is invoked explicitly via `scripts/run-a11y-scan.sh`
// (`swift package plugin ... scan`).
let package = Package(
    name: "A11yScanSPMConsumer",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    dependencies: [
        .package(name: "AccessibilityDevTools", path: "../.."),
    ],
    targets: [
        // Sample sources containing intentional accessibility issues for the
        // scanner to flag.
        .target(name: "A11yDemoLib"),
        .testTarget(
            name: "A11yDemoLibTests",
            dependencies: ["A11yDemoLib"]
        ),
    ]
)
