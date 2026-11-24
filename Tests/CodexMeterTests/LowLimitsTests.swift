import Foundation
import Testing
@testable import CodexMeter

@Suite("Low limits and chat moves")
struct LowLimitsTests {
    private let now = Date(timeIntervalSince1970: 1_795_400_000)

    @Test("An account is low when any window, a model limit included, has 10% or less left")
    func findsLowAccounts() {
        let statuses = [
            status("claude", short: 50, weekly: 70, model: 92),
            status("claude-work", short: 90, weekly: 30),
            status("claude-new"),
        ]

        #expect(statuses.map(LowLimits.room(of:)) == [8, 10, nil])
        #expect(LowLimits.lowIDs(in: statuses) == ["claude", "claude-work"])
    }

    @Test("Names the account of the same provider with the most room")
    func namesTheRoomiestAccount() throws {
        let low = status("claude", weekly: 95)
        let statuses = [
            low,
            status("claude-work", weekly: 40),
            status("claude-personal", weekly: 92),
            status("codex", weekly: 0, provider: .codex),
        ]

        let alert = try #require(LowLimits.alert(for: low, in: statuses))
        #expect(alert.title == "claude has 5% left")
        #expect(alert.body == "Most room left: claude-work (60%).")
        #expect(LowLimits.alert(for: low, in: [low, status("claude-x", weekly: 92)])?.body
            == "No other Claude account has room left.")
    }

    @Test("Suggests the chats the roomiest account does not hold yet")
    func suggestsChatMoves() throws {
        let statuses = [status("claude", weekly: 97), status("claude-work", weekly: 20), status("claude-x", weekly: 50)]
        let chats = [
            chat("s1", on: "claude"),
            chat("s2", on: "claude", copiedTo: ["claude-work"]),
            chat("s3", on: "claude-x"),
        ]

        let move = try #require(LowLimits.chatMove(statuses: statuses, chats: chats))

        #expect(move.source.id == "claude")
        #expect(move.destination.id == "claude-work")
        #expect(move.sourceRoom == 3)
        #expect(move.chats.map(\.file.sessionID) == ["s1"])
        #expect(LowLimits.chatMove(statuses: statuses, chats: [chats[1], chats[2]]) == nil)
        #expect(LowLimits.chatMove(statuses: [statuses[0], status("claude-y", weekly: 95)], chats: chats) == nil)
    }

    private func status(
        _ id: String,
        short: Double? = nil,
        weekly: Double? = nil,
        model: Double? = nil,
        provider: ProfileProvider = .claude
    ) -> ProfileStatus {
        func window(_ used: Double?) -> QuotaWindow? {
            used.map { QuotaWindow(durationMinutes: 10_080, usedPercent: $0, resetsAt: nil, state: .active) }
        }
        let snapshot = weekly.map { _ in
            QuotaSnapshot(
                planType: nil,
                shortWindow: window(short),
                weeklyWindow: window(weekly),
                modelWindows: model.flatMap(window).map { [ModelQuotaWindow(name: "Fable", window: $0)] } ?? [],
                fetchedAt: now
            )
        }
        return ProfileStatus(
            profile: CodexProfile(id: id, displayName: id, homeURL: URL(fileURLWithPath: "/h/.\(id)"), provider: provider),
            snapshot: snapshot
        )
    }

    private func chat(_ sessionID: String, on profileID: String, copiedTo: Set<String> = []) -> RecentClaudeChat {
        RecentClaudeChat(
            profileID: profileID,
            file: .init(sessionID: sessionID, projectDirectoryName: "-p", url: URL(fileURLWithPath: "/p/\(sessionID).jsonl"), modifiedAt: now),
            title: sessionID,
            workingDirectory: nil,
            folderName: "p",
            lastMessageAt: now,
            copiedToProfileIDs: copiedTo
        )
    }
}

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
