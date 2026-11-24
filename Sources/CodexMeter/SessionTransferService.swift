import Darwin
import Foundation

struct SessionSyncResult: Sendable {
    var updatedCount = 0
    var issues: [String] = []
}

private struct PickerImport: Codable {
    let sourceID: String
    let forkID: String
    let activityMilliseconds: Int64
}

enum SessionTransferError: Error, LocalizedError {
    case sameProfile
    case invalidQueryResponse(String)
    case noEligibleSessions(String)
    case rolloutOutsideProfile(threadID: String, path: String)
    case unreadableRollout(threadID: String, reason: String)
    case incompleteRollout(threadID: String)
    case invalidRollout(threadID: String, line: Int)
    case mismatchedThreadIdentifier(expected: String)
    case missingLineageSource(threadID: String, sourceThreadID: String)
    case ambiguousLineageSource(String)
    case invalidHistoryBase(String)
    case lineageCycle(threadID: String)
    case divergentHistory(String)
    case copyFailed(threadID: String, reason: String)
    case missingCodexExecutable(URL)
    case appServerFailed(String)
    case appServerTimedOut(TimeInterval)
    case indexingFailed(profile: String, copiedCount: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .sameProfile:
            "Source and destination profiles must be different."
        case let .invalidQueryResponse(message):
            "Could not decode the recent-session query: \(message)"
        case let .noEligibleSessions(profile):
            "No transferable conversation was found for \(profile)."
        case let .rolloutOutsideProfile(threadID, path):
            "Conversation \(threadID) has a rollout outside its profile: \(path)"
        case let .unreadableRollout(threadID, reason):
            "Could not read conversation \(threadID): \(reason)"
        case let .incompleteRollout(threadID):
            "Conversation \(threadID) ends with an incomplete JSONL record."
        case let .invalidRollout(threadID, line):
            "Conversation \(threadID) contains invalid JSON on line \(line)."
        case let .mismatchedThreadIdentifier(expected):
            "The rollout metadata does not identify the expected conversation \(expected)."
        case let .missingLineageSource(threadID, sourceThreadID):
            "Conversation \(threadID) depends on missing source rollout \(sourceThreadID)."
        case let .ambiguousLineageSource(identifier):
            "Multiple source rollouts match history segment \(identifier)."
        case let .invalidHistoryBase(identifier):
            "Conversation \(identifier) has invalid history_base metadata."
        case let .lineageCycle(threadID):
            "Conversation history contains a lineage cycle at \(threadID)."
        case let .divergentHistory(threadID):
            "Conversation \(threadID) has different histories across profiles. Both copies were kept."
        case let .copyFailed(threadID, reason):
            "Could not copy conversation \(threadID): \(reason)"
        case let .missingCodexExecutable(url):
            "Codex executable not found at \(url.path)."
        case let .appServerFailed(message):
            "Codex app-server failed while indexing transferred conversations: \(message)"
        case let .appServerTimedOut(seconds):
            "Codex app-server did not finish indexing within \(Int(seconds)) seconds."
        case let .indexingFailed(profile, copiedCount, reason):
            if copiedCount > 0 {
                "Copied \(copiedCount) conversation(s) to \(profile), but /resume indexing failed: \(reason)"
            } else {
                "Could not refresh /resume for \(profile): \(reason)"
            }
        }
    }
}

struct SessionTransferService: Sendable {
    let codexExecutableURL: URL
    let timeout: TimeInterval

    init(
        codexExecutableURL: URL = URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
        timeout: TimeInterval = 30
    ) {
        self.codexExecutableURL = codexExecutableURL
        self.timeout = timeout
    }

    @concurrent
    func transferRecentSessions(
        from source: CodexProfile,
        to destination: CodexProfile,
        limit: Int = 3
    ) async throws -> SessionTransferResult {
        guard source.id != destination.id else {
            throw SessionTransferError.sameProfile
        }

        let sessions = try Self.recentSessions(for: source, limit: limit)
        guard sessions.isEmpty == false else {
            throw SessionTransferError.noEligibleSessions(source.displayName)
        }

        return try transfer(sessions, from: source, to: destination)
    }

    @concurrent
    func syncRecentSessions(across profiles: [CodexProfile], now: Date = .now) async throws -> SessionSyncResult {
        var result = SessionSyncResult()
        var sources: [(CodexProfile, [SessionRecord])] = []
        for profile in profiles {
            do {
                let sessions = try Self.sessionsInSyncWindow(for: profile, now: now) { issue in
                    result.issues.append("\(profile.displayName): \(issue)")
                }
                sources.append((profile, sessions))
            } catch {
                result.issues.append("\(profile.displayName): \(error.localizedDescription)")
            }
        }
        for (source, sessions) in sources where !sessions.isEmpty {
            for destination in profiles where destination.id != source.id {
                try Task.checkCancellation()
                let prefix = "\(source.displayName) → \(destination.displayName)"
                do {
                    let transfer = try transfer(sessions, from: source, to: destination) { issue in
                        result.issues.append("\(prefix): \(issue)")
                    }
                    result.updatedCount += transfer.copiedCount + transfer.pickerImportsCount
                } catch {
                    result.issues.append("\(prefix): \(error.localizedDescription)")
                }
            }
        }
        return result
    }

