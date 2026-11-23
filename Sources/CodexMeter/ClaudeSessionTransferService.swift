import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

enum ClaudeSessionTransferError: Error, Equatable, LocalizedError {
    case sameProfile
    case noEligibleSessions(String)
    case unreadableTranscript(sessionID: String, reason: String)
    case incompleteTranscript(sessionID: String)
    case invalidTranscript(sessionID: String, line: Int)
    case copyFailed(sessionID: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .sameProfile:
            "Source and destination profiles must be different."
        case let .noEligibleSessions(profile):
            "No transferable conversation was found for \(profile)."
        case let .unreadableTranscript(sessionID, reason):
            "Could not read conversation \(sessionID): \(reason)"
        case let .incompleteTranscript(sessionID):
            "Conversation \(sessionID) ends with an incomplete JSONL record."
        case let .invalidTranscript(sessionID, line):
            "Conversation \(sessionID) contains invalid JSON on line \(line)."
        case let .copyFailed(sessionID, reason):
            "Could not copy conversation \(sessionID): \(reason)"
        }
    }
}

/// Copies recent Claude Code conversations between configuration directories.
///
/// A conversation is one transcript at `projects/<project>/<session-id>.jsonl`. Claude Code
/// finds conversations by reading that folder, so a copy at the same relative path is all
/// `/resume` needs.
struct ClaudeSessionTransferService: Sendable {
    @concurrent
    func transferRecentSessions(
        from source: CodexProfile,
        to destination: CodexProfile,
        limit: Int = 3
    ) async throws -> SessionTransferResult {
        guard source.id != destination.id else {
            throw ClaudeSessionTransferError.sameProfile
        }

        let sessions = try Self.recentSessions(in: source, limit: limit)
        guard sessions.isEmpty == false else {
            throw ClaudeSessionTransferError.noEligibleSessions(source.displayName)
        }

        let prepared = try sessions.map { try Self.prepareTransfer($0, to: destination) }
        let copiedCount = try Self.commit(prepared)
        return SessionTransferResult(sessionCount: sessions.count, copiedCount: copiedCount)
    }
}

extension ClaudeSessionTransferService {
    struct TranscriptFile: Equatable, Sendable {
        let sessionID: String
        let projectDirectoryName: String
        let url: URL
        let modifiedAt: Date
    }

    struct SessionRecord: Equatable, Sendable {
        let file: TranscriptFile
        let data: Data
        let lastUserMessageAt: Date
    }

    enum DestinationDisposition: Equatable {
        case copy
        case replace
        case alreadyPresent
    }

    struct PreparedTransfer {
        let session: SessionRecord
        let destinationURL: URL
        let disposition: DestinationDisposition
        let destinationData: Data?
    }

