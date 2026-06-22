// swift-tools-version: 5.9
import PackageDescription

// Scan driver for the Xcode-app harness.
//
// Pure Xcode app projects have no Package.swift, so the official BrowserStack
// integration synthesizes a minimal one to host the `a11y-scan` command plugin
// (see scripts/{bash,zsh,fish}/spm.sh in this repo). We check that minimal
// package in directly so the scan can run over the app's `Sources/` without any
// network self-update step.
//
// `targets: []` is intentional — the scanner selects files by `--include`
// globs, not by SwiftPM target membership, so no target wiring is required.
let package = Package(
    name: "A11yScanDemoAppScan",
    dependencies: [
        .package(name: "AccessibilityDevTools", path: "../.."),
    ],
    targets: []
)
