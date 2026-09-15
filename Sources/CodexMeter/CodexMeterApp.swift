import SwiftUI

@main
struct CodexMeterApp: App {
    @State private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            DashboardView(store: store)
                .task {
                    await store.monitor()
                }
        } label: {
            Label(menuTitle, systemImage: "gauge.with.dots.needle.67percent")
        }
        .menuBarExtraStyle(.window)
    }

    private var menuTitle: String {
        guard let remaining = store.lowestRemainingPercent else {
            return "Codex"
        }
        return "Codex \(remaining)%"
    }
}