    /// Every conversation transcript of a profile. Subagent transcripts are left out: they
    /// sit one level deeper, or carry an `agent-` prefix in older versions.
    static func transcriptFiles(in profile: CodexProfile) throws -> [TranscriptFile] {
        let fileManager = FileManager.default
        let projectsURL = profile.homeURL.appending(path: "projects")
        guard fileManager.fileExists(atPath: projectsURL.path) else { return [] }

        var files: [TranscriptFile] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        for projectURL in try fileManager.contentsOfDirectory(
            at: projectsURL, includingPropertiesForKeys: [.isDirectoryKey]
        ) where try projectURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            for url in try fileManager.contentsOfDirectory(
                at: projectURL, includingPropertiesForKeys: keys
            ) where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("agent-") == false {
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true, let modifiedAt = values.contentModificationDate else {
                    continue
                }
                files.append(TranscriptFile(
                    sessionID: url.deletingPathExtension().lastPathComponent,
                    projectDirectoryName: projectURL.lastPathComponent,
                    url: url,
                    modifiedAt: modifiedAt
                ))
            }
        }
        return files
    }

    /// The most recently changed conversations that contain a message from the user.
    static func recentSessions(in profile: CodexProfile, limit: Int) throws -> [SessionRecord] {
        let safeLimit = max(1, min(limit, 100))
        let files = try transcriptFiles(in: profile).sorted {
            $0.modifiedAt != $1.modifiedAt ? $0.modifiedAt > $1.modifiedAt : $0.url.path < $1.url.path
        }

        var sessions: [SessionRecord] = []
        for file in files {
            let data: Data
            do {
                data = try Data(contentsOf: file.url)
            } catch {
                throw ClaudeSessionTransferError.unreadableTranscript(
                    sessionID: file.sessionID, reason: error.localizedDescription
                )
            }
            // An empty transcript is a conversation that never started.
            guard data.isEmpty == false,
                  let lastUserMessageAt = try latestUserMessage(in: data, sessionID: file.sessionID)
            else {
                continue
            }
            sessions.append(SessionRecord(file: file, data: data, lastUserMessageAt: lastUserMessageAt))
            if sessions.count == safeLimit { break }
        }
        return sessions
    }

    /// Validates a transcript and returns the time of its last message typed by the user.
    /// Tool results, injected context and subagent turns are user-role records too, and
    /// do not count.
    @discardableResult
    static func latestUserMessage(in data: Data, sessionID: String) throws -> Date? {
        guard data.isEmpty == false, data.last == 0x0A else {
            throw ClaudeSessionTransferError.incompleteTranscript(sessionID: sessionID)
        }

        var latest: Date?
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        for (index, line) in lines.enumerated() {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                throw ClaudeSessionTransferError.invalidTranscript(sessionID: sessionID, line: index + 1)
            }
            guard
                record["type"] as? String == "user",
                record["isSidechain"] as? Bool != true,
                record["isMeta"] as? Bool != true,
                record["isCompactSummary"] as? Bool != true,
                let message = record["message"] as? [String: Any],
                isTypedByUser(message["content"]),
                let timestamp = record["timestamp"] as? String,
                let date = ClaudeTimestamp.parse(timestamp)
            else {
                continue
            }
            if latest == nil || date > latest! { latest = date }
        }
        return latest
    }

    private static func isTypedByUser(_ content: Any?) -> Bool {
        if let text = content as? String {
            return text.isEmpty == false
        }
        guard let blocks = content as? [[String: Any]] else { return false }
        return blocks.contains { $0["type"] as? String != "tool_result" }
    }

    static func prepareTransfer(
        _ session: SessionRecord,
        to destination: CodexProfile
    ) throws -> PreparedTransfer {
        let destinationURL = destination.homeURL
            .appending(path: "projects")
            .appending(path: session.file.projectDirectoryName)
            .appending(path: session.file.url.lastPathComponent)
        let destinationData = FileManager.default.fileExists(atPath: destinationURL.path)
            ? try Data(contentsOf: destinationURL) : nil
        return PreparedTransfer(
            session: session,
            destinationURL: destinationURL,
            disposition: try destinationDisposition(
                sourceData: session.data,
                destinationData: destinationData,
                sessionID: session.file.sessionID
            ),
            destinationData: destinationData
        )
    }

    /// Follows the Codex rules: an identical or further-along destination is kept, a
    /// destination that is the start of the source is extended, and when the two have
    /// diverged the one with the later user message wins.
    static func destinationDisposition(
        sourceData: Data,
        destinationData: Data?,
        sessionID: String
    ) throws -> DestinationDisposition {
        guard let destinationData else { return .copy }
        guard sourceData != destinationData else { return .alreadyPresent }
        if sourceData.starts(with: destinationData) { return .replace }
        if destinationData.starts(with: sourceData) { return .alreadyPresent }
        let sourceDate = try latestUserMessage(in: sourceData, sessionID: sessionID)
        let destinationDate = try latestUserMessage(in: destinationData, sessionID: sessionID)
        if let sourceDate, destinationDate == nil || sourceDate > destinationDate! {
            return .replace
        }
        return .alreadyPresent
    }

    /// Writes every pending transcript, or none: a failure restores what was there before.
    /// Returns the number of transcripts written.
    @discardableResult
    static func commit(_ prepared: [PreparedTransfer]) throws -> Int {
        let fileManager = FileManager.default
        var committed: [PreparedTransfer] = []
        do {
            for transfer in prepared where transfer.disposition != .alreadyPresent {
                let sessionID = transfer.session.file.sessionID
                let directoryURL = transfer.destinationURL.deletingLastPathComponent()
                let temporaryURL = directoryURL.appending(
                    path: ".\(transfer.destinationURL.lastPathComponent).\(UUID().uuidString).tmp"
                )
                do {
                    try fileManager.createDirectory(
                        at: directoryURL,
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700]
                    )
                    try transfer.session.data.write(to: temporaryURL, options: .withoutOverwriting)
                    // Keep the original's time so /resume lists the copy where it belongs.
                    try fileManager.setAttributes(
                        [.posixPermissions: 0o600, .modificationDate: transfer.session.file.modifiedAt],
                        ofItemAtPath: temporaryURL.path
                    )
                    if transfer.disposition == .replace {
                        guard try Data(contentsOf: transfer.destinationURL) == transfer.destinationData else {
                            throw ClaudeSessionTransferError.copyFailed(
                                sessionID: sessionID,
                                reason: "Destination changed during transfer. Retry the transfer."
                            )
                        }
                        guard rename(temporaryURL.path, transfer.destinationURL.path) == 0 else {
                            throw ClaudeSessionTransferError.copyFailed(
                                sessionID: sessionID, reason: String(cString: strerror(errno))
                            )
                        }
                    } else {
                        try fileManager.moveItem(at: temporaryURL, to: transfer.destinationURL)
                    }
                    committed.append(transfer)
                } catch {
                    try? fileManager.removeItem(at: temporaryURL)
                    if let transferError = error as? ClaudeSessionTransferError { throw transferError }
                    throw ClaudeSessionTransferError.copyFailed(
                        sessionID: sessionID, reason: error.localizedDescription
                    )
                }
            }
        } catch {
            for transfer in committed.reversed() {
                do {
                    if let original = transfer.destinationData {
                        try original.write(to: transfer.destinationURL, options: .atomic)
                    } else {
                        try fileManager.removeItem(at: transfer.destinationURL)
                    }
                } catch {
                    throw ClaudeSessionTransferError.copyFailed(
                        sessionID: transfer.session.file.sessionID,
                        reason: "Transfer rollback failed: \(error.localizedDescription)"
                    )
                }
            }
            throw error
        }
        return committed.count
    }
}
