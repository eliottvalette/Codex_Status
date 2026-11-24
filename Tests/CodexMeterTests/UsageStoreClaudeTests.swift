import Foundation
import Testing
@testable import CodexMeter

@Suite("Usage store with Claude profiles")
@MainActor
final class UsageStoreClaudeTests {
    private let recorder = Recorder()
    private let defaultsName = "CodexMeterTests-\(UUID().uuidString)"
    private lazy var settings = AppSettings(defaults: UserDefaults(suiteName: defaultsName)!)

    deinit {
        UserDefaults().removePersistentDomain(forName: defaultsName)
    }

    /// Stands in for Claude Code: the five-hour window is idle until an activation request
    /// creates the `window` file, unless `stuck` exists. A `weekly` file sets the weekly
    /// utilization, and a `limited` file answers without limits.
    private let fakeClaude = """
        calls="$CLAUDE_CONFIG_DIR/calls"
        case " $* " in
          *" --model haiku "*)
            echo activation >> "$calls"
            [ -f "$CLAUDE_CONFIG_DIR/stuck" ] || echo started > "$CLAUDE_CONFIG_DIR/window"
            echo '{"type":"result","subtype":"success","is_error":false,"result":"OK"}'
            ;;
          *)
            read request
            echo usage >> "$calls"
            if [ -f "$CLAUDE_CONFIG_DIR/limited" ]; then
              echo '{"type":"control_response","response":{"subtype":"success","request_id":"codex-meter-usage","response":{"rate_limits_available":true,"rate_limits":null}}}'
              exit 0
            fi
            if [ -f "$CLAUDE_CONFIG_DIR/window" ]; then used=1; reset='"2099-01-01T00:00:00Z"'; else used=0; reset=null; fi
            weekly=$(cat "$CLAUDE_CONFIG_DIR/weekly" 2>/dev/null || echo 20)
            echo "{\\"type\\":\\"control_response\\",\\"response\\":{\\"subtype\\":\\"success\\",\\"request_id\\":\\"codex-meter-usage\\",\\"response\\":{\\"subscription_type\\":\\"max\\",\\"rate_limits_available\\":true,\\"rate_limits\\":{\\"five_hour\\":{\\"utilization\\":$used,\\"resets_at\\":$reset},\\"seven_day\\":{\\"utilization\\":$weekly,\\"resets_at\\":\\"2099-01-01T00:00:00Z\\"}}}}}"
            ;;
        esac
        """

    @Test("Reads Claude quotas and starts an idle window once")
    func refreshesAndActivates() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let work = try profile("claude-work", in: home)
        let store = try makeStore([work], home: home)

        await store.refresh()

        let status = try #require(store.statuses.first)
        #expect(status.errorMessage == nil)
        #expect(status.snapshot?.planType == "max")
        #expect(status.snapshot?.shortWindow?.state == .active)
        #expect(status.snapshot?.shortWindow?.usedPercent == 1)
        #expect(status.snapshot?.weeklyWindow?.remainingPercent == 80)
        #expect(store.lowestRemaining == LowestRemainingQuota(provider: .claude, percent: 80))
        #expect(try calls(work) == ["usage", "activation", "usage"])

