import SwiftUI

/// Demo screen with intentional accessibility issues for the `a11y-scan` plugin
/// to report during the build's pre-compile scan phase. Each control documents
/// the issue the BrowserStack rule engine is expected to flag.
struct ContentView: View {
    @State private var notificationsEnabled = false

    var body: some View {
        VStack(spacing: 20) {
            // Issue: meaningful image with no accessibility label.
            Image(systemName: "bell.fill")
                .font(.largeTitle)

            // Issue: icon-only button with no accessible label.
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
            }

            // Issue: toggle with no descriptive label.
            Toggle("", isOn: $notificationsEnabled)
                .labelsHidden()

            // Issue: empty text element conveys nothing to assistive tech.
            Text("")
        }
        .padding()
    }

    private func refresh() {}
}

#Preview {
    ContentView()
}
