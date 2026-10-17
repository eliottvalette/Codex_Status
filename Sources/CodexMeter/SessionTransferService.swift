import Darwin
import Foundation

struct SessionTransferResult: Sendable, Equatable {
    let sessionCount: Int
    let copiedCount: Int

    var alreadyPresentCount: Int {
        sessionCount - copiedCount
    }
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

        let availableSessions = try Self.allSessions(for: source)
        let prepared = try Self.prepareTransferClosure(
            selected: sessions,
            available: availableSessions,
            from: source,
            to: destination
        )
        let selectedPaths = Set(sessions.map(\.rolloutPath))
        let copiedCount = prepared.count {
            selectedPaths.contains($0.session.rolloutPath) && $0.requiresIndex
        }
        let copiedSessions = Self.sessionsRequiringIndex(prepared)
        _ = try Self.commit(prepared)

        if copiedSessions.isEmpty == false {
            do {
                try index(sessions: copiedSessions, in: destination)
            } catch {
                throw SessionTransferError.indexingFailed(
                    profile: destination.displayName,
                    copiedCount: copiedCount,
                    reason: error.localizedDescription
                )
            }
        }

        return SessionTransferResult(sessionCount: sessions.count, copiedCount: copiedCount)
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
        let disposition: DestinationDisposition
        let sourceThreadID: String?
        var historyBaseThreadID: String? = nil
        var requiresIndex = false
        var destinationData: Data? = nil
    }

    static func recentSessions(for profile: CodexProfile, limit: Int) throws -> [SessionRecord] {
        let safeLimit = max(1, min(limit, 100))
        let query = """
            SELECT id, rollout_path, name
            FROM threads
            WHERE archived = 0
              AND preview <> ''
              AND agent_path IS NULL
              AND source NOT LIKE '{"subagent"%'
            ORDER BY COALESCE(NULLIF(recency_at_ms, 0), updated_at_ms, updated_at * 1000) DESC, id DESC
            LIMIT \(safeLimit);
            """
        return try querySessions(for: profile, query: query)
    }

    static func allSessions(for profile: CodexProfile) throws -> [SessionRecord] {
        try querySessions(
            for: profile,
            query: "SELECT id, rollout_path, name FROM threads;"
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

    static func prepareTransferClosure(
        selected: [SessionRecord],
        available: [SessionRecord],
        from source: CodexProfile,
        to destination: CodexProfile
    ) throws -> [PreparedTransfer] {
        let recordsByID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
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

            var transfer = try prepareTransfer(session, from: source, to: destination)
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
            try prepareWithAncestors(session)
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
        to destination: CodexProfile
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
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
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
            destinationData: destinationData
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
        try validateRollout(destinationData, threadID: threadID)
        guard sourceData != destinationData else { return .alreadyPresent }
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
    func index(sessions: [SessionRecord], in profile: CodexProfile) throws {
        guard FileManager.default.isExecutableFile(atPath: codexExecutableURL.path) else {
            throw SessionTransferError.missingCodexExecutable(codexExecutableURL)
        }

        let rpc = try AppServerRPC(
            executableURL: codexExecutableURL,
            profileHomeURL: profile.homeURL,
            timeout: timeout
        )
        defer { rpc.close() }

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

        for session in sessions {
            _ = try rpc.call(
                method: "thread/resume",
                params: [
                    "threadId": session.id,
                    "excludeTurns": true,
                    "sandbox": "read-only",
                    "approvalPolicy": "never",
                ]
            )

            var cursor: String?
            repeat {
                var params: [String: Any] = [
                    "threadId": session.id,
                    "limit": 100,
                ]
                if let cursor {
                    params["cursor"] = cursor
                }
                let result = try rpc.call(method: "thread/items/list", params: params)
                cursor = result["nextCursor"] as? String
            } while cursor != nil

            if let name = session.name, name.isEmpty == false {
                _ = try rpc.call(
                    method: "thread/name/set",
                    params: ["threadId": session.id, "name": name]
                )
            }
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
