import Foundation
import Testing
@testable import CodexMeter

@Suite("Claude profile discovery")
struct ClaudeProfilesTests {
    @Test("Finds the default directory and every named directory that holds Claude Code data")
    func discoversProfiles() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        for path in [".claude", ".claude-work/projects", ".claude-new", ".claude-mem", ".codex", ".claudette/projects"] {
            try FileManager.default.createDirectory(
                at: home.appending(path: path), withIntermediateDirectories: true
            )
        }
        try Data("{}".utf8).write(to: home.appending(path: ".claude-new/.claude.json"))
        try Data("{}".utf8).write(to: home.appending(path: ".claude.json"))

        let profiles = ClaudeProfiles.discover(home: home)

        #expect(profiles.map(\.id) == ["claude", "claude-new", "claude-work"])
        #expect(profiles.map(\.displayName) == ["claude", "claude-new", "claude-work"])
        #expect(profiles.allSatisfy { $0.provider == .claude })
        #expect(profiles[2].homeURL.path == home.appending(path: ".claude-work").path)
        #expect(ClaudeProfiles.usesDefaultDirectory(profiles[0], home: home))
        #expect(ClaudeProfiles.usesDefaultDirectory(profiles[2], home: home) == false)
    }

    @Test("Keeps the Codex list unless Claude profiles exist and no Codex directory does")
    func choosesLaunchProfiles() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = [
            CodexProfile(id: "codex", displayName: "codex", homeURL: home.appending(path: ".codex")),
        ]
        #expect(CodexProfile.launchProfiles(home: home, codex: codex) == codex)

        try FileManager.default.createDirectory(
            at: home.appending(path: ".claude"), withIntermediateDirectories: true
        )
        #expect(CodexProfile.launchProfiles(home: home, codex: codex).map(\.id) == ["claude"])

        try FileManager.default.createDirectory(
            at: home.appending(path: ".codex"), withIntermediateDirectories: true
        )
        #expect(CodexProfile.launchProfiles(home: home, codex: codex).map(\.id) == ["codex", "claude"])
        #expect(codex[0].provider == .codex)
    }

    @Test("Encodes a working directory the way Claude Code names its project folder")
    func encodesProjectDirectory() {
        #expect(ClaudeProfiles.projectDirectoryName(for: "/Users/me/My Project_1.0") == "-Users-me-My-Project-1-0")
        // Claude Code replaces UTF-16 units, so one emoji becomes two hyphens.
        #expect(ClaudeProfiles.projectDirectoryName(for: "/tmp/é😀x") == "-tmp----x")
        #expect(ClaudeProfiles.matchesProjectDirectory("-Users-me-app", workingDirectory: "/Users/me/app"))
        #expect(ClaudeProfiles.matchesProjectDirectory("-Users-me-app2", workingDirectory: "/Users/me/app") == false)

        let longPath = "/" + String(repeating: "a", count: 250)
        let truncated = "-" + String(repeating: "a", count: 199)
        #expect(ClaudeProfiles.matchesProjectDirectory(truncated + "-1x2y3z", workingDirectory: longPath))
        #expect(ClaudeProfiles.matchesProjectDirectory(truncated, workingDirectory: longPath) == false)
    }

    @Test("Parses Claude timestamps with any fractional precision and offset")
    func parsesTimestamps() throws {
        let base = Date(timeIntervalSince1970: 1_762_232_399)
        let micro = try #require(ClaudeTimestamp.parse("2025-11-04T04:59:59.943648+00:00"))
        #expect(abs(micro.timeIntervalSince(base) - 0.943648) < 0.000_01)
        let milli = try #require(ClaudeTimestamp.parse("2025-11-04T04:59:59.177Z"))
        #expect(abs(milli.timeIntervalSince(base) - 0.177) < 0.000_01)
        #expect(ClaudeTimestamp.parse("2025-11-04T04:59:59Z") == base)
        #expect(ClaudeTimestamp.parse("2025-11-03T23:59:59-05:00") == base)
        #expect(ClaudeTimestamp.parse("yesterday") == nil)
        #expect(ClaudeTimestamp.parse("2025-11-04T04:59:59.Z") == nil)
    }

    @Test("Names the provider that owns the tightest quota window")
    func findsLowestRemainingQuota() {
        func status(_ provider: ProfileProvider, short: Double?, weekly: Double?) -> ProfileStatus {
            func window(_ used: Double?) -> QuotaWindow? {
                used.map { QuotaWindow(durationMinutes: 300, usedPercent: $0, resetsAt: nil, state: .active) }
            }
            let profile = CodexProfile(
                id: "\(provider)-\(short ?? -1)", displayName: "p",
                homeURL: URL(fileURLWithPath: "/nowhere"), provider: provider
            )
            return ProfileStatus(profile: profile, snapshot: QuotaSnapshot(
                planType: nil, shortWindow: window(short), weeklyWindow: window(weekly), fetchedAt: .now
            ))
        }
        let codexOnly = [status(.codex, short: 10, weekly: 40)]
        #expect(LowestRemainingQuota.find(in: codexOnly) == LowestRemainingQuota(provider: .codex, percent: 60))
        let mixed = codexOnly + [status(.claude, short: nil, weekly: 88.4)]
        #expect(LowestRemainingQuota.find(in: mixed) == LowestRemainingQuota(provider: .claude, percent: 12))
        let noData = [ProfileStatus(profile: codexOnly[0].profile)]
        #expect(LowestRemainingQuota.find(in: noData) == nil)
    }

    @Test("Leaves Claude accounts out of the Codex cycle pace")
    func paceIgnoresClaudeProfiles() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = QuotaSnapshot(
            planType: "pro",
            shortWindow: nil,
            weeklyWindow: QuotaWindow(
                durationMinutes: 10_080, usedPercent: 30,
                resetsAt: now.addingTimeInterval(3 * UsagePace.day), state: .active
            ),
            fetchedAt: now
        )
        let home = URL(fileURLWithPath: "/nowhere")
        let statuses = [
            ProfileStatus(profile: CodexProfile(id: "codex", displayName: "codex", homeURL: home), snapshot: snapshot),
            ProfileStatus(
                profile: CodexProfile(id: "claude", displayName: "claude", homeURL: home, provider: .claude),
                snapshot: snapshot
            ),
        ]
        #expect(Array(UsagePace.currentObservations(statuses, now: now).keys) == ["codex"])
    }

    @Test("Creates an account directory and its alias once, as claude-accounts does")
    func createsAccount() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }

        let profile = try ClaudeProfiles.createAccount(named: "claude-Work ", home: home, shell: "/bin/zsh")
        _ = try ClaudeProfiles.createAccount(named: "work", home: home, shell: "/bin/zsh")

        #expect(profile.id == "claude-work")
        #expect(profile.provider == .claude)
        let attributes = try FileManager.default.attributesOfItem(atPath: home.appending(path: ".claude-work").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let zshrc = try String(contentsOf: home.appending(path: ".zshrc"), encoding: .utf8)
        #expect(zshrc.components(separatedBy: #"alias claude-work='CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude'"#).count == 2)

        _ = try ClaudeProfiles.createAccount(named: "personal", home: home, shell: "/bin/bash")
        #expect(FileManager.default.fileExists(atPath: home.appending(path: ".bashrc").path))
        for name in ["", "my work", "-x", "a/b", "ü"] {
            #expect(throws: ClaudeAccountError.invalidName) {
                try ClaudeProfiles.createAccount(named: name, home: home)
            }
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "CodexMeterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