    private func transfer(
        _ sessions: [SessionRecord],
        from source: CodexProfile,
        to destination: CodexProfile,
        onSyncIssue: ((String) -> Void)? = nil
    ) throws -> SessionTransferResult {
        let availableSessions = try Self.allSessions(for: source)
        let destinationRecords: [String: SessionRecord]
        if onSyncIssue != nil {
            let database = destination.homeURL.appending(path: "state_5.sqlite")
            let indexed = FileManager.default.fileExists(atPath: database.path)
                ? try Self.allSessions(for: destination) : []
            destinationRecords = Dictionary(uniqueKeysWithValues: indexed.map { ($0.id, $0) })
        } else {
            destinationRecords = [:]
        }
        let comparisonKey = source.homeURL.resolvingSymlinksInPath().path
        var comparisonCache: SyncComparisonCache?
        if let onSyncIssue {
            do {
                comparisonCache = try SyncComparisonCache.read(in: destination)
            } catch {
                onSyncIssue("Could not read the comparison cache: \(error.localizedDescription)")
                comparisonCache = SyncComparisonCache()
            }
        }
        let indexedRollouts = comparisonCache == nil ? [:] : try Self.cacheIndexedRollouts(in: destination)
        let entries = comparisonCache?.sources[comparisonKey] ?? [:]
        let availablePaths = Dictionary((availableSessions + sessions).map { ($0.id, $0.rolloutPath) }) { _, selected in selected }
        let segmentIDs = Set(entries.values.flatMap { $0.historySegments.keys })
        let segmentPaths = segmentIDs.isEmpty ? [:] : try Self.cacheSegmentPaths(segmentIDs, in: source)
        let cached = sessions.filter { session in
            entries[session.id]?.matches(
                sourcePath: session.rolloutPath,
                destination: indexedRollouts[session.id],
                indexedParents: availablePaths,
                historySegments: segmentPaths
            ) == true
        }
        let cachedIDs = Set(cached.map(\.id))
        for session in cached {
            if let issue = entries[session.id]?.issue {
                onSyncIssue?(issue)
            }
        }
        let pending = sessions.filter { !cachedIDs.contains($0.id) }
        let selectedPaths = Set(pending.map(\.rolloutPath))
        var detachedPaths: [String: String] = [:]
        var conflicts: [String: SyncComparisonCache.Entry] = [:]
        var prepared = try Self.prepareTransferClosure(
            selected: pending,
            available: availableSessions + cached,
            from: source,
            to: destination,
            validate: { item in
                guard onSyncIssue != nil else { return }
                if selectedPaths.contains(item.session.rolloutPath),
                   let indexedPath = destinationRecords[item.session.id]?.rolloutPath,
                   URL(fileURLWithPath: indexedPath).resolvingSymlinksInPath() != item.destinationURL.resolvingSymlinksInPath() {
                    let indexedURL = URL(fileURLWithPath: indexedPath).resolvingSymlinksInPath()
                    let directory = destination.homeURL.resolvingSymlinksInPath()
                    guard indexedURL.path.hasPrefix(directory.path + "/"),
                          try Self.isDetachedMetadataRollout(indexedURL, id: item.session.id),
                          try Self.latestUserRequest(in: item.sourceData) != nil else {
                        throw SessionTransferError.divergentHistory(item.session.id)
                    }
                    detachedPaths[item.session.id] = indexedPath
                }
                if let existing = item.destinationData,
                   !existing.starts(with: item.sourceData),
                   !item.sourceData.starts(with: existing) {
                    guard Self.sameHistoryWithLocalSettings(item.sourceData, existing) else {
                        let error = SessionTransferError.divergentHistory(item.session.id)
                        if selectedPaths.contains(item.session.rolloutPath),
                           let indexed = indexedRollouts[item.session.id], item.comparisonStamps.count == 2,
                           indexed.path == destinationRecords[item.session.id]?.rolloutPath,
                           URL(fileURLWithPath: indexed.path).resolvingSymlinksInPath()
                            == item.destinationURL.resolvingSymlinksInPath() {
                            conflicts[item.session.id] = SyncComparisonCache.Entry(
                                sourcePath: item.session.rolloutPath, destination: indexed,
                                files: item.comparisonStamps, indexedParents: [:], historySegments: [:],
                                issue: "\(item.session.name ?? item.session.id): \(error.localizedDescription)"
                            )
                        }
                        throw error
                    }
                    item.disposition = .alreadyPresent
                }
            },
            onSkippedSession: onSyncIssue,
            captureStamps: comparisonCache != nil
        )
        let selected = prepared.filter { selectedPaths.contains($0.session.rolloutPath) }
        let selectedIDs = Set(selected.map(\.session.id))
        let requestedIDs = Set(sessions.map(\.id))
        let visibleIDs = try Self.visibleSessionIDs(in: destination)
        for index in prepared.indices where selectedPaths.contains(prepared[index].session.rolloutPath) {
            let item = prepared[index]
            if !visibleIDs.contains(item.session.id) || detachedPaths[item.session.id] != nil {
                prepared[index].requiresIndex = true
            }
        }
        var copiedSessions = Self.sessionsRequiringIndex(prepared)
        let copiedIDs = Set(copiedSessions.map(\.id))
        let previouslyCopiedSessions = prepared.compactMap { transfer -> SessionRecord? in
            guard selectedPaths.contains(transfer.session.rolloutPath),
                  !copiedIDs.contains(transfer.session.id),
                  transfer.destinationData == transfer.sourceData else { return nil }
            return transfer.session
        }
        if let onSyncIssue {
            for session in pending where !selectedIDs.contains(session.id) && !copiedIDs.contains(session.id) {
                guard let record = destinationRecords[session.id] else { continue }
                do {
                    let rollout = URL(fileURLWithPath: record.rolloutPath).resolvingSymlinksInPath()
                    let home = destination.homeURL.resolvingSymlinksInPath()
                    guard rollout.path.hasPrefix(home.path + "/") else {
                        throw SessionTransferError.rolloutOutsideProfile(threadID: record.id, path: rollout.path)
                    }
                    if !visibleIDs.contains(record.id) {
                        try Self.validateRollout(Data(contentsOf: rollout), threadID: record.id)
                        copiedSessions.append(record)
                    }
                } catch {
                    onSyncIssue("\(record.name ?? record.id): \(error.localizedDescription)")
                }
            }
        }
        let copiedCount = copiedSessions.count
        _ = try Self.commit(prepared)

        var indexedSessions: [SessionRecord] = []
        var pickerImportsCount = 0
        do {
            try Self.repairDetachedIndexPaths(detachedPaths, using: selected, in: destination)
            if !copiedSessions.isEmpty {
                indexedSessions = try index(sessions: copiedSessions, in: destination, onIssue: onSyncIssue)
            }
            try Self.restoreIndexedRecency(for: indexedSessions + previouslyCopiedSessions, in: destination)
            let visibleAfterIndexing = try Self.visibleSessionIDs(in: destination)
            for missing in selected where !visibleAfterIndexing.contains(missing.session.id) {
                let error = SessionTransferError.invalidQueryResponse("Missing preview for \(missing.session.id).")
                guard let onSyncIssue else { throw error }
                onSyncIssue(error.localizedDescription)
            }
            let pickerSessions = sessions.filter { visibleAfterIndexing.contains($0.id) }
            pickerImportsCount = try ensurePickerVisibility(for: pickerSessions, in: destination, onIssue: onSyncIssue)
        } catch {
            throw SessionTransferError.indexingFailed(
                profile: destination.displayName,
                copiedCount: copiedCount,
                reason: error.localizedDescription
            )
        }

        if var comparisonCache, let onSyncIssue {
            do {
                let finalIndex = try Self.cacheIndexedRollouts(in: destination)
                var retained: [String: SyncComparisonCache.Entry] = [:]
                for session in cached {
                    if let entry = entries[session.id], entry.destination == finalIndex[session.id] {
                        retained[session.id] = entry
                    }
                }
                for (id, entry) in conflicts
                where entry.destination == finalIndex[id]
                    && entry.files.allSatisfy({ SyncComparisonCache.FileStamp.read($0.key) == $0.value }) {
                    retained[id] = entry
                }
                let byPath = Dictionary(uniqueKeysWithValues: prepared.map { ($0.session.rolloutPath, $0) })
                let bySegment = Dictionary(grouping: prepared, by: { Self.segmentIdentifier(for: $0.session.rolloutPath) })
                for item in selected where detachedPaths[item.session.id] == nil {
                    guard let indexed = finalIndex[item.session.id],
                          URL(fileURLWithPath: indexed.path).resolvingSymlinksInPath()
                            == item.destinationURL.resolvingSymlinksInPath(),
                          let entry = Self.cacheEntry(
                            for: item, destination: indexed, byPath: byPath,
                            bySegment: bySegment, indexedParents: availablePaths
                          ) else { continue }
                    retained[item.session.id] = entry
                }
                comparisonCache.sources[comparisonKey] = retained
                try comparisonCache.save(in: destination)
            } catch {
                onSyncIssue("Could not save the comparison cache: \(error.localizedDescription)")
            }
        }

        return SessionTransferResult(
            sessionCount: selected.count + cached.count,
            copiedCount: indexedSessions.count { requestedIDs.contains($0.id) },
            pickerImportsCount: pickerImportsCount
        )
    }
}

