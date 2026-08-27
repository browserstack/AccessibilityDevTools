#if canImport(SwiftUI)
import SwiftUI

/// Sample SwiftUI views that deliberately contain accessibility issues so the
/// `a11y-scan` plugin has something to report when run against this package.
///
/// These are NOT examples of good practice — each view documents the WCAG-style
/// issue the BrowserStack rule engine is expected to flag.
@available(iOS 15, macOS 12, *)
struct SampleContentView: View {
    @State private var isOn = false

    var body: some View {
        VStack(spacing: 16) {
            // Issue: image conveys meaning but has no accessibility label and is
            // not marked decorative.
            Image(systemName: "trash")

            // Issue: icon-only button with no accessible label — screen readers
            // announce nothing actionable.
            Button(action: deleteItem) {
                Image(systemName: "plus.circle")
            }

            // Issue: toggle with no label describing what it controls.
            Toggle("", isOn: $isOn)

            // Issue: empty text element provides no information.
            Text("")
        }
        .padding()
    }

    private func deleteItem() {}
}
#endif

/// Public marker so the test target has a concrete symbol to import and assert
/// against without depending on SwiftUI being available on the host.
public enum A11yDemoLib {
    public static let name = "A11yScanSPMConsumer"
}
