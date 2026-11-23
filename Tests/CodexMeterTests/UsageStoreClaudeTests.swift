import Foundation
import Testing
@testable import CodexMeter

@Suite("Usage store with Claude profiles")
@MainActor
struct UsageStoreClaudeTests {
    /// Stands in for Claude Code: the five-hour window is idle until an activation request
    /// creates the `window` file, unless `stuck` exists.
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
            if [ -f "$CLAUDE_CONFIG_DIR/window" ]; then used=1; reset='"2099-01-01T00:00:00Z"'; else used=0; reset=null; fi
            echo "{\\"type\\":\\"control_response\\",\\"response\\":{\\"subtype\\":\\"success\\",\\"request_id\\":\\"codex-meter-usage\\",\\"response\\":{\\"subscription_type\\":\\"max\\",\\"rate_limits_available\\":true,\\"rate_limits\\":{\\"five_hour\\":{\\"utilization\\":$used,\\"resets_at\\":$reset},\\"seven_day\\":{\\"utilization\\":20,\\"resets_at\\":\\"2099-01-01T00:00:00Z\\"}}}}}"
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

    @Test("Shows why a Claude profile has no quota")
    func reportsUnavailableProfile() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let work = try profile("claude-work", in: home)
        let store = UsageStore(
            profiles: [work],
            claudeClient: ClaudeUsageClient(cli: ClaudeCLI(executableURL: home.appending(path: "absent"), home: home))
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

    private func makeStore(_ profiles: [CodexProfile], home: URL) throws -> UsageStore {
        let executable = home.appending(path: "claude")
        try Data("#!/bin/sh\n\(fakeClaude)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return UsageStore(
            profiles: profiles,
            claudeClient: ClaudeUsageClient(cli: ClaudeCLI(executableURL: executable, home: home))
        )
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

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "CodexMeterTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
