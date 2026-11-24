import Foundation
import Testing
@testable import CodexMeter

@Suite("Recent Claude chats")
struct ClaudeRecentChatsTests {
    private let project = "-Users-me-app"

    @Test("Takes the title from a custom title, an AI title, a summary, then the first prompt")
    func picksTitle() {
        let prompts = [
            prompt("Fix the\tlogin\npage", at: "2026-11-20T10:00:00Z"),
            prompt("and the footer", at: "2026-11-20T11:00:00Z"),
        ]
        let summary = #"{"type":"summary","summary":"Login fixes","leafUuid":"x"}"#
        let aiTitle = #"{"type":"ai-title","aiTitle":"Repair login page","sessionId":"s1"}"#
        let customTitle = #"{"type":"custom-title","customTitle":"Login","sessionId":"s1"}"#
        func title(_ lines: [String]) -> String {
            ClaudeChatCatalog.summarize(transcript(lines)).title
        }

        #expect(title(prompts) == "Fix the login page")
        #expect(title(prompts + [summary]) == "Login fixes")
        #expect(title([aiTitle] + prompts + [summary]) == "Repair login page")
        #expect(title(prompts + [customTitle, aiTitle]) == "Login")
        #expect(title([prompt(String(repeating: "word ", count: 40), at: "2026-11-20T10:00:00Z")]).count == 100)
    }