extension SessionTransferService {
    struct SessionRecord: Decodable, Sendable, Equatable {
        let id: String
        let rolloutPath: String
        let name: String?

        enum CodingKeys: String, CodingKey {
            case id
            case rolloutPath = "rollout_path"
            case name
        }
    }

    enum DestinationDisposition: Equatable {
        case copy
        case replace
        case alreadyPresent
    }

    struct RolloutMetadata: Equatable {
        let threadID: String
        let sourceThreadID: String?
        var historyBaseThreadID: String? = nil
    }

    struct PreparedTransfer {
        let session: SessionRecord
        let sourceData: Data
        let destinationURL: URL
        var disposition: DestinationDisposition
        let sourceThreadID: String?
        var historyBaseThreadID: String? = nil
        var requiresIndex = false
        var destinationData: Data? = nil
        var sourceModificationDate: Date? = nil
        var comparisonStamps: [String: SyncComparisonCache.FileStamp] = [:]
    }

    static func recentSessions(for profile: CodexProfile, limit: Int) throws -> [SessionRecord] {
        let safeLimit = max(1, min(limit, 100))
        return try eligibleSessions(for: profile, limit: "LIMIT \(safeLimit)")
    }

    static func sessionsInSyncWindow(
        for profile: CodexProfile,
        now: Date,
        onSkippedSession: ((String) -> Void)? = nil
    ) throws -> [SessionRecord] {
        guard FileManager.default.fileExists(atPath: profile.homeURL.appending(path: "state_5.sqlite").path) else {
            return []
        }
        let cutoff = Int64(now.addingTimeInterval(-10 * 86_400).timeIntervalSince1970 * 1_000)
        let imports = Dictionary(try pickerImports(in: profile).map { ($0.forkID, $0.activityMilliseconds) }) { _, newest in newest }
        let sessions = try eligibleSessions(
            for: profile,
            activityFilter: "AND COALESCE(NULLIF(recency_at_ms, 0), updated_at_ms, updated_at * 1000) >= \(cutoff)"
        )
        return try sessions.compactMap { session in
            do {
                let resolved = try resolveDetachedMetadataRollout(session)
                guard let baseline = imports[session.id] else { return resolved }
                let data = try Data(contentsOf: URL(fileURLWithPath: resolved.rolloutPath))
                guard let date = try latestUserRequest(in: data),
                      Int64((date.timeIntervalSince1970 * 1_000).rounded()) > baseline else { return nil }
                return resolved
            } catch {
                guard let onSkippedSession else { throw error }
                onSkippedSession("\(session.name ?? session.id): \(error.localizedDescription)")
                return nil
            }
        }
    }

    private static func eligibleSessions(
        for profile: CodexProfile,
        activityFilter: String = "",
        limit: String = ""
    ) throws -> [SessionRecord] {
        let query = """
            SELECT id, rollout_path, name
            FROM threads
            WHERE archived = 0
              AND (preview <> '' OR first_user_message <> '' OR has_user_event = 1)
              AND agent_path IS NULL
              AND source NOT LIKE '{"subagent"%'
              \(activityFilter)
            ORDER BY COALESCE(NULLIF(recency_at_ms, 0), updated_at_ms, updated_at * 1000) DESC, id DESC
            \(limit);
            """
        return try querySessions(for: profile, query: query)
    }

    private static func pickerImportURL(in profile: CodexProfile) -> URL {
        profile.homeURL.appending(path: "codex-meter-picker-imports.json")
    }

    private static func pickerImports(in profile: CodexProfile) throws -> [PickerImport] {
        let url = pickerImportURL(in: profile)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([PickerImport].self, from: Data(contentsOf: url))
    }

    private static func sqlString(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private static func isDetachedMetadataRollout(_ url: URL, id: String) throws -> Bool {
        guard url.deletingPathExtension().lastPathComponent.contains("_"),
              let length = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              length <= 65_536 else { return false }
        let data = try Data(contentsOf: url)
        let metadata = try validateRollout(data, threadID: id)
        guard metadata.historyBaseThreadID == nil, metadata.sourceThreadID == nil else { return false }
        return try data.split(separator: 0x0A).allSatisfy { line in
            guard let record = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return false }
            return record["type"] as? String == "session_meta"
                || (record["type"] as? String == "event_msg"
                    && (record["payload"] as? [String: Any])?["type"] as? String == "thread_settings_applied")
        }
    }

