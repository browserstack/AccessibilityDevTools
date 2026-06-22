import XCTest

@testable import A11yScanDemoApp

final class A11yScanDemoAppTests: XCTestCase {
    /// Sanity check that the app target builds and the test bundle links against
    /// it. The accessibility scan itself runs as the app target's pre-compile
    /// build phase (see project.yml), so a successful `xcodebuild test` means the
    /// scan ran during the build.
    func testContentViewExists() {
        _ = ContentView()
    }
}
