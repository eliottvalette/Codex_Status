import Foundation
import Testing
@testable import CodexMeter

@Suite("Session transfer file handling")
struct SessionTransferServiceTests {
    @Test("Accepts a complete rollout with matching metadata")
    func validatesCompleteRollout() throws {
        let data = rolloutData(threadID: "thread-1")
        try SessionTransferService.validateRollout(data, threadID: "thread-1")
    }

    @Test("Rejects truncated and mismatched rollouts")
    func rejectsInvalidRollouts() {
        let truncated = Data(#"{"type":"session_meta"}"#.utf8)
        #expect(throws: SessionTransferError.self) {
            try SessionTransferService.validateRollout(truncated, threadID: "thread-1")
        }

        #expect(throws: SessionTransferError.self) {
            try SessionTransferService.validateRollout(
                rolloutData(threadID: "different-thread"),
                threadID: "thread-1"
            )
        }
    }

    @Test("Treats an identical or destination-continued rollout as already present")
    func recognizesSafeReexport() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "rollout.jsonl")
        let source = rolloutData(threadID: "thread-1")

        try source.write(to: destination)
        #expect(
            SessionTransferService.destinationDisposition(at: destination) == .alreadyPresent
        )

        try (source + Data(#"{"type":"event_msg","payload":{"type":"user_message"}}"#.utf8) + Data([0x0A]))
            .write(to: destination)
        #expect(
            SessionTransferService.destinationDisposition(at: destination) == .alreadyPresent
        )
    }

    @Test("Skips a same-id destination with divergent history")
    func skipsDivergentDestination() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "rollout.jsonl")
        try rolloutData(threadID: "thread-1", marker: "destination").write(to: destination)

        #expect(
            SessionTransferService.destinationDisposition(at: destination) == .alreadyPresent
        )
        #expect(try Data(contentsOf: destination) == rolloutData(
            threadID: "thread-1",
            marker: "destination"
        ))
    }

    @Test("Copies missing conversations while preserving divergent existing ones")
    func copiesMissingConversationsFromMixedBatch() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destinationRoot = directory.appending(path: "destination")
        let existingURL = destinationRoot.appending(path: "sessions/existing.jsonl")
        let missingURL = destinationRoot.appending(path: "sessions/missing.jsonl")
        try FileManager.default.createDirectory(
            at: existingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existingData = rolloutData(threadID: "existing", marker: "destination")
        try existingData.write(to: existingURL)

        let prepared = [
            SessionTransferService.PreparedTransfer(
                session: .init(id: "existing", rolloutPath: "/source/existing.jsonl", name: nil),
                sourceData: rolloutData(threadID: "existing", marker: "source"),
                destinationURL: existingURL,
                disposition: SessionTransferService.destinationDisposition(at: existingURL),
                sourceThreadID: nil
            ),
            SessionTransferService.PreparedTransfer(
                session: .init(id: "missing", rolloutPath: "/source/missing.jsonl", name: nil),
                sourceData: rolloutData(threadID: "missing"),
                destinationURL: missingURL,
                disposition: SessionTransferService.destinationDisposition(at: missingURL),
                sourceThreadID: nil
            ),
        ]

        #expect(try SessionTransferService.commit(prepared) == 1)
        #expect(try Data(contentsOf: existingURL) == existingData)
        #expect(try Data(contentsOf: missingURL) == rolloutData(threadID: "missing"))
    }

    @Test("Copies a rollout to the matching destination-relative path")
    func copiesToMatchingRelativePath() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceRoot = directory.appending(path: "source")
        let destinationRoot = directory.appending(path: "destination")
        let sourceRollout = sourceRoot.appending(path: "sessions/2026/09/23/rollout-thread-1.jsonl")
        try FileManager.default.createDirectory(
            at: sourceRollout.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sourceData = rolloutData(threadID: "thread-1")
        try sourceData.write(to: sourceRollout)

        let session = SessionTransferService.SessionRecord(
            id: "thread-1",
            rolloutPath: sourceRollout.path,
            name: nil
        )
        let source = CodexProfile(id: "source", displayName: "source", homeURL: sourceRoot)
        let destination = CodexProfile(
            id: "destination",
            displayName: "destination",
            homeURL: destinationRoot
        )
        let prepared = try SessionTransferService.prepareTransfer(
            session,
            from: source,
            to: destination
        )

        #expect(try SessionTransferService.commit([prepared]) == 1)
        let copiedURL = destinationRoot.appending(
            path: "sessions/2026/09/23/rollout-thread-1.jsonl"
        )
        #expect(try Data(contentsOf: copiedURL) == sourceData)
    }

    @Test("Copies required fork ancestors before the selected conversation")
    func copiesForkLineageInDependencyOrder() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceRoot = directory.appending(path: "source")
        let destinationRoot = directory.appending(path: "destination")
        let sessionsDirectory = sourceRoot.appending(path: "sessions/2026/09/23")
        try FileManager.default.createDirectory(
            at: sessionsDirectory,
            withIntermediateDirectories: true
        )

        let rootURL = sessionsDirectory.appending(path: "rollout-root.jsonl")
        let childURL = sessionsDirectory.appending(path: "rollout-child.jsonl")
        try rolloutData(threadID: "root").write(to: rootURL)
        try rolloutData(threadID: "child", sourceThreadID: "root").write(to: childURL)

        let root = SessionTransferService.SessionRecord(
            id: "root",
            rolloutPath: rootURL.path,
            name: nil
        )
        let child = SessionTransferService.SessionRecord(
            id: "child",
            rolloutPath: childURL.path,
            name: "Selected child"
        )
        let source = CodexProfile(id: "source", displayName: "source", homeURL: sourceRoot)
        let destination = CodexProfile(
            id: "destination",
            displayName: "destination",
            homeURL: destinationRoot
        )

        let prepared = try SessionTransferService.prepareTransferClosure(
            selected: [child],
            available: [child, root],
            from: source,
            to: destination
        )
        #expect(prepared.map(\.session.id) == ["root", "child"])
        #expect(try SessionTransferService.commit(prepared) == 2)
        #expect(
            FileManager.default.fileExists(
                atPath: destinationRoot.appending(
                    path: "sessions/2026/09/23/rollout-root.jsonl"
                ).path
            )
        )
    }

    @Test("Rejects a fork whose source rollout is absent")
    func rejectsMissingForkAncestor() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceRoot = directory.appending(path: "source")
        let childURL = sourceRoot.appending(path: "sessions/rollout-child.jsonl")
        try FileManager.default.createDirectory(
            at: childURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try rolloutData(threadID: "child", sourceThreadID: "missing-root")
            .write(to: childURL)

        let child = SessionTransferService.SessionRecord(
            id: "child",
            rolloutPath: childURL.path,
            name: nil
        )
        let source = CodexProfile(id: "source", displayName: "source", homeURL: sourceRoot)
        let destination = CodexProfile(
            id: "destination",
            displayName: "destination",
            homeURL: directory.appending(path: "destination")
        )

        #expect {
            try SessionTransferService.prepareTransferClosure(
                selected: [child],
                available: [child],
                from: source,
                to: destination
            )
        } throws: { error in
            guard case SessionTransferError.missingLineageSource(
                threadID: "child",
                sourceThreadID: "missing-root"
            ) = error else {
                return false
            }
            return true
        }
    }

    @Test("Selects three recent visible parent conversations")
    func selectsRecentParentConversations() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = CodexProfile(id: "test", displayName: "test", homeURL: directory)
        let database = directory.appending(path: "state_5.sqlite")
        let sql = """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY,
                rollout_path TEXT NOT NULL,
                name TEXT,
                archived INTEGER NOT NULL,
                preview TEXT NOT NULL,
                agent_path TEXT,
                source TEXT NOT NULL,
                recency_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER,
                updated_at INTEGER NOT NULL
            );
            INSERT INTO threads VALUES ('old', '/tmp/old', NULL, 0, 'visible', NULL, 'cli', 10, 10, 10);
            INSERT INTO threads VALUES ('one', '/tmp/one', 'One', 0, 'visible', NULL, 'cli', 50, 50, 50);
            INSERT INTO threads VALUES ('two', '/tmp/two', NULL, 0, 'visible', NULL, 'vscode', 40, 40, 40);
            INSERT INTO threads VALUES ('three', '/tmp/three', NULL, 0, 'visible', NULL, 'cli', 30, 30, 30);
            INSERT INTO threads VALUES ('archived', '/tmp/archived', NULL, 1, 'visible', NULL, 'cli', 100, 100, 100);
            INSERT INTO threads VALUES ('hidden', '/tmp/hidden', NULL, 0, '', NULL, 'cli', 90, 90, 90);
            INSERT INTO threads VALUES ('child', '/tmp/child', NULL, 0, 'visible', '/root/child', '{"subagent":{}}', 80, 80, 80);
            """
        try runSQLite(database: database, sql: sql)

        let sessions = try SessionTransferService.recentSessions(for: profile, limit: 3)
        #expect(sessions.map(\.id) == ["one", "two", "three"])
        #expect(sessions.first?.name == "One")
    }

    private func rolloutData(
        threadID: String,
        marker: String = "source",
        sourceThreadID: String? = nil
    ) -> Data {
        let lineage = sourceThreadID.map { ",\"forked_from_id\":\"\($0)\"" } ?? ""
        let text = """
            {"type":"session_meta","payload":{"id":"\(threadID)"\(lineage)}}
            {"type":"event_msg","payload":{"type":"user_message","message":"\(marker)"}}

            """
        return Data(text.utf8)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "CodexMeterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func runSQLite(database: URL, sql: String) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let stderr = String(
            decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        #expect(process.terminationStatus == 0, Comment(rawValue: stderr))
    }
}