    static func sameHistoryWithLocalSettings(_ source: Data, _ destination: Data) -> Bool {
        guard source.count == destination.count else { return false }
        let sourceLines = source.split(separator: 0x0A, omittingEmptySubsequences: false)
        let destinationLines = destination.split(separator: 0x0A, omittingEmptySubsequences: false)
        guard sourceLines.count == destinationLines.count else { return false }
        // Preserve the byte offsets and ordinal positions referenced by paginated forks.
        return zip(sourceLines, destinationLines).allSatisfy { sourceLine, destinationLine in
            sourceLine == destinationLine || (sourceLine.count == destinationLine.count
                && isLocalSettingsRecord(sourceLine) && isLocalSettingsRecord(destinationLine))
        }
    }

    private static func isLocalSettingsRecord(_ line: Data.SubSequence) -> Bool {
        guard let record = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              record["type"] as? String == "event_msg",
              let payload = record["payload"] as? [String: Any] else { return false }
        return payload["type"] as? String == "thread_settings_applied"
    }

    private static func resolveDetachedMetadataRollout(_ session: SessionRecord) throws -> SessionRecord {
        let path = URL(fileURLWithPath: session.rolloutPath)
        guard try isDetachedMetadataRollout(path, id: session.id) else { return session }
        let siblings = try FileManager.default.contentsOfDirectory(
            at: path.deletingLastPathComponent(), includingPropertiesForKeys: nil
        )
        let roots = siblings.filter { $0.lastPathComponent.hasSuffix("-\(session.id).jsonl") }
        guard roots.count == 1, let root = roots.first else {
            throw SessionTransferError.missingLineageSource(threadID: session.id, sourceThreadID: session.id)
        }
        let data = try Data(contentsOf: root)
        try validateRollout(data, threadID: session.id)
        guard try latestUserRequest(in: data) != nil else {
            throw SessionTransferError.invalidQueryResponse("Missing user history in \(root.lastPathComponent).")
        }
        return SessionRecord(id: session.id, rolloutPath: root.path, name: session.name)
    }

    private static func repairDetachedIndexPaths(
        _ paths: [String: String],
        using selected: [PreparedTransfer],
        in profile: CodexProfile
    ) throws {
        guard !paths.isEmpty else { return }
        var updates: [String] = []
        for item in selected {
            guard let path = paths[item.session.id] else { continue }
            let old = URL(fileURLWithPath: path)
            guard try isDetachedMetadataRollout(old, id: item.session.id) else {
                throw SessionTransferError.copyFailed(threadID: item.session.id, reason: "Destination history changed during repair.")
            }
            updates.append("""
                UPDATE threads SET rollout_path = '\(sqlString(item.destinationURL.path))'
                WHERE id = '\(sqlString(item.session.id))' AND rollout_path = '\(sqlString(path))';
                """)
        }
        _ = try SQLiteQueryRunner.query(
            databaseURL: profile.homeURL.appending(path: "state_5.sqlite"),
            sql: (["PRAGMA busy_timeout = 5000;", "BEGIN IMMEDIATE;"] + updates + ["COMMIT;"]).joined(separator: "\n")
        )
    }

    static func allSessions(for profile: CodexProfile) throws -> [SessionRecord] {
        try querySessions(
            for: profile,
            query: "SELECT id, rollout_path, name FROM threads;"
        )
    }

    static func visibleSessionIDs(in profile: CodexProfile) throws -> Set<String> {
        let database = profile.homeURL.appending(path: "state_5.sqlite")
        guard FileManager.default.fileExists(atPath: database.path) else { return [] }
        struct VisibleSession: Decodable {
            let id: String
        }
        let output = try SQLiteQueryRunner.query(
            databaseURL: database,
            sql: "SELECT id FROM threads WHERE preview <> '';",
            outputJSON: true
        )
        return Set(try JSONDecoder().decode([VisibleSession].self, from: output).map(\.id))
    }

