import Foundation
import Testing
@testable import CodexMeter

@Suite("Claude session transfer")
struct ClaudeSessionTransferServiceTests {
    private let project = "-Users-me-app"

    @Test("Finds the last message the user typed and ignores tool results and injected turns")
    func findsLatestUserMessage() throws {
        let data = transcript([
            prompt("first", at: "2026-11-20T10:00:00.000Z"),
            #"{"type":"assistant","timestamp":"2026-11-20T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}"#,
            prompt("second", at: "2026-11-20T11:30:00.250Z"),
            #"{"type":"user","timestamp":"2026-11-20T12:00:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"toolUseResult":{}}"#,
            #"{"type":"user","isMeta":true,"timestamp":"2026-11-20T12:10:00.000Z","message":{"role":"user","content":"Caveat"}}"#,
            #"{"type":"user","isSidechain":true,"timestamp":"2026-11-20T12:20:00.000Z","message":{"role":"user","content":"subagent task"}}"#,
            #"{"type":"user","isCompactSummary":true,"timestamp":"2026-11-20T12:30:00.000Z","message":{"role":"user","content":"summary"}}"#,
            #"{"type":"ai-title","aiTitle":"A title","sessionId":"s1"}"#,
        ])

        let latest = try #require(try ClaudeSessionTransferService.latestUserMessage(in: data, sessionID: "s1"))

        #expect(latest == ClaudeTimestamp.parse("2026-11-20T11:30:00.250Z"))
        let imagePrompt = transcript([
            #"{"type":"user","timestamp":"2026-11-21T08:00:00Z","message":{"role":"user","content":[{"type":"image","source":{}},{"type":"text","text":"what is this"}]}}"#,
        ])
        #expect(try ClaudeSessionTransferService.latestUserMessage(in: imagePrompt, sessionID: "s2")
            == ClaudeTimestamp.parse("2026-11-21T08:00:00Z"))
        let titleOnly = transcript([#"{"type":"summary","summary":"Old conversation","leafUuid":"x"}"#])
        #expect(try ClaudeSessionTransferService.latestUserMessage(in: titleOnly, sessionID: "s3") == nil)
    }

    @Test("Rejects truncated and malformed transcripts")
    func rejectsInvalidTranscripts() {
        let truncated = Data(prompt("cut off", at: "2026-11-20T10:00:00Z").utf8)
        #expect(throws: ClaudeSessionTransferError.incompleteTranscript(sessionID: "s1")) {
            try ClaudeSessionTransferService.latestUserMessage(in: truncated, sessionID: "s1")
        }
        #expect(throws: ClaudeSessionTransferError.incompleteTranscript(sessionID: "s1")) {
            try ClaudeSessionTransferService.latestUserMessage(in: Data(), sessionID: "s1")
        }
        let malformed = transcript([prompt("fine", at: "2026-11-20T10:00:00Z"), "{not json"])
        #expect(throws: ClaudeSessionTransferError.invalidTranscript(sessionID: "s1", line: 2)) {
            try ClaudeSessionTransferService.latestUserMessage(in: malformed, sessionID: "s1")
        }
    }

    @Test("Keeps an identical or further-along destination and extends an earlier one")
    func comparesWithDestination() throws {
        let start = transcript([prompt("one", at: "2026-11-20T10:00:00Z")])
        let continued = start + transcript([prompt("two", at: "2026-11-20T11:00:00Z")])
        func disposition(_ source: Data, _ destination: Data?) throws -> ClaudeSessionTransferService.DestinationDisposition {
            try ClaudeSessionTransferService.destinationDisposition(
                sourceData: source, destinationData: destination, sessionID: "s1"
            )
        }

        #expect(try disposition(start, nil) == .copy)
        #expect(try disposition(start, start) == .alreadyPresent)
        #expect(try disposition(continued, start) == .replace)
        #expect(try disposition(start, continued) == .alreadyPresent)
    }

    @Test("Diverged conversations follow the later user message", arguments: [true, false])
    func resolvesDivergence(sourceNewer: Bool) throws {
        let start = transcript([prompt("one", at: "2026-11-20T10:00:00Z")])
        let older = start + transcript([prompt("short", at: "2026-11-20T11:00:00Z")])
        let newer = start + transcript([prompt("a much longer continuation", at: "2026-11-20T12:00:00.5Z")])

        #expect(try ClaudeSessionTransferService.destinationDisposition(
            sourceData: sourceNewer ? newer : older,
            destinationData: sourceNewer ? older : newer,
            sessionID: "s1"
        ) == (sourceNewer ? .replace : .alreadyPresent))
    }

    @Test("Selects the most recently changed conversations that have a user message")
    func selectsRecentSessions() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = profile("claude-work", in: home)
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        for (index, name) in ["oldest", "older", "recent", "newest"].enumerated() {
            try write(
                transcript([prompt(name, at: "2026-11-20T1\(index):00:00Z")]),
                to: source, project: index == 2 ? "-Users-me-other" : project, name: "\(name).jsonl",
                modifiedAt: now.addingTimeInterval(Double(index) * 60)
            )
        }
        // None of these is a conversation the user can resume.
        let later = now.addingTimeInterval(3_600)
        try write(transcript([prompt("task", at: "2026-11-21T10:00:00Z")]),
                  to: source, project: project, name: "agent-abc123.jsonl", modifiedAt: later)
        try write(transcript([prompt("task", at: "2026-11-21T10:00:00Z")]),
                  to: source, project: project, name: "newest/subagents/agent-def456.jsonl", modifiedAt: later)
        try write(transcript([#"{"type":"summary","summary":"No prompt","leafUuid":"x"}"#]),
                  to: source, project: project, name: "summary-only.jsonl", modifiedAt: later)
        try write(Data(), to: source, project: project, name: "empty.jsonl", modifiedAt: later)
        try write(Data("notes".utf8), to: source, project: project, name: "notes.txt", modifiedAt: later)

        let sessions = try ClaudeSessionTransferService.recentSessions(in: source, limit: 3)

        #expect(sessions.map(\.file.sessionID) == ["newest", "recent", "older"])
        #expect(sessions.map(\.file.projectDirectoryName) == [project, "-Users-me-other", project])
        #expect(sessions[0].lastUserMessageAt == ClaudeTimestamp.parse("2026-11-20T13:00:00Z"))
        #expect(try ClaudeSessionTransferService.recentSessions(in: profile("claude-empty", in: home), limit: 3).isEmpty)
    }

    @Test("Copies conversations to the same project folder and skips them the second time")
    func transfersBetweenProfiles() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = profile("claude-work", in: home)
        let destination = profile("claude-personal", in: home)
        let modifiedAt = Date(timeIntervalSince1970: 1_795_000_000)
        let first = transcript([prompt("one", at: "2026-11-20T10:00:00Z")])
        let second = transcript([prompt("two", at: "2026-11-20T11:00:00Z")])
        try write(first, to: source, project: project, name: "s1.jsonl", modifiedAt: modifiedAt)
        try write(second, to: source, project: project, name: "s2.jsonl", modifiedAt: modifiedAt.addingTimeInterval(60))
        let service = ClaudeSessionTransferService()

        let copied = try await service.transferRecentSessions(from: source, to: destination)

        #expect(copied == SessionTransferResult(sessionCount: 2, copiedCount: 2))
        let copy = destination.homeURL.appending(path: "projects/\(project)/s1.jsonl")
        #expect(try Data(contentsOf: copy) == first)
        let attributes = try FileManager.default.attributesOfItem(atPath: copy.path)
        #expect(attributes[.modificationDate] as? Date == modifiedAt)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try Data(contentsOf: source.homeURL.appending(path: "projects/\(project)/s1.jsonl")) == first)

        let repeated = try await service.transferRecentSessions(from: source, to: destination)
        #expect(repeated == SessionTransferResult(sessionCount: 2, copiedCount: 0))

        // Continue one conversation on each side, then copy again.
        let sourceContinued = first + transcript([prompt("more", at: "2026-11-21T09:00:00Z")])
        try write(sourceContinued, to: source, project: project, name: "s1.jsonl", modifiedAt: modifiedAt.addingTimeInterval(120))
        let destinationContinued = second + transcript([prompt("elsewhere", at: "2026-11-21T10:00:00Z")])
        try write(destinationContinued, to: destination, project: project, name: "s2.jsonl", modifiedAt: modifiedAt.addingTimeInterval(180))

        let updated = try await service.transferRecentSessions(from: source, to: destination)

        #expect(updated == SessionTransferResult(sessionCount: 2, copiedCount: 1))
        #expect(try Data(contentsOf: copy) == sourceContinued)
        #expect(try Data(contentsOf: destination.homeURL.appending(path: "projects/\(project)/s2.jsonl")) == destinationContinued)
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: destination.homeURL.appending(path: "projects/\(project)").path
        )
        #expect(leftovers.sorted() == ["s1.jsonl", "s2.jsonl"])
    }

    @Test("Refuses the same profile and a profile with nothing to copy")
    func rejectsImpossibleTransfers() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = profile("claude-work", in: home)
        let service = ClaudeSessionTransferService()

        await #expect(throws: ClaudeSessionTransferError.sameProfile) {
            try await service.transferRecentSessions(from: source, to: source)
        }
        await #expect(throws: ClaudeSessionTransferError.noEligibleSessions("claude-work")) {
            try await service.transferRecentSessions(from: source, to: profile("claude-personal", in: home))
        }
    }

    @Test("Restores a replaced conversation when a later copy fails")
    func rollsBackReplacement() throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let original = transcript([prompt("one", at: "2026-11-20T10:00:00Z")])
        let originalURL = home.appending(path: "s1.jsonl")
        try original.write(to: originalURL)
        let blockingFile = home.appending(path: "blocked")
        try Data("file".utf8).write(to: blockingFile)
        func record(_ id: String, _ data: Data) -> ClaudeSessionTransferService.SessionRecord {
            .init(
                file: .init(sessionID: id, projectDirectoryName: project,
                            url: URL(fileURLWithPath: "/source/\(id).jsonl"), modifiedAt: .now),
                data: data, lastUserMessageAt: .now
            )
        }
        let replacement = ClaudeSessionTransferService.PreparedTransfer(
            session: record("s1", original + transcript([prompt("two", at: "2026-11-20T11:00:00Z")])),
            destinationURL: originalURL, disposition: .replace, destinationData: original
        )
        let failing = ClaudeSessionTransferService.PreparedTransfer(
            session: record("s2", original),
            destinationURL: blockingFile.appending(path: "s2.jsonl"), disposition: .copy, destinationData: nil
        )

        #expect(throws: ClaudeSessionTransferError.self) {
            try ClaudeSessionTransferService.commit([replacement, failing])
        }
        #expect(try Data(contentsOf: originalURL) == original)
    }

    @Test("Reports the newest transcript change as the profile's last activity")
    func readsLatestActivity() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let source = profile("claude-work", in: home)
        #expect(try await ClaudeActivityReader.latestActivity(for: source) == nil)

        let newest = Date(timeIntervalSince1970: 1_795_000_600)
        try write(transcript([prompt("one", at: "2026-11-20T10:00:00Z")]),
                  to: source, project: project, name: "s1.jsonl", modifiedAt: newest.addingTimeInterval(-600))
        try write(transcript([prompt("two", at: "2026-11-20T11:00:00Z")]),
                  to: source, project: "-Users-me-other", name: "s2.jsonl", modifiedAt: newest)

        #expect(try await ClaudeActivityReader.latestActivity(for: source) == newest)
    }

    private func prompt(_ text: String, at timestamp: String) -> String {
        #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"\#(text)"},"uuid":"u-\#(text.count)","timestamp":"\#(timestamp)","cwd":"/Users/me/app","sessionId":"s1"}"#
    }

    private func transcript(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func profile(_ name: String, in home: URL) -> CodexProfile {
        CodexProfile(id: name, displayName: name, homeURL: home.appending(path: ".\(name)"), provider: .claude)
    }

    private func write(
        _ data: Data, to profile: CodexProfile, project: String, name: String, modifiedAt: Date
    ) throws {
        let url = profile.homeURL.appending(path: "projects/\(project)/\(name)")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
    }
}
