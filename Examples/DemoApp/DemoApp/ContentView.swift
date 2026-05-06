import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text(DemoGreeting.message)
                .font(.headline)
            Text("XCSteward fixture")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

enum DemoGreeting {
    static let message = "Hello from XCSteward"
}

#Preview {
    ContentView()
}