    static func restoreIndexedRecency(
        for sessions: [SessionRecord],
        in profile: CodexProfile,
        inheritedActivity: [String: Int64] = [:]
    ) throws {
        guard !sessions.isEmpty else { return }
        struct IndexedSession: Decodable {
            let id: String
            let path: String
            let updatedAt: Int64
        }
        let database = profile.homeURL.appending(path: "state_5.sqlite")
        let output = try SQLiteQueryRunner.query(
            databaseURL: database,
            sql: """
                SELECT id, rollout_path AS path,
                       COALESCE(updated_at_ms, updated_at * 1000) AS updatedAt
                FROM threads;
                """,
            outputJSON: true
        )
        let indexed = try JSONDecoder().decode([IndexedSession].self, from: output)
        let rowsByID = Dictionary(uniqueKeysWithValues: indexed.map { ($0.id, $0) })
        let profileRoot = profile.homeURL.resolvingSymlinksInPath().standardizedFileURL.path
        var updates: [String] = []
        for session in sessions {
            guard let row = rowsByID[session.id] else {
                throw SessionTransferError.invalidQueryResponse("Missing destination index row for \(session.id).")
            }
            let rollout = URL(fileURLWithPath: row.path).resolvingSymlinksInPath().standardizedFileURL
            guard rollout.path.hasPrefix(profileRoot + "/") else {
                throw SessionTransferError.rolloutOutsideProfile(threadID: session.id, path: row.path)
            }
            let before = try rollout.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let data = try Data(contentsOf: rollout)
            try validateRollout(data, threadID: session.id)
            let inheritedDate = inheritedActivity[session.id].map {
                Date(timeIntervalSince1970: Double($0) / 1_000)
            }
            let date = [try latestUserRequest(in: data), inheritedDate].compactMap { $0 }.max()
            guard let date else { continue }
            let after = try rollout.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard before.contentModificationDate == after.contentModificationDate,
                  before.fileSize == after.fileSize else { continue }
            // Codex's rollout scan can use file mtime instead of the SQLite timestamp.
            if let modificationDate = after.contentModificationDate,
               abs(modificationDate.timeIntervalSince(date)) >= 0.001 {
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: rollout.path)
            }
            let milliseconds = Int64((date.timeIntervalSince1970 * 1_000).rounded())
            let seconds = milliseconds / 1_000
            let id = sqlString(session.id)
            let path = sqlString(row.path)
            // Preserve any concurrent change to the destination's indexed activity.
            updates.append("""
                UPDATE threads
                SET updated_at = \(seconds), updated_at_ms = \(milliseconds),
                    recency_at = \(seconds), recency_at_ms = \(milliseconds)
                WHERE id = '\(id)' AND rollout_path = '\(path)'
                    AND COALESCE(updated_at_ms, updated_at * 1000) = \(row.updatedAt);
                """)
        }
        guard !updates.isEmpty else { return }
        _ = try SQLiteQueryRunner.query(
            databaseURL: database,
            sql: (["PRAGMA busy_timeout = 5000;", "BEGIN IMMEDIATE;"] + updates + ["COMMIT;"])
                .joined(separator: "\n")
        )
    }

    private static func querySessions(
        for profile: CodexProfile,
        query: String
    ) throws -> [SessionRecord] {
        let databaseURL = profile.homeURL.appending(path: "state_5.sqlite")
        let output = try SQLiteQueryRunner.query(
            databaseURL: databaseURL,
            sql: query,
            outputJSON: true
        )

        do {
            return try JSONDecoder().decode([SessionRecord].self, from: output)
        } catch {
            throw SessionTransferError.invalidQueryResponse(error.localizedDescription)
        }
    }

    private static func cacheIndexedRollouts(in profile: CodexProfile) throws -> [String: SyncComparisonCache.IndexedRollout] {
        let database = profile.homeURL.appending(path: "state_5.sqlite")
        guard FileManager.default.fileExists(atPath: database.path) else { return [:] }
        struct Row: Decodable {
            let id: String
            let path: String
            let updated: Int64
            let recency: Int64
        }
        let data = try SQLiteQueryRunner.query(
            databaseURL: database,
            sql: """
                SELECT id, rollout_path AS path, COALESCE(updated_at_ms, updated_at * 1000) AS updated,
                       recency_at_ms AS recency
                FROM threads WHERE archived = 0 AND preview <> '';
                """,
            outputJSON: true
        )
        let rows = try JSONDecoder().decode([Row].self, from: data)
        return Dictionary(uniqueKeysWithValues: rows.map {
            ($0.id, SyncComparisonCache.IndexedRollout(path: $0.path, updated: $0.updated, recency: $0.recency))
        })
    }

    private static func segmentIdentifier(for path: String) -> String {
        String(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.suffix(36))
    }

    private static func cacheSegmentPaths(_ ids: Set<String>, in profile: CodexProfile) throws -> [String: [String]] {
        var paths: [String: [String]] = [:]
        for url in try sourceRolloutURLs(in: profile) {
            let id = segmentIdentifier(for: url.path)
            if ids.contains(id) { paths[id, default: []].append(url.path) }
        }
        return paths
    }

    private static func cacheEntry(
        for root: PreparedTransfer,
        destination: SyncComparisonCache.IndexedRollout,
        byPath: [String: PreparedTransfer],
        bySegment: [String: [PreparedTransfer]],
        indexedParents: [String: String]
    ) -> SyncComparisonCache.Entry? {
        var files: [String: SyncComparisonCache.FileStamp] = [:]
        var parents: [String: String] = [:]
        var segments: [String: String] = [:]
        var visited: Set<String> = []
        var current = root
        while true {
            guard visited.insert(current.session.rolloutPath).inserted,
                  current.disposition == .alreadyPresent, !current.requiresIndex,
                  current.comparisonStamps.count == 2 else { return nil }
            for (path, stamp) in current.comparisonStamps {
                guard SyncComparisonCache.FileStamp.read(path) == stamp else { return nil }
                files[path] = stamp
            }
            if let id = current.historyBaseThreadID {
                guard let matches = bySegment[id], matches.count == 1, let parent = matches.first else { return nil }
                segments[id] = parent.session.rolloutPath
                current = parent
            } else if let id = current.sourceThreadID {
                guard let path = indexedParents[id], let parent = byPath[path] else { return nil }
                parents[id] = path
                current = parent
            } else {
                return SyncComparisonCache.Entry(
                    sourcePath: root.session.rolloutPath, destination: destination,
                    files: files, indexedParents: parents, historySegments: segments
                )
            }
        }
    }

    static func prepareTransferClosure(
        selected: [SessionRecord],
        available: [SessionRecord],
        from source: CodexProfile,
        to destination: CodexProfile,
        validate: (inout PreparedTransfer) throws -> Void = { _ in },
        onSkippedSession: ((String) -> Void)? = nil,
        captureStamps: Bool = false
    ) throws -> [PreparedTransfer] {
        let recordsByID = Dictionary((available + selected).map { ($0.id, $0) }) { _, selected in selected }
        var preparedByPath: [String: PreparedTransfer] = [:]
        var visiting: Set<String> = []
        var ordered: [PreparedTransfer] = []

        var rolloutURLs: [URL]?

        func historySegment(_ identifier: String, for session: SessionRecord) throws -> SessionRecord {
            if rolloutURLs == nil {
                rolloutURLs = try sourceRolloutURLs(in: source)
            }
            let matches = (rolloutURLs ?? []).filter {
                let name = $0.lastPathComponent
                return name.hasSuffix("-\(identifier).jsonl") || name.hasSuffix("_\(identifier).jsonl")
            }
            guard matches.count <= 1 else {
                throw SessionTransferError.ambiguousLineageSource(identifier)
            }
            guard let url = matches.first else {
                throw SessionTransferError.missingLineageSource(
                    threadID: session.id, sourceThreadID: identifier
                )
            }
            let data = try Data(contentsOf: url)
            guard let firstLine = data.split(separator: 0x0A).first,
                  let object = try JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any],
                  let threadID = payload["id"] as? String else {
                throw SessionTransferError.mismatchedThreadIdentifier(expected: identifier)
            }
            return SessionRecord(id: threadID, rolloutPath: url.path, name: recordsByID[threadID]?.name)
        }

        @discardableResult
        func prepareWithAncestors(_ session: SessionRecord) throws -> Bool {
            let path = URL(fileURLWithPath: session.rolloutPath).standardizedFileURL.path
            if let cached = preparedByPath[path] { return cached.requiresIndex }
            guard visiting.insert(path).inserted else {
                throw SessionTransferError.lineageCycle(threadID: session.id)
            }
            defer { visiting.remove(path) }

            var transfer = try prepareTransfer(session, from: source, to: destination, captureStamps: captureStamps)
            try validate(&transfer)
            transfer.requiresIndex = transfer.disposition != .alreadyPresent
            if let segmentID = transfer.historyBaseThreadID {
                let segment = try historySegment(segmentID, for: session)
                let dependencyChanged = try prepareWithAncestors(segment)
                transfer.requiresIndex = transfer.requiresIndex || dependencyChanged
            } else if let sourceThreadID = transfer.sourceThreadID {
                guard let sourceSession = recordsByID[sourceThreadID] else {
                    throw SessionTransferError.missingLineageSource(
                        threadID: session.id,
                        sourceThreadID: sourceThreadID
                    )
                }
                let dependencyChanged = try prepareWithAncestors(sourceSession)
                transfer.requiresIndex = transfer.requiresIndex || dependencyChanged
            }

            preparedByPath[path] = transfer
            ordered.append(transfer)
            return transfer.requiresIndex
        }

        for session in selected {
            do {
                try prepareWithAncestors(session)
            } catch {
                guard let onSkippedSession else { throw error }
                onSkippedSession("\(session.name ?? session.id): \(error.localizedDescription)")
            }
        }
        return ordered
    }

    static func sessionsRequiringIndex(_ prepared: [PreparedTransfer]) -> [SessionRecord] {
        var seen: Set<String> = []
        return prepared.reversed().compactMap { transfer in
            guard transfer.requiresIndex, seen.insert(transfer.session.id).inserted else { return nil }
            return transfer.session
        }.reversed()
    }

    private static func sourceRolloutURLs(in profile: CodexProfile) throws -> [URL] {
        var urls: [URL] = []
        for folder in ["sessions", "archived_sessions"] {
            let root = profile.homeURL.appending(path: folder)
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            var enumerationError: Error?
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, error in enumerationError = error; return false }
            ) else {
                throw SessionTransferError.unreadableRollout(threadID: root.path, reason: "Cannot enumerate rollouts.")
            }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    urls.append(url)
                }
            }
            if let enumerationError { throw enumerationError }
        }
        return urls
    }

    static func prepareTransfer(
        _ session: SessionRecord,
        from source: CodexProfile,
        to destination: CodexProfile,
        captureStamps: Bool = false
    ) throws -> PreparedTransfer {
        let sourceURL = URL(fileURLWithPath: session.rolloutPath).standardizedFileURL
        let sourceRoot = source.homeURL.standardizedFileURL
        guard sourceURL.path.hasPrefix(sourceRoot.path + "/") else {
            throw SessionTransferError.rolloutOutsideProfile(
                threadID: session.id,
                path: sourceURL.path
            )
        }

        let relativePath = String(sourceURL.path.dropFirst(sourceRoot.path.count + 1))
        let destinationURL = destination.homeURL.appending(path: relativePath).standardizedFileURL
        var stamps: [String: SyncComparisonCache.FileStamp] = [:]
        if captureStamps {
            if let stamp = SyncComparisonCache.FileStamp.read(session.rolloutPath) {
                stamps[session.rolloutPath] = stamp
            }
            if let stamp = SyncComparisonCache.FileStamp.read(destinationURL.path) {
                stamps[destinationURL.path] = stamp
            }
        }
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            throw SessionTransferError.unreadableRollout(
                threadID: session.id,
                reason: error.localizedDescription
            )
        }

        let metadata = try validateRollout(data, threadID: session.id)
        let destinationData = FileManager.default.fileExists(atPath: destinationURL.path)
            ? try Data(contentsOf: destinationURL) : nil
        let disposition = try destinationDisposition(
            sourceData: data, destinationData: destinationData, threadID: session.id
        )
        return PreparedTransfer(
            session: session,
            sourceData: data,
            destinationURL: destinationURL,
            disposition: disposition,
            sourceThreadID: metadata.sourceThreadID,
            historyBaseThreadID: metadata.historyBaseThreadID,
            destinationData: destinationData,
            sourceModificationDate: try sourceURL.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate,
            comparisonStamps: stamps
        )
    }

    @discardableResult
    static func validateRollout(_ data: Data, threadID: String) throws -> RolloutMetadata {
        guard data.isEmpty == false, data.last == 0x0A else {
            throw SessionTransferError.incompleteRollout(threadID: threadID)
        }

        var metadata: RolloutMetadata?
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        for (index, line) in lines.enumerated() {
            let object: Any
            do {
                object = try JSONSerialization.jsonObject(with: Data(line))
            } catch {
                throw SessionTransferError.invalidRollout(threadID: threadID, line: index + 1)
            }

            guard
                let dictionary = object as? [String: Any],
                dictionary["type"] as? String == "session_meta",
                let payload = dictionary["payload"] as? [String: Any]
            else {
                continue
            }
            guard let metadataThreadID = payload["id"] as? String,
                  metadataThreadID == threadID else {
                throw SessionTransferError.mismatchedThreadIdentifier(expected: threadID)
            }
            if metadata == nil {
                var historyBaseThreadID: String?
                if let historyBase = payload["history_base"], !(historyBase is NSNull) {
                    guard let base = historyBase as? [String: Any],
                          let identifier = base["thread_id"] as? String,
                          identifier.isEmpty == false else {
                        throw SessionTransferError.invalidHistoryBase(threadID)
                    }
                    historyBaseThreadID = identifier
                }
                metadata = RolloutMetadata(
                    threadID: metadataThreadID,
                    sourceThreadID: payload["forked_from_id"] as? String,
                    historyBaseThreadID: historyBaseThreadID
                )
            }
        }

        guard let metadata else {
            throw SessionTransferError.mismatchedThreadIdentifier(expected: threadID)
        }
        return metadata
    }

    static func destinationDisposition(
        sourceData: Data,
        destinationData: Data?,
        threadID: String
    ) throws -> DestinationDisposition {
        guard let destinationData else { return .copy }
        guard sourceData != destinationData else { return .alreadyPresent }
        try validateRollout(destinationData, threadID: threadID)
        if sourceData.starts(with: destinationData) { return .replace }
        if destinationData.starts(with: sourceData) { return .alreadyPresent }
        let sourceDate = try latestUserRequest(in: sourceData)
        let destinationDate = try latestUserRequest(in: destinationData)
        if let sourceDate, destinationDate == nil || sourceDate > destinationDate! {
            return .replace
        }
        return .alreadyPresent
    }

    private static func latestUserRequest(in data: Data) throws -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        var latest: Date?
        for line in data.split(separator: 0x0A) {
            guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { continue }
            let isUserEvent = object["type"] as? String == "event_msg"
                && payload["type"] as? String == "user_message"
            let isUserMessage = object["type"] as? String == "response_item"
                && payload["type"] as? String == "message"
                && payload["role"] as? String == "user"
            guard isUserEvent || isUserMessage else { continue }
            guard let timestamp = object["timestamp"] as? String else { continue }
            guard let date = fractional.date(from: timestamp) ?? standard.date(from: timestamp) else {
                throw ActivityReaderError.invalidTimestamp(timestamp)
            }
            if latest == nil || date > latest! { latest = date }
        }
        return latest
    }

    static func commit(_ prepared: [PreparedTransfer]) throws -> Int {
        var committed: [PreparedTransfer] = []
        do {
            for transfer in prepared where transfer.disposition != .alreadyPresent {
                let directoryURL = transfer.destinationURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )

                let temporaryURL = directoryURL.appending(
                    path: ".\(transfer.destinationURL.lastPathComponent).\(UUID().uuidString).tmp"
                )
                do {
                    try transfer.sourceData.write(to: temporaryURL, options: .withoutOverwriting)
                    if let modificationDate = transfer.sourceModificationDate {
                        try FileManager.default.setAttributes(
                            [.modificationDate: modificationDate],
                            ofItemAtPath: temporaryURL.path
                        )
                    }
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: temporaryURL.path
                    )
                    if transfer.disposition == .replace {
                        guard try Data(contentsOf: transfer.destinationURL) == transfer.destinationData else {
                            throw SessionTransferError.copyFailed(
                                threadID: transfer.session.id,
                                reason: "Destination changed during transfer. Retry the transfer."
                            )
                        }
                        guard Darwin.rename(temporaryURL.path, transfer.destinationURL.path) == 0 else {
                            throw SessionTransferError.copyFailed(
                                threadID: transfer.session.id, reason: String(cString: strerror(errno))
                            )
                        }
                    } else {
                        try FileManager.default.moveItem(at: temporaryURL, to: transfer.destinationURL)
                    }
                    committed.append(transfer)
                } catch {
                    try? FileManager.default.removeItem(at: temporaryURL)
                    throw SessionTransferError.copyFailed(
                        threadID: transfer.session.id,
                        reason: error.localizedDescription
                    )
                }
            }
        } catch {
            for transfer in committed.reversed() {
                do {
                    if let original = transfer.destinationData {
                        try original.write(to: transfer.destinationURL, options: .atomic)
                    } else {
                        try FileManager.default.removeItem(at: transfer.destinationURL)
                    }
                } catch {
                    throw SessionTransferError.copyFailed(
                        threadID: transfer.session.id,
                        reason: "Transfer rollback failed: \(error.localizedDescription)"
                    )
                }
            }
            throw error
        }
        return committed.count
    }
}

