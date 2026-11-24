import Foundation
import ServiceManagement
import UserNotifications

@MainActor
protocol LowLimitNotifier {
    func notify(title: String, body: String)
}

/// Posts a macOS notification, asking for permission the first time.
struct SystemNotifier: LowLimitNotifier {
    func notify(title: String, body: String) {
        // Notifications need an app bundle; `swift test` and `swift run` have none.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// Starts the app at login through macOS's login items.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns a message for the user when macOS refuses or needs approval.
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            return "Open at login: \(error.localizedDescription)"
        }
        if enabled, SMAppService.mainApp.status == .requiresApproval {
            return "Allow CodexMeter in System Settings > General > Login Items."
        }
        return nil
    }
}
