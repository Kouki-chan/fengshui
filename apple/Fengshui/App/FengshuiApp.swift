import SwiftUI

@main
struct FengshuiApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    var body: some View {
        Text("Fengshui")
            .accessibilityIdentifier("root.title")
    }
}