private extension SessionTransferService {
    func ensurePickerVisibility(
        for sessions: [SessionRecord],
        in profile: CodexProfile,
        onIssue: ((String) -> Void)?
    ) throws -> Int {
        guard !sessions.isEmpty else { return 0 }
        let rpc = try AppServerRPC(executableURL: codexExecutableURL, profileHomeURL: profile.homeURL, timeout: timeout)
        defer { rpc.close() }
        try initialize(rpc)
        var imports = try Self.pickerImports(in: profile)
        let accountVisible = try pickerVisibleIDs(sessions.map(\.id) + imports.map(\.forkID), with: rpc)
        let missing = sessions.filter { !accountVisible.contains($0.id) }
        guard !missing.isEmpty else { return 0 }
        let generallyVisible = try pickerVisibleIDs(missing.map(\.id), with: rpc, currentAccountOnly: false)

        struct IndexedActivity: Decodable {
            let id: String
            let activity: Int64
            let cwd: String
        }
        let database = profile.homeURL.appending(path: "state_5.sqlite")
        let ids = missing.map { "'\(Self.sqlString($0.id))'" }.joined(separator: ",")
        let data = try SQLiteQueryRunner.query(
            databaseURL: database,
            sql: """
                SELECT id, cwd, COALESCE(NULLIF(recency_at_ms, 0), updated_at_ms, updated_at * 1000) AS activity
                FROM threads WHERE id IN (\(ids)) AND archived = 0;
                """,
            outputJSON: true
        )
        let activities = try JSONDecoder().decode([IndexedActivity].self, from: data)
        let activityByID = Dictionary(uniqueKeysWithValues: activities.map { ($0.id, $0) })
        var imported = 0
        for session in missing {
            do {
                guard generallyVisible.contains(session.id) else {
                    throw SessionTransferError.appServerFailed("Conversation \(session.id) is ineligible for /resume.")
                }
                guard let record = activityByID[session.id] else {
                    throw SessionTransferError.invalidQueryResponse("Missing active session \(session.id).")
                }
                let activity = record.activity
                let forkID: String
                var created = false
                if let existing = imports.last(where: {
                    $0.sourceID == session.id && $0.activityMilliseconds == activity && accountVisible.contains($0.forkID)
                }) {
                    forkID = existing.forkID
                } else {
                    let response = try rpc.call(method: "thread/fork", params: [
                        "threadId": session.id,
                        "excludeTurns": true,
                        "cwd": record.cwd,
                    ])
                    guard let thread = response["thread"] as? [String: Any],
                          let id = thread["id"] as? String else {
                        throw SessionTransferError.appServerFailed("thread/fork did not return a conversation ID.")
                    }
                    forkID = id
                    created = true
                    imports.append(PickerImport(sourceID: session.id, forkID: forkID, activityMilliseconds: activity))
                    let checkpoint = try JSONEncoder().encode(imports)
                    try checkpoint.write(to: Self.pickerImportURL(in: profile), options: .atomic)
                    if let name = session.name, !name.isEmpty {
                        _ = try rpc.call(method: "thread/name/set", params: ["threadId": forkID, "name": name])
                    }
                }
                let fork = SessionRecord(id: forkID, rolloutPath: "", name: session.name)
                try Self.restoreIndexedRecency(for: [fork], in: profile, inheritedActivity: [forkID: activity])
                guard try pickerVisibleIDs([forkID], with: rpc).contains(forkID) else {
                    throw SessionTransferError.appServerFailed("Conversation \(forkID) is missing from this account's /resume list.")
                }
                if created { imported += 1 }
            } catch {
                guard let onIssue else { throw error }
                onIssue("\(session.name ?? session.id): \(error.localizedDescription)")
            }
        }
        return imported
    }

