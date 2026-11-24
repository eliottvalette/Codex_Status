import AppKit
import Foundation
import ServiceManagement
import UserNotifications

/// What the store asks of the Mac outside the app. Tests record these instead.
@MainActor
protocol DesktopActions {
    func notify(title: String, body: String)
    func copyToClipboard(_ text: String)
    /// Opens Terminal with Claude Code running in the account, where the user signs in.
    func openSignIn(for profile: CodexProfile)
}

struct Desktop: DesktopActions {
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

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func openSignIn(for profile: CodexProfile) {
        // A .command file opens in Terminal without asking for any permission.
        let script = FileManager.default.temporaryDirectory
            .appending(path: "CodexMeter-sign-in-\(profile.id).command")
        let executable = (try? ClaudeCLI().resolvedExecutable().path) ?? "claude"
        let configuration = ClaudeProfiles.usesDefaultDirectory(profile)
            ? "unset CLAUDE_CONFIG_DIR"
            : "export CLAUDE_CONFIG_DIR=\(ClaudeProfiles.shellWord(profile.homeURL.path))"
        // The account name is the user's own text, so it is quoted like everything else.
        let greeting = "Signing in to \(profile.displayName). Run /login if Claude Code does not ask."
        let text = """
            #!/bin/zsh
            \(configuration)
            echo \(ClaudeProfiles.shellWord(greeting))
            exec \(ClaudeProfiles.shellWord(executable))

            """
        do {
            try Data(text.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            NSSound.beep()
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
