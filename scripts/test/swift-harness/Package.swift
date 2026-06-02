// swift-tools-version: 5.9
import PackageDescription

// Standalone harness that exercises the real DEVA11Y-484 extraction guard against
// live curl/bsdtar processes. The guard logic in Sources/ExtractionHarness/Guard.swift
// is a verbatim mirror of the block in the SPM plugin (SwiftPM command plugins cannot be
// imported by a test target, so we mirror + drift-check instead). See ../check_drift.sh.
let package = Package(
    name: "ExtractionHarness",
    targets: [
        .executableTarget(name: "ExtractionHarness")
    ]
)