    func pickerVisibleIDs(
        _ ids: [String],
        with rpc: AppServerRPC,
        currentAccountOnly: Bool = true
    ) throws -> Set<String> {
        var visible: Set<String> = []
        for offset in stride(from: 0, to: ids.count, by: 100) {
            let batch = Array(ids[offset..<min(offset + 100, ids.count)])
            let result = try rpc.call(method: "thread/list", params: [
                "includedThreadIds": batch,
                "currentAccountOnly": currentAccountOnly,
                "archived": false,
                "limit": batch.count,
                "useStateDbOnly": true,
            ])
            guard let rows = result["data"] as? [[String: Any]] else {
                throw SessionTransferError.appServerFailed("thread/list did not return a conversation list.")
            }
            visible.formUnion(rows.compactMap { $0["id"] as? String })
        }
        return visible
    }

    func index(
        sessions: [SessionRecord],
        in profile: CodexProfile,
        onIssue: ((String) -> Void)?
    ) throws -> [SessionRecord] {
        guard FileManager.default.isExecutableFile(atPath: codexExecutableURL.path) else {
            throw SessionTransferError.missingCodexExecutable(codexExecutableURL)
        }

        let rpc = try AppServerRPC(
            executableURL: codexExecutableURL,
            profileHomeURL: profile.homeURL,
            timeout: timeout
        )
        defer { rpc.close() }
        try initialize(rpc)

        var indexed: [SessionRecord] = []
        for session in sessions {
            do {
                try index(session: session, with: rpc)
                indexed.append(session)
            } catch {
                guard let onIssue else { throw error }
                onIssue("\(session.name ?? session.id): \(error.localizedDescription)")
            }
        }
        return indexed
    }