    @Test("Reads typed prompts only and skips a record still being written")
    func readsTypedPrompts() {
        let data = transcript([
            #"{"type":"user","isMeta":true,"timestamp":"2026-11-20T09:00:00Z","message":{"role":"user","content":"Caveat"},"cwd":"/elsewhere"}"#,
            #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"image","source":{}},{"type":"text","text":"what is this"}]},"timestamp":"2026-11-20T10:00:00Z","cwd":"/Users/me/app"}"#,
            #"{"type":"assistant","timestamp":"2026-11-20T10:00:05Z","message":{"role":"assistant","content":[{"type":"text","text":"{\"type\":\"user\"}"}]}}"#,
            #"{"parentUuid":"a","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"ok"}]},"timestamp":"2026-11-20T12:00:00Z"}"#,
            #"{"type":"user","isSidechain":true,"timestamp":"2026-11-20T12:30:00Z","message":{"role":"user","content":"subagent task"}}"#,
            prompt("later", at: "2026-11-20T11:00:00.5Z"),
        ]) + Data(prompt("cut off", at: "2026-11-20T13:00:00Z").utf8)

        let summary = ClaudeChatCatalog.summarize(data)

        #expect(summary.firstPrompt == "what is this")
        #expect(summary.workingDirectory == "/Users/me/app")
        #expect(summary.lastUserMessageAt == ClaudeTimestamp.parse("2026-11-20T11:00:00.5Z"))
        #expect(ClaudeChatCatalog.summarize(transcript([#"{"type":"summary","summary":"Old","leafUuid":"x"}"#]))
            .lastUserMessageAt == nil)
    }

    @Test("Lists the newest conversations across accounts by their last prompt")
    func listsAcrossAccounts() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let work = profile("claude-work", in: home)
        let personal = profile("claude-personal", in: home)
        let base = Date(timeIntervalSince1970: 1_795_400_000)
        try write([prompt("one", at: "2026-11-20T10:00:00Z")], to: work, name: "s1", modifiedAt: base)
        try write([prompt("two", at: "2026-11-20T12:00:00Z")], to: personal, name: "s2", modifiedAt: base.addingTimeInterval(60))
        // Touched recently, but its last prompt is the oldest.
        try write([prompt("zero", at: "2026-11-19T10:00:00Z"), #"{"type":"ai-title","aiTitle":"Retitled","sessionId":"s0"}"#],
                  to: work, name: "s0", modifiedAt: base.addingTimeInterval(120))
        try write([#"{"type":"summary","summary":"No prompt","leafUuid":"x"}"#], to: work, name: "empty", modifiedAt: base.addingTimeInterval(180))
        try write([prompt("task", at: "2026-11-21T10:00:00Z")], to: work, name: "agent-abc", modifiedAt: base.addingTimeInterval(240))
        let catalog = ClaudeChatCatalog(home: URL(fileURLWithPath: "/Users/me"))

        let chats = await catalog.recentChats(in: [work, personal])

        #expect(chats.map(\.file.sessionID) == ["s2", "s1", "s0"])
        #expect(chats.map(\.profileID) == ["claude-personal", "claude-work", "claude-work"])
        #expect(chats.map(\.title) == ["two", "one", "Retitled"])
        #expect(chats[0].folderName == "app")
        #expect(chats[0].lastMessageAt == ClaudeTimestamp.parse("2026-11-20T12:00:00Z"))
        #expect(await catalog.recentChats(in: [work, personal], limit: 2).map(\.file.sessionID) == ["s2", "s1"])
    }

    @Test("Shows a conversation once and marks the accounts that hold the same copy")
    func marksCopies() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let work = profile("claude-work", in: home)
        let personal = profile("claude-personal", in: home)
        let modifiedAt = Date(timeIntervalSince1970: 1_795_400_000.25)
        let lines = [prompt("one", at: "2026-11-20T10:00:00Z")]
        try write(lines, to: work, name: "s1", modifiedAt: modifiedAt)
        let catalog = ClaudeChatCatalog()

        #expect(await catalog.recentChats(in: [work, personal]).map(\.copiedToProfileIDs) == [[]])

        try write(lines, to: personal, name: "s1", modifiedAt: modifiedAt)
        let copied = await catalog.recentChats(in: [work, personal])
        #expect(copied.map(\.profileID) == [work.id], "an identical copy stays under the first account")
        #expect(copied[0].copiedToProfileIDs == [personal.id])

        // Continued in the other account: that copy is now the newer one.
        try write(lines + [prompt("two", at: "2026-11-21T10:00:00Z")], to: personal, name: "s1",
                  modifiedAt: modifiedAt.addingTimeInterval(60))
        let continued = await catalog.recentChats(in: [work, personal])
        #expect(continued.map(\.profileID) == [personal.id])
        #expect(continued[0].copiedToProfileIDs.isEmpty)
    }

    @Test("Reads a transcript again only when its time or size changes")
    func cachesSummaries() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let work = profile("claude-work", in: home)
        let modifiedAt = Date(timeIntervalSince1970: 1_795_000_000)
        try write([prompt("aaa", at: "2026-11-20T10:00:00Z")], to: work, name: "s1", modifiedAt: modifiedAt)
        let catalog = ClaudeChatCatalog()
        #expect(await catalog.recentChats(in: [work]).map(\.title) == ["aaa"])

        try write([prompt("bbb", at: "2026-11-20T10:00:00Z")], to: work, name: "s1", modifiedAt: modifiedAt)
        #expect(await catalog.recentChats(in: [work]).map(\.title) == ["aaa"], "same time and size: cached")

        try write([prompt("bbb", at: "2026-11-20T10:00:00Z")], to: work, name: "s1", modifiedAt: modifiedAt.addingTimeInterval(1))
        #expect(await catalog.recentChats(in: [work]).map(\.title) == ["bbb"])
    }

    @Test("Copies one conversation and keeps the original")
    func copiesOneConversation() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let work = profile("claude-work", in: home)
        let personal = profile("claude-personal", in: home)
        let modifiedAt = Date(timeIntervalSince1970: 1_795_000_000)
        try write([prompt("one", at: "2026-11-20T10:00:00Z")], to: work, name: "s1", modifiedAt: modifiedAt)
        try write([prompt("two", at: "2026-11-20T11:00:00Z")], to: work, name: "s2", modifiedAt: modifiedAt)
        let chat = try #require(await ClaudeChatCatalog().recentChats(in: [work, personal]).last)
        let service = ClaudeSessionTransferService()

        let result = try await service.transferSession(chat.file, from: work, to: personal)

        #expect(chat.file.sessionID == "s1")
        #expect(result == SessionTransferResult(sessionCount: 1, copiedCount: 1))
        let copy = personal.homeURL.appending(path: "projects/\(project)/s1.jsonl")
        #expect(try Data(contentsOf: copy) == Data(contentsOf: chat.file.url))
        #expect(try FileManager.default.attributesOfItem(atPath: copy.path)[.modificationDate] as? Date == modifiedAt)
        #expect(FileManager.default.fileExists(atPath: chat.file.url.path))
        #expect(try FileManager.default.contentsOfDirectory(
            atPath: personal.homeURL.appending(path: "projects/\(project)").path
        ) == ["s1.jsonl"])

        #expect(try await service.transferSession(chat.file, from: work, to: personal)
            == SessionTransferResult(sessionCount: 1, copiedCount: 0))
        await #expect(throws: ClaudeSessionTransferError.sameProfile) {
            try await service.transferSession(chat.file, from: work, to: work)
        }
    }

    @Test("Formats ages the way claude-who does")
    func formatsAges() {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        func age(_ seconds: TimeInterval) -> String {
            RecentClaudeChat.ageLabel(since: now.addingTimeInterval(-seconds), relativeTo: now)
        }
        #expect(age(-5) == "now")
        #expect(age(59) == "now")
        #expect(age(60) == "1m")
        #expect(age(3_599) == "59m")
        #expect(age(7_200) == "2h")
        #expect(age(2 * 86_400 + 3 * 3_600 + 59) == "2d 3h")
    }

    private func prompt(_ text: String, at timestamp: String) -> String {
        let content = String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst().dropLast()
        return #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":\#(content)},"uuid":"u","timestamp":"\#(timestamp)","cwd":"/Users/me/app","sessionId":"s1"}"#
    }

    private func transcript(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func profile(_ name: String, in home: URL) -> CodexProfile {
        CodexProfile(id: name, displayName: name, homeURL: home.appending(path: ".\(name)"), provider: .claude)
    }

    private func write(_ lines: [String], to profile: CodexProfile, name: String, modifiedAt: Date) throws {
        let url = profile.homeURL.appending(path: "projects/\(project)/\(name).jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try transcript(lines).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "CodexMeterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