        await store.refresh()
        #expect(try calls(work) == ["usage", "activation", "usage", "usage"])
        #expect(store.statuses[0].snapshot?.shortWindow?.state == .active)
    }

    @Test("Does not repeat the activation request while a window stays idle")
    func respectsActivationCooldown() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let work = try profile("claude-work", in: home)
        try Data().write(to: work.homeURL.appending(path: "stuck"))
        let store = try makeStore([work], home: home)

        await store.refresh()
        await store.refresh()
        await store.refresh()

        #expect(try calls(work).filter { $0 == "activation" }.count == 1)
        #expect(store.statuses[0].snapshot?.shortWindow?.state == .dormant)
        #expect(store.statuses[0].snapshot?.shortWindow?.remainingPercent == 100)
    }

    @Test("Keeps the last reading while the usage service is limiting reads")
    func keepsReadingWhenUsageIsUnavailable() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let work = try profile("claude-work", in: home)
        let store = try makeStore([work], home: home)
        await store.refresh()
        let reading = try #require(store.statuses[0].snapshot)

        try Data().write(to: work.homeURL.appending(path: "limited"))
        await store.refresh()

        #expect(store.statuses[0].snapshot == reading)
        #expect(store.statuses[0].isStale)
        #expect(store.statuses[0].errorMessage == ClaudeUsageError.usageTemporarilyUnavailable.errorDescription)

        // Reads pause for a while, so the next refresh does not ask again.
        let usageReads = try calls(work).filter { $0 == "usage" }.count
        await store.refresh()
        #expect(try calls(work).filter { $0 == "usage" }.count == usageReads)
        #expect(store.statuses[0].snapshot == reading)
    }

    @Test("Starts no idle window when the setting is off")
    func respectsActivationSetting() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let work = try profile("claude-work", in: home)
        settings.startsIdleClaudeWindows = false
        let store = try makeStore([work], home: home)

        await store.refresh()

        #expect(try calls(work) == ["usage"])
        #expect(store.statuses[0].snapshot?.shortWindow?.state == .dormant)
    }

    @Test("Shows why a Claude profile has no quota")
    func reportsUnavailableProfile() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let work = try profile("claude-work", in: home)
        let store = UsageStore(
            profiles: [work],
            claudeClient: ClaudeUsageClient(cli: ClaudeCLI(executableURL: home.appending(path: "absent"), home: home)),
            settings: settings,
            notifier: recorder
        )

        await store.refresh()

        #expect(store.statuses[0].snapshot == nil)
        #expect(store.statuses[0].errorMessage?.hasPrefix("Claude Code executable not found") == true)
        #expect(store.statuses[0].isRefreshing == false)
        #expect(store.lowestRemaining == nil)
    }

    @Test("Copies conversations between Claude accounts and refuses a Codex destination")
    func transfersBetweenClaudeProfiles() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let work = try profile("claude-work", in: home)
        let personal = try profile("claude-personal", in: home)
        let codex = CodexProfile(id: "codex", displayName: "codex", homeURL: home.appending(path: ".codex"))
        let transcript = Data(#"{"type":"user","timestamp":"2026-11-20T10:00:00Z","message":{"role":"user","content":"hello"}}"#.utf8) + Data("\n".utf8)
        let sourceURL = work.homeURL.appending(path: "projects/-Users-me-app/s1.jsonl")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try transcript.write(to: sourceURL)
        let store = try makeStore([codex, work, personal], home: home)

        await store.handleProfileTap(work.id)
        #expect(store.transferSourceID == work.id)

        await store.handleProfileTap(codex.id)
        #expect(store.transferFeedback?.style == .failure)
        #expect(store.transferSourceID == work.id, "the source stays selected for another destination")
        #expect(store.isTransferring == false)

        await store.handleProfileTap(personal.id)
        #expect(store.transferFeedback == TransferFeedback(
            style: .success, message: "✓ 1 conversation copied to claude-personal"
        ))
        #expect(store.transferSourceID == nil)
        #expect(try Data(contentsOf: personal.homeURL.appending(path: "projects/-Users-me-app/s1.jsonl")) == transcript)
    }

    @Test("Lists recent chats once two accounts exist and copies one from the list")
    func copiesFromRecentChats() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let work = try profile("claude-work", in: home)
        let personal = try profile("claude-personal", in: home)
        let transcript = Data(#"{"type":"user","timestamp":"2026-11-20T10:00:00Z","message":{"role":"user","content":"hello"},"cwd":"/Users/me/app"}"#.utf8) + Data("\n".utf8)
        let sourceURL = work.homeURL.appending(path: "projects/-Users-me-app/s1.jsonl")
        try FileManager.default.createDirectory(
            at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try transcript.write(to: sourceURL)

        let single = try makeStore([work], home: home)
        await single.refresh()
        #expect(single.showsRecentChats == false)
        #expect(single.recentChats.isEmpty)

        let store = try makeStore([work, personal], home: home)
        await store.refresh()
        let chat = try #require(store.recentChats.first)
        #expect(store.recentChats.count == 1)
        #expect(chat.profileID == work.id)
        #expect(chat.title == "hello")
        #expect(chat.folderName == "app")

        await store.copyChat(chat, to: personal.id)

        #expect(store.transferFeedback == TransferFeedback(
            style: .success, message: "✓ “hello” copied to claude-personal · resume command copied"
        ))
        #expect(recorder.clipboard == [chat.resumeCommand(in: personal)])
        #expect(store.isTransferring == false)
        #expect(try Data(contentsOf: personal.homeURL.appending(path: "projects/-Users-me-app/s1.jsonl")) == transcript)
        #expect(try Data(contentsOf: sourceURL) == transcript)
        #expect(store.recentChats.map(\.profileID) == [work.id], "the copy is the same conversation")
        #expect(store.recentChats.first?.copiedToProfileIDs == [personal.id])

        await store.copyChat(chat, to: personal.id)
        #expect(store.transferFeedback == TransferFeedback(
            style: .success, message: "✓ “hello” already on claude-personal · resume command copied"
        ))

        store.copyResumeCommand(for: chat)
        #expect(recorder.clipboard.last == chat.resumeCommand(in: work))
    }

    @Test("Announces a low account once and suggests moving its chats")
    func suggestsMovingChats() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let work = try profile("claude-work", in: home)
        let personal = try profile("claude-personal", in: home)
        try Data("95".utf8).write(to: work.homeURL.appending(path: "weekly"))
        try writeChat(to: work)
        settings.notifiesLowLimits = true
        let store = try makeStore([work, personal], home: home)

        await store.refresh()
        await store.refresh()

        #expect(recorder.notifications.map(\.title) == ["claude-work has 5% left"])
        #expect(recorder.notifications.map(\.body) == ["Most room left: claude-personal (80%)."])
        let move = try #require(store.chatMove)
        #expect(move.source == work && move.destination == personal && move.sourceRoom == 5)
        #expect(move.chats.map(\.file.sessionID) == ["s1"])
        #expect(FileManager.default.fileExists(atPath: personal.homeURL.appending(path: "projects").path) == false)

        settings.chatMoves = .off
        #expect(store.chatMove == nil)
    }

    @Test("Moves the chats of a low account on its own when the setting asks")
    func movesChatsAutomatically() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let work = try profile("claude-work", in: home)
        let personal = try profile("claude-personal", in: home)
        try Data("95".utf8).write(to: work.homeURL.appending(path: "weekly"))
        let transcript = try writeChat(to: work)
        settings.chatMoves = .automatic
        let store = try makeStore([work, personal], home: home)

        await store.refresh()

        #expect(try Data(contentsOf: personal.homeURL.appending(path: "projects/-Users-me-app/s1.jsonl")) == transcript)
        #expect(store.transferFeedback?.message == "✓ 1 chat from claude-work copied to claude-personal")
        #expect(store.chatMove == nil, "nothing is left to move")
        #expect(recorder.notifications.isEmpty, "notifications are off by default")
    }

    @Test("Leaves Claude accounts out of the Codex conversation sync")
    func syncsCodexAccountsOnly() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let work = try profile("claude-work", in: home)
        let personal = try profile("claude-personal", in: home)
        let codex = CodexProfile(id: "codex", displayName: "codex", homeURL: home.appending(path: ".codex"))
        let before = try FileManager.default.contentsOfDirectory(atPath: work.homeURL.path)

        let claudeOnly = try makeStore([work, personal], home: home)
        #expect(claudeOnly.canSyncConversations == false)
        await claudeOnly.syncRecentConversations()
        #expect(claudeOnly.transferFeedback == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.homeURL.path) == before)

        let mixed = try makeStore([codex, work, personal], home: home)
        #expect(mixed.codexProfiles.map(\.id) == ["codex"])
        #expect(mixed.canSyncConversations == false)
    }

    private func makeStore(_ profiles: [CodexProfile], home: URL) throws -> UsageStore {
        let executable = home.appending(path: "claude")
        try Data("#!/bin/sh\n\(fakeClaude)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let recorder = recorder
        return UsageStore(
            profiles: profiles,
            claudeClient: ClaudeUsageClient(cli: ClaudeCLI(executableURL: executable, home: home)),
            settings: settings,
            notifier: recorder,
            writeToClipboard: { recorder.clipboard.append($0) }
        )
    }

    @discardableResult
    private func writeChat(to profile: CodexProfile) throws -> Data {
        let transcript = Data(#"{"type":"user","timestamp":"2026-11-20T10:00:00Z","message":{"role":"user","content":"hello"},"cwd":"/Users/me/app"}"#.utf8) + Data("\n".utf8)
        let url = profile.homeURL.appending(path: "projects/-Users-me-app/s1.jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try transcript.write(to: url)
        return transcript
    }

    private func profile(_ name: String, in home: URL) throws -> CodexProfile {
        let url = home.appending(path: ".\(name)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return CodexProfile(id: name, displayName: name, homeURL: url, provider: .claude)
    }

    private func calls(_ profile: CodexProfile) throws -> [String] {
        try String(contentsOf: profile.homeURL.appending(path: "calls"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    /// Keeps what the store would put on the clipboard and in notifications.
    @MainActor
    private final class Recorder: LowLimitNotifier {
        var clipboard: [String] = []
        var notifications: [(title: String, body: String)] = []

        func notify(title: String, body: String) {
            notifications.append((title, body))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "CodexMeterTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