    func initialize(_ rpc: AppServerRPC) throws {
        _ = try rpc.call(
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "codex_meter",
                    "title": "CodexMeter",
                    "version": "0.1.0",
                ],
            ]
        )
        try rpc.notify(method: "initialized", params: [:])
    }

    func index(session: SessionRecord, with rpc: AppServerRPC) throws {
        let resumed = try rpc.call(
            method: "thread/resume",
            params: [
                "threadId": session.id,
                "excludeTurns": true,
            ]
        )

        if let thread = resumed["thread"] as? [String: Any], thread["historyMode"] as? String == "paginated" {
            _ = try rpc.call(method: "thread/items/list", params: ["threadId": session.id, "limit": 1])
        }

        if let name = session.name, name.isEmpty == false {
            _ = try rpc.call(
                method: "thread/name/set",
                params: ["threadId": session.id, "name": name]
            )
        }
    }
}

private final class AppServerRPC {
    private let process: Process
    private let inputHandle: FileHandle
    private let outputHandle: FileHandle
    private let errorHandle: FileHandle
    private let timeout: TimeInterval
    private var nextIdentifier = 0
    private var buffer = Data()

    init(executableURL: URL, profileHomeURL: URL, timeout: TimeInterval) throws {
        self.timeout = timeout
        process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        inputHandle = inputPipe.fileHandleForWriting
        outputHandle = outputPipe.fileHandleForReading
        errorHandle = errorPipe.fileHandleForReading

        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["CODEX_HOME": profileHomeURL.path],
            uniquingKeysWith: { _, profileValue in profileValue }
        )
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw SessionTransferError.appServerFailed(error.localizedDescription)
        }
    }

    func call(method: String, params: [String: Any]) throws -> [String: Any] {
        nextIdentifier += 1
        let identifier = nextIdentifier
        try write(["method": method, "id": identifier, "params": params])

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard line.isEmpty == false else { continue }
                guard let object = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    continue
                }
                guard (object["id"] as? Int) == identifier else { continue }

                if let error = object["error"] as? [String: Any] {
                    let message = error["message"] as? String ?? String(describing: error)
                    throw SessionTransferError.appServerFailed(message)
                }
                guard let result = object["result"] as? [String: Any] else {
                    throw SessionTransferError.appServerFailed("\(method) returned no result object.")
                }
                return result
            }

            var descriptor = pollfd(
                fd: outputHandle.fileDescriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let remainingMilliseconds = max(1, Int32(deadline.timeIntervalSinceNow * 1_000))
            let pollResult = Darwin.poll(&descriptor, 1, remainingMilliseconds)
            if pollResult < 0 {
                throw SessionTransferError.appServerFailed(String(cString: strerror(errno)))
            }
            if pollResult == 0 {
                throw SessionTransferError.appServerTimedOut(timeout)
            }
            if descriptor.revents & Int16(POLLIN | POLLHUP) != 0 {
                let chunk = try PipeReader.readAvailableBytes(
                    from: outputHandle.fileDescriptor,
                    maximumCount: 65_536
                )
                guard chunk.isEmpty == false else {
                    throw exitedError()
                }
                buffer.append(chunk)
            }
        }
        throw SessionTransferError.appServerTimedOut(timeout)
    }

    func notify(method: String, params: [String: Any]) throws {
        try write(["method": method, "params": params])
    }

    func close() {
        try? inputHandle.close()
        if process.isRunning {
            process.terminate()
        }
    }

    private func write(_ object: [String: Any]) throws {
        do {
            let data = try JSONSerialization.data(withJSONObject: object) + Data([0x0A])
            try inputHandle.write(contentsOf: data)
        } catch {
            throw SessionTransferError.appServerFailed("Could not write request: \(error.localizedDescription)")
        }
    }

    private func exitedError() -> SessionTransferError {
        var descriptor = pollfd(
            fd: errorHandle.fileDescriptor,
            events: Int16(POLLIN),
            revents: 0
        )
        let stderr: String
        if Darwin.poll(&descriptor, 1, 0) > 0,
           descriptor.revents & Int16(POLLIN) != 0,
           let data = try? PipeReader.readAvailableBytes(
               from: errorHandle.fileDescriptor,
               maximumCount: 65_536
           ) {
            stderr = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            stderr = ""
        }
        return .appServerFailed(stderr.isEmpty ? "The process exited before replying." : stderr)
    }
}
