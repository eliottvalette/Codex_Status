import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    private var monitoringTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        monitoringTask = Task {
            await store.monitor()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitoringTask?.cancel()
    }
}

@main
struct CodexMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            DashboardView(store: appDelegate.store)
        } label: {
            Label(menuTitle, systemImage: "gauge.with.dots.needle.67percent")
        }
        .menuBarExtraStyle(.window)
    }

    private var menuTitle: String {
        guard let lowest = appDelegate.store.lowestRemaining else {
            return appDelegate.store.statuses.first?.profile.provider.displayName ?? "Codex"
        }
        return "\(lowest.provider.displayName) \(lowest.percent)%"
    }
}
