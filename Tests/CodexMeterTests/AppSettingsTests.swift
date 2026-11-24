import Foundation
import Testing
@testable import CodexMeter

@Suite("Settings")
@MainActor
struct AppSettingsTests {
    @Test("Starts from the defaults and keeps each change")
    func persistsChoices() throws {
        let name = "CodexMeterTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.startsIdleClaudeWindows)
        #expect(settings.refreshMinutes == 2)
        #expect(settings.notifiesLowLimits == false)
        #expect(settings.chatMoves == .suggest)
        #expect(settings.accountNames.isEmpty)

        settings.startsIdleClaudeWindows = false
        settings.refreshMinutes = 5
        settings.notifiesLowLimits = true
        settings.chatMoves = .automatic
        settings.accountNames = ["claude-test": "Side project"]
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.startsIdleClaudeWindows == false)
        #expect(reloaded.refreshMinutes == 5)
        #expect(reloaded.notifiesLowLimits)
        #expect(reloaded.chatMoves == .automatic)
        #expect(reloaded.accountNames == ["claude-test": "Side project"])

        defaults.set(7, forKey: "refreshMinutes")
        #expect(AppSettings(defaults: defaults).refreshMinutes == 2, "an interval the menu does not offer falls back")
    }
}
