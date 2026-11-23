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
            try SessionTransferService.destinationDisposition(
                sourceData: rolloutData(threadID: "thread-1"),
                destinationData: Data(contentsOf: destination), threadID: "thread-1"
            ) == .alreadyPresent
        )

        try (source + Data(#"{"type":"event_msg","payload":{"type":"user_message"}}"#.utf8) + Data([0x0A]))
            .write(to: destination)
        #expect(
            try SessionTransferService.destinationDisposition(
                sourceData: rolloutData(threadID: "thread-1"),
                destinationData: Data(contentsOf: destination), threadID: "thread-1"
            ) == .alreadyPresent
        )
    }

    @Test("Skips a same-id destination with divergent history")
    func skipsDivergentDestination() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "rollout.jsonl")
        try rolloutData(threadID: "thread-1", marker: "destination").write(to: destination)

        #expect(
            try SessionTransferService.destinationDisposition(
                sourceData: rolloutData(threadID: "thread-1"),
                destinationData: Data(contentsOf: destination), threadID: "thread-1"
            ) == .alreadyPresent
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
        let source = CodexProfile(id: "source", displayName: "Source", homeURL: directory.appending(path: "source"))
        let destination = CodexProfile(id: "destination", displayName: "Destination", homeURL: directory.appending(path: "destination"))
        let existing = source.homeURL.appending(path: "sessions/existing.jsonl")
        let missing = source.homeURL.appending(path: "sessions/missing.jsonl")
        let existingDestination = destination.homeURL.appending(path: "sessions/existing.jsonl")
        let missingDestination = destination.homeURL.appending(path: "sessions/missing.jsonl")
        for url in [existing, existingDestination] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let destinationData = rolloutData(threadID: "existing", marker: "destination")
        try destinationData.write(to: existingDestination)
        try rolloutData(threadID: "existing", marker: "source").write(to: existing)
        try rolloutData(threadID: "missing").write(to: missing)
        let sessions = [
            SessionTransferService.SessionRecord(id: "existing", rolloutPath: existing.path, name: nil),
            SessionTransferService.SessionRecord(id: "missing", rolloutPath: missing.path, name: nil),
        ]
        var issues: [String] = []
        let prepared = try SessionTransferService.prepareTransferClosure(
            selected: sessions,
            available: sessions,
            from: source,
            to: destination,
            validate: { item in
                if item.destinationData != nil {
                    throw SessionTransferError.divergentHistory(item.session.id)
                }
            },
            onSkippedSession: { issues.append($0) }
        )
        #expect(issues.count == 1)
        #expect(try SessionTransferService.commit(prepared) == 1)
        #expect(try Data(contentsOf: existingDestination) == destinationData)
        #expect(try Data(contentsOf: missingDestination) == rolloutData(threadID: "missing"))
    }

    @Test("Round-trip transfer replaces the original and indexes the continued conversation")
    func replacesOlderConversationOnReturn() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = CodexProfile(id: "a", displayName: "a", homeURL: directory.appending(path: "a"))
        let b = CodexProfile(id: "b", displayName: "b", homeURL: directory.appending(path: "b"))
        let relative = "sessions/rollout-thread-1.jsonl"
        let originalURL = a.homeURL.appending(path: relative)
        try FileManager.default.createDirectory(at: originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = rolloutData(threadID: "thread-1")
        try original.write(to: originalURL)
        let first = SessionTransferService.SessionRecord(id: "thread-1", rolloutPath: originalURL.path, name: nil)
        let outgoing = try SessionTransferService.prepareTransferClosure(selected: [first], available: [first], from: a, to: b)
        #expect(try SessionTransferService.commit(outgoing) == 1)
        let continued = original + Data("{\"timestamp\":\"2026-10-17T10:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"Continue\"}}\n".utf8)
        let bURL = b.homeURL.appending(path: relative)
        try continued.write(to: bURL)
        let returning = SessionTransferService.SessionRecord(id: "thread-1", rolloutPath: bURL.path, name: nil)
        let incoming = try SessionTransferService.prepareTransferClosure(selected: [returning], available: [returning], from: b, to: a)
        #expect(incoming.map(\.disposition) == [.replace])
        #expect(SessionTransferService.sessionsRequiringIndex(incoming) == [returning])
        #expect(try SessionTransferService.commit(incoming) == 1)
        #expect(try Data(contentsOf: originalURL) == continued)
        #expect(try SessionTransferService.commit(SessionTransferService.prepareTransferClosure(selected: [first], available: [first], from: a, to: b)) == 0)
    }

    @Test("Treats equal-length local settings as equivalent without ignoring changed messages")
    func comparesLocalSettingsWithoutChangingHistoryOffsets() {
        let history = rolloutData(threadID: "thread-1")
        let first = Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"thread_settings_applied\",\"setting\":\"one\"}}\n".utf8)
        let second = Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"thread_settings_applied\",\"setting\":\"two\"}}\n".utf8)
        #expect(SessionTransferService.sameHistoryWithLocalSettings(history + first, history + second))
        #expect(!SessionTransferService.sameHistoryWithLocalSettings(history + first, history + second + Data(" ".utf8)))
        #expect(!SessionTransferService.sameHistoryWithLocalSettings(
            rolloutData(threadID: "thread-1", marker: "first") + first,
            rolloutData(threadID: "thread-1", marker: "other") + second
        ))
    }

    @Test("Persists successful comparisons and invalidates changed parents and index rows")
    func invalidatesPersistedComparison() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = CodexProfile(id: "destination", displayName: "Destination", homeURL: directory)
        let parent = directory.appending(path: "parent.jsonl")
        try Data("original".utf8).write(to: parent)
        let stamp = try #require(SyncComparisonCache.FileStamp.read(parent.path))
        let indexed = SyncComparisonCache.IndexedRollout(path: "/destination", updated: 42, recency: 42)
        let entry = SyncComparisonCache.Entry(
            sourcePath: "/source", destination: indexed, files: [parent.path: stamp],
            indexedParents: ["parent": parent.path], historySegments: ["segment": parent.path]
        )
        let cache = SyncComparisonCache(sources: ["profile": ["thread": entry]])
        try cache.save(in: profile)
        let recovered = try #require(SyncComparisonCache.read(in: profile).sources["profile"]?["thread"])

        let parents = ["parent": parent.path]
        let segments = ["segment": [parent.path]]
        #expect(recovered.matches(sourcePath: "/source", destination: indexed, indexedParents: parents, historySegments: segments))
        #expect(!recovered.matches(sourcePath: "/source", destination: nil, indexedParents: parents, historySegments: segments))
        #expect(!recovered.matches(sourcePath: "/source", destination: indexed, indexedParents: [:], historySegments: segments))
        #expect(!recovered.matches(sourcePath: "/source", destination: indexed, indexedParents: parents,
                                  historySegments: ["segment": [parent.path, "/duplicate"]]))
        try Data("modified".utf8).write(to: parent)
        #expect(!recovered.matches(sourcePath: "/source", destination: indexed, indexedParents: parents, historySegments: segments))
    }

    @Test("Divergent conversations follow user request recency rather than file size", arguments: [true, false])
    func comparesDivergentRequestTimestamps(sourceNewer: Bool) throws {
        func data(_ date: String, _ message: String) -> Data {
            rolloutData(threadID: "thread-1") + Data("{\"timestamp\":\"\(date)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"\(message)\"}}\n".utf8)
        }
        let older = data("2026-10-16T10:00:00.000Z", String(repeating: "long", count: 100))
        let newer = data("2026-10-17T10:00:00Z", "new")
        #expect(try SessionTransferService.destinationDisposition(
            sourceData: sourceNewer ? newer : older,
            destinationData: sourceNewer ? older : newer,
            threadID: "thread-1"
        ) == (sourceNewer ? .replace : .alreadyPresent))
    }

    @Test("Restores a replaced conversation when a later copy fails")
    func rollsBackReplacement() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalURL = directory.appending(path: "original.jsonl")
        let original = rolloutData(threadID: "thread-1")
        try original.write(to: originalURL)
        let blockingFile = directory.appending(path: "blocked")
        try Data("file".utf8).write(to: blockingFile)
        let replacement = SessionTransferService.PreparedTransfer(
            session: .init(id: "thread-1", rolloutPath: "/source/rollout.jsonl", name: nil),
            sourceData: original + Data("{}\n".utf8),
            destinationURL: originalURL, disposition: .replace,
            sourceThreadID: nil, destinationData: original
        )
        let failing = SessionTransferService.PreparedTransfer(
            session: .init(id: "thread-2", rolloutPath: "/source/other.jsonl", name: nil),
            sourceData: rolloutData(threadID: "thread-2"),
            destinationURL: blockingFile.appending(path: "other.jsonl"),
            disposition: .copy, sourceThreadID: nil
        )
        #expect(throws: (any Error).self) {
            try SessionTransferService.commit([replacement, failing])
        }
        #expect(try Data(contentsOf: originalURL) == original)
    }

    @Test("Compares current response-item user messages", arguments: [true, false])
    func comparesResponseItemRequests(sourceNewer: Bool) throws {
        func data(_ timestamp: String) -> Data {
            Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread-1\"}}\n{\"timestamp\":\"\(timestamp)\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[]}}\n".utf8)
        }
        let older = data("2026-10-16T10:00:00Z")
        let newer = data("2026-10-17T10:00:00.123Z")
        #expect(try SessionTransferService.destinationDisposition(
            sourceData: sourceNewer ? newer : older,
            destinationData: sourceNewer ? older : newer,
            threadID: "thread-1"
        ) == (sourceNewer ? .replace : .alreadyPresent))
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
                first_user_message TEXT NOT NULL DEFAULT '',
                has_user_event INTEGER NOT NULL DEFAULT 0,
                agent_path TEXT,
                source TEXT NOT NULL,
                recency_at_ms INTEGER NOT NULL,
                updated_at_ms INTEGER,
                updated_at INTEGER NOT NULL
            );
            INSERT INTO threads VALUES ('old', '/tmp/old', NULL, 0, 'visible', '', 0, NULL, 'cli', 10, 10, 10);
            INSERT INTO threads VALUES ('one', '/tmp/one', 'One', 0, '', 'First message', 0, NULL, 'cli', 50, 50, 50);
            INSERT INTO threads VALUES ('two', '/tmp/two', NULL, 0, 'visible', '', 0, NULL, 'vscode', 40, 40, 40);
            INSERT INTO threads VALUES ('three', '/tmp/three', NULL, 0, 'visible', '', 0, NULL, 'cli', 30, 30, 30);
            INSERT INTO threads VALUES ('archived', '/tmp/archived', NULL, 1, 'visible', '', 0, NULL, 'cli', 100, 100, 100);
            INSERT INTO threads VALUES ('hidden', '/tmp/hidden', NULL, 0, '', '', 0, NULL, 'cli', 90, 90, 90);
            INSERT INTO threads VALUES ('child', '/tmp/child', NULL, 0, 'visible', '', 0, '/root/child', '{"subagent":{}}', 80, 80, 80);
            """
        try runSQLite(database: database, sql: sql)

        let sessions = try SessionTransferService.recentSessions(for: profile, limit: 3)
        #expect(sessions.map(\.id) == ["one", "two", "three"])
        #expect(sessions.first?.name == "One")
        let now = Date(timeIntervalSince1970: 10 * 86_400 + 0.03)
        let syncSessions = try SessionTransferService.sessionsInSyncWindow(for: profile, now: now)
        #expect(syncSessions.map(\.id) == ["one", "two", "three"])

        let continued = directory.appending(path: "one.jsonl")
        let unchanged = directory.appending(path: "two.jsonl")
        try Data("""
            {"timestamp":"1970-01-01T00:00:00.050Z","type":"event_msg","payload":{"type":"user_message"}}

            """.utf8).write(to: continued)
        try rolloutData(threadID: "two").write(to: unchanged)
        try runSQLite(database: database, sql: """
            UPDATE threads SET rollout_path = '\(continued.path)' WHERE id = 'one';
            UPDATE threads SET rollout_path = '\(unchanged.path)', recency_at_ms = 60 WHERE id = 'two';
            """)
        try """
            [{"sourceID":"original","forkID":"two","activityMilliseconds":40},
             {"sourceID":"other","forkID":"one","activityMilliseconds":45}]
            """.write(
                to: directory.appending(path: "codex-meter-picker-imports.json"),
                atomically: true,
                encoding: .utf8
            )
        let syncAfterImport = try SessionTransferService.sessionsInSyncWindow(for: profile, now: now)
        #expect(syncAfterImport.map(\.id) == ["one", "three"])
    }

    @Test("Uses the original user message times after indexing")
    func restoresRecencyAfterIndexing() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = CodexProfile(id: "test", displayName: "test", homeURL: directory)
        let database = directory.appending(path: "state_5.sqlite")
        try runSQLite(database: database, sql: """
            CREATE TABLE threads (
                id TEXT PRIMARY KEY, rollout_path TEXT, name TEXT, preview TEXT,
                updated_at INTEGER, updated_at_ms INTEGER, recency_at INTEGER, recency_at_ms INTEGER
            );
            """)
        #expect(try SessionTransferService.visibleSessionIDs(in: profile).isEmpty)

        let sessions = try [("older", "2026-11-22T12:00:00.100Z"), ("newer", "2026-11-23T11:58:00.200Z")]
            .map { id, timestamp in
                let rollout = directory.appending(path: "\(id).jsonl")
                try """
                    {"type":"session_meta","payload":{"id":"\(id)"}}
                    {"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"user"}}
                    {"timestamp":"2026-11-23T12:00:00.999Z","type":"event_msg","payload":{"type":"thread_settings_applied"}}

                    """.write(to: rollout, atomically: true, encoding: .utf8)
                try runSQLite(database: database, sql: """
                    INSERT INTO threads VALUES (
                        '\(id)', '\(rollout.path)', NULL, 'visible', 1795435200, 1795435200000, 1795435200, 1795435200000
                    );
                    """)
                return SessionTransferService.SessionRecord(id: id, rolloutPath: "/source/\(id)", name: nil)
            }

        try SessionTransferService.restoreIndexedRecency(for: sessions, in: profile)
        let result = try SQLiteQueryRunner.query(
            databaseURL: database,
            sql: "SELECT id, updated_at_ms, recency_at_ms FROM threads ORDER BY recency_at_ms DESC;"
        )
        #expect(String(decoding: result, as: UTF8.self) == """
            newer|1795435080200|1795435080200
            older|1795348800100|1795348800100

            """)
        let olderRollout = directory.appending(path: "older.jsonl")
        let attributes = try FileManager.default.attributesOfItem(atPath: olderRollout.path)
        let date = try #require(attributes[.modificationDate] as? Date)
        #expect(abs(date.timeIntervalSince1970 - 1795348800.1) < 0.001)

        let fork = directory.appending(path: "fork.jsonl")
        try rolloutData(threadID: "fork").write(to: fork)
        try runSQLite(database: database, sql: """
            INSERT INTO threads VALUES (
                'fork', '\(fork.path)', NULL, 'visible', 1795435200, 1795435200000, 1795435200, 1795435200000
            );
            """)
        try SessionTransferService.restoreIndexedRecency(
            for: [.init(id: "fork", rolloutPath: fork.path, name: nil)],
            in: profile,
            inheritedActivity: ["fork": 1795348800100]
        )
        let forkActivity = try SQLiteQueryRunner.query(
            databaseURL: database,
            sql: "SELECT recency_at_ms FROM threads WHERE id = 'fork';"
        )
        #expect(String(decoding: forkActivity, as: UTF8.self) == "1795348800100\n")
    }

    @Test("Repairs an existing segmented conversation whose ancestors are not database rows")
    func repairsSegmentedHistory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = CodexProfile(id: "source", displayName: "source", homeURL: directory.appending(path: "source"))
        let destination = CodexProfile(id: "destination", displayName: "destination", homeURL: directory.appending(path: "destination"))
        let folder = "sessions/2026/09/28"
        let filenames = ["rollout-root.jsonl", "rollout-root_middle.jsonl", "rollout-root_leaf.jsonl"]
        try FileManager.default.createDirectory(at: source.homeURL.appending(path: folder), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.homeURL.appending(path: folder), withIntermediateDirectories: true)
        let rootData = rolloutData(threadID: "root")
        let middleData = segmentedRollout(threadID: "root", base: "root")
        let leafData = segmentedRollout(threadID: "root", base: "middle")
        for (filename, data) in zip(filenames, [rootData, middleData, leafData]) {
            try data.write(to: source.homeURL.appending(path: "\(folder)/\(filename)"))
        }
        let existingURL = destination.homeURL.appending(path: "\(folder)/\(filenames[2])")
        try leafData.write(to: existingURL)
        let leaf = SessionTransferService.SessionRecord(
            id: "root", rolloutPath: source.homeURL.appending(path: "\(folder)/\(filenames[2])").path, name: "Segmented"
        )
        let prepared = try SessionTransferService.prepareTransferClosure(
            selected: [leaf], available: [leaf], from: source, to: destination
        )
        #expect(prepared.map { $0.destinationURL.lastPathComponent } == filenames)
        #expect(prepared.map(\.disposition) == [.copy, .copy, .alreadyPresent])
        #expect(SessionTransferService.sessionsRequiringIndex(prepared) == [leaf])
        #expect(try SessionTransferService.commit(prepared) == 2)
        #expect(try Data(contentsOf: existingURL) == leafData)
        let repeated = try SessionTransferService.prepareTransferClosure(
            selected: [leaf], available: [leaf], from: source, to: destination
        )
        #expect(try SessionTransferService.commit(repeated) == 0)
        #expect(SessionTransferService.sessionsRequiringIndex(repeated).isEmpty)
    }

    @Test("Rejects missing, ambiguous, and cyclic paginated history before copying", arguments: ["missing", "ambiguous", "cycle"])
    func rejectsInvalidSegmentDependencies(kind: String) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = CodexProfile(id: "source", displayName: "source", homeURL: directory.appending(path: "source"))
        let destination = CodexProfile(id: "destination", displayName: "destination", homeURL: directory.appending(path: "destination"))
        let folder = source.homeURL.appending(path: "sessions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let leafURL = folder.appending(path: "rollout-root_leaf.jsonl")
        try segmentedRollout(threadID: "root", base: "parent").write(to: leafURL)
        if kind == "ambiguous" {
            try rolloutData(threadID: "root").write(to: folder.appending(path: "rollout-a_parent.jsonl"))
            try rolloutData(threadID: "root").write(to: folder.appending(path: "rollout-b_parent.jsonl"))
        } else if kind == "cycle" {
            try segmentedRollout(threadID: "root", base: "leaf").write(to: folder.appending(path: "rollout-root_parent.jsonl"))
        }
        let leaf = SessionTransferService.SessionRecord(id: "root", rolloutPath: leafURL.path, name: nil)
        #expect {
            try SessionTransferService.prepareTransferClosure(selected: [leaf], available: [leaf], from: source, to: destination)
        } throws: { error in
            switch (kind, error) {
            case ("missing", SessionTransferError.missingLineageSource): true
            case ("ambiguous", SessionTransferError.ambiguousLineageSource): true
            case ("cycle", SessionTransferError.lineageCycle): true
            default: false
            }
        }
        #expect(FileManager.default.fileExists(atPath: destination.homeURL.path) == false)
    }

    @Test("Rejects malformed history_base metadata instead of omitting its dependency")
    func rejectsMalformedHistoryBase() {
        let data = Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"root\",\"history_base\":{}}}\n".utf8)
        #expect(throws: SessionTransferError.self) {
            try SessionTransferService.validateRollout(data, threadID: "root")
        }
    }

    private func segmentedRollout(threadID: String, base: String) -> Data {
        Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(threadID)\",\"session_id\":\"\(threadID)\",\"history_mode\":\"paginated\",\"history_base\":{\"thread_id\":\"\(base)\",\"end_ordinal_exclusive\":2,\"end_byte_offset\":100}}}\n".utf8)
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
