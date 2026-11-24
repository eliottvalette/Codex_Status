import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One conversation in the recent-chats list below the Claude accounts.
struct RecentClaudeChat: Identifiable, Equatable, Sendable {
    /// Rows shown at first, and added by each See more.
    static let pageSize = 8
    /// Rows loaded for See more.
    static let listLimit = 24

    let profileID: String
    let file: ClaudeSessionTransferService.TranscriptFile
    let title: String
    let workingDirectory: String?
    let folderName: String
    let lastMessageAt: Date
    /// Other Claude accounts that already hold this exact transcript.
    let copiedToProfileIDs: Set<String>

    /// The same conversation in two accounts is one row.
    var id: String { "\(file.projectDirectoryName)/\(file.sessionID)" }

    /// The age `claude-who` prints: `now`, `12m`, `5h` or `2d 3h`.
    static func ageLabel(since date: Date, relativeTo now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(date)))
        if elapsed < 60 { return "now" }
        if elapsed < 3_600 { return "\(elapsed / 60)m" }
        if elapsed < 86_400 { return "\(elapsed / 3_600)h" }
        return "\(elapsed / 86_400)d \((elapsed % 86_400) / 3_600)h"
    }

    /// A shell command that opens this conversation in `profile`, from its project folder
    /// so that `/resume` finds it.
    func resumeCommand(
        in profile: CodexProfile,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        var command = "claude --resume \(file.sessionID)"
        if ClaudeProfiles.usesDefaultDirectory(profile, home: home) == false {
            let directory = profile.homeURL.standardizedFileURL
            let inHome = directory.deletingLastPathComponent().path == home.standardizedFileURL.path
            let path = inHome ? "\"$HOME/\(directory.lastPathComponent)\"" : ClaudeProfiles.shellQuoted(directory.path)
            command = "CLAUDE_CONFIG_DIR=\(path) " + command
        }
        guard let workingDirectory else { return command }
        return "cd \(ClaudeProfiles.shellQuoted(workingDirectory)) && " + command
    }
}

/// Lists the most recent Claude conversations across accounts.
///
/// Transcripts can be tens of megabytes and the list is rebuilt on every refresh, so a
/// transcript is read again only when its modification time or size changes, and only
/// the records that carry a title or a typed prompt are parsed.
actor ClaudeChatCatalog {
    struct Summary: Equatable, Sendable {
        var customTitle: String?
        var aiTitle: String?
        var summary: String?
        var firstPrompt: String?
        var lastUserMessageAt: Date?
        var workingDirectory: String?

        /// The order `claude-who` uses.
        /// The order `claude-who` uses, with the Claude app's title after a custom one.
        func title(appTitle: String? = nil) -> String {
            [customTitle, appTitle, aiTitle, summary, firstPrompt]
                .compactMap { $0.map(ClaudeChatCatalog.cleanTitle) }
                .first { $0.isEmpty == false } ?? "[untitled]"
        }
    }

    private struct CacheEntry {
        let modifiedAt: Date
        let size: Int
        let summary: Summary
    }

    private static let maximumTitleLength = 100
    /// Every record type sits within the first few hundred bytes of its line.
    private static let headLength = 4_096

    /// What the Claude desktop app keeps about one of its Code sessions.
    struct AppSession: Equatable, Sendable {
        let isArchived: Bool
        let title: String?
    }

    private let home: URL
    private let appSessionsURL: URL
    private var cache: [String: CacheEntry] = [:]
    private var appSessionCache: [String: (modifiedAt: Date, sessionID: String?, session: AppSession)] = [:]

    /// `appSessionsURL` is where the Claude desktop app keeps one small JSON file per local
    /// Code session. The list hides the sessions archived there and uses their titles.
    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        appSessionsURL: URL? = nil
    ) {
        self.home = home
        self.appSessionsURL = appSessionsURL
            ?? home.appending(path: "Library/Application Support/Claude/claude-code-sessions")
    }

    /// The Claude app's sessions by Claude Code session ID. Only `cliSessionId`,
    /// `isArchived` and `title` are read, and a file is read again only when it changes.
    func appSessions() -> [String: AppSession] {
        let fileManager = FileManager.default
        func contents(_ url: URL) -> [URL] {
            (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
        var found: [String: AppSession] = [:]
        var seen = Set<String>()
        // <account>/<organization>/local_<id>.json
        for url in contents(appSessionsURL).flatMap(contents).flatMap(contents)
        where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
            guard let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { continue }
            seen.insert(url.path)
            if appSessionCache[url.path]?.modifiedAt != modifiedAt {
                let record = (try? Data(contentsOf: url))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                appSessionCache[url.path] = (
                    modifiedAt,
                    record["cliSessionId"] as? String,
                    AppSession(isArchived: record["isArchived"] as? Bool == true, title: record["title"] as? String)
                )
            }
            guard let entry = appSessionCache[url.path], let sessionID = entry.sessionID else { continue }
            // A session the app still shows anywhere is not archived.
            if found[sessionID]?.isArchived == false { continue }
            found[sessionID] = entry.session
        }
        appSessionCache = appSessionCache.filter { seen.contains($0.key) }
        return found
    }

    func recentChats(in profiles: [CodexProfile], limit: Int = 8) -> [RecentClaudeChat] {
        let limit = max(1, limit)
        let appSessions = appSessions()
        var files: [(profile: CodexProfile, file: ClaudeSessionTransferService.TranscriptFile)] = []
        for profile in profiles {
            // An account whose folder cannot be listed is left out rather than failing the list.
            let transcripts = (try? ClaudeSessionTransferService.transcriptFiles(in: profile)) ?? []
            files += transcripts.map { (profile, $0) }
        }
        let rank = Dictionary(profiles.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let listedPaths = Set(files.map(\.file.url.path))
        cache = cache.filter { listedPaths.contains($0.key) }

        // A transcript changes whenever a message is added, so its last prompt is never later
        // than its modification time. Reading newest first allows an early stop.
        files.sort {
            $0.file.modifiedAt != $1.file.modifiedAt
                ? $0.file.modifiedAt > $1.file.modifiedAt
                : $0.file.url.path < $1.file.url.path
        }
        var chats: [String: (profile: CodexProfile, file: ClaudeSessionTransferService.TranscriptFile, summary: Summary, at: Date)] = [:]
        for (profile, file) in files {
            if chats.count >= limit {
                let cutoff = chats.values.map(\.at).sorted(by: >)[limit - 1]
                if file.modifiedAt < cutoff { break }
            }
            // A conversation archived in the Claude app is left out, as the app's menu does.
            if appSessions[file.sessionID]?.isArchived == true { continue }
            guard let summary = summary(of: file), let lastMessageAt = summary.lastUserMessageAt else {
                continue
            }
            let id = "\(file.projectDirectoryName)/\(file.sessionID)"
            if let existing = chats[id] {
                // Identical copies stay under the account listed first, usually the original.
                let keepsExisting = existing.at == lastMessageAt
                    ? rank[existing.profile.id, default: 0] <= rank[profile.id, default: 0]
                    : existing.at > lastMessageAt
                if keepsExisting { continue }
            }
            chats[id] = (profile, file, summary, lastMessageAt)
        }

        return chats.values
            .sorted { $0.at != $1.at ? $0.at > $1.at : $0.file.url.path < $1.file.url.path }
            .prefix(limit)
            .map { entry in
                RecentClaudeChat(
                    profileID: entry.profile.id,
                    file: entry.file,
                    title: entry.summary.title(appTitle: appSessions[entry.file.sessionID]?.title),
                    workingDirectory: entry.summary.workingDirectory,
                    folderName: folderName(entry.summary.workingDirectory, project: entry.file.projectDirectoryName),
                    lastMessageAt: entry.at,
                    copiedToProfileIDs: Set(profiles.filter { other in
                        other.id != entry.profile.id && Self.holdsCopy(of: entry.file, in: other)
                    }.map(\.id))
                )
            }
    }

    private func summary(of file: ClaudeSessionTransferService.TranscriptFile) -> Summary? {
        guard
            let values = try? file.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
            let modifiedAt = values.contentModificationDate,
            let size = values.fileSize
        else {
            return nil
        }
        if let entry = cache[file.url.path], entry.modifiedAt == modifiedAt, entry.size == size {
            return entry.summary
        }
        guard let data = try? Data(contentsOf: file.url, options: .alwaysMapped) else { return nil }
        let summary = Self.summarize(data)
        cache[file.url.path] = CacheEntry(modifiedAt: modifiedAt, size: size, summary: summary)
        return summary
    }

    private func folderName(_ workingDirectory: String?, project: String) -> String {
        guard let workingDirectory, workingDirectory.isEmpty == false else { return project }
        let url = URL(fileURLWithPath: workingDirectory)
        if url.standardizedFileURL.path == home.standardizedFileURL.path { return "~" }
        return url.lastPathComponent
    }

    /// A copy made by the app keeps the size and the modification time of the original.
    private static func holdsCopy(
        of file: ClaudeSessionTransferService.TranscriptFile,
        in profile: CodexProfile
    ) -> Bool {
        let copy = profile.homeURL
            .appending(path: "projects")
            .appending(path: file.projectDirectoryName)
            .appending(path: file.url.lastPathComponent)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard
            let original = try? file.url.resourceValues(forKeys: keys),
            let candidate = try? copy.resourceValues(forKeys: keys),
            let originalDate = original.contentModificationDate,
            let candidateDate = candidate.contentModificationDate
        else {
            return false
        }
        return original.fileSize == candidate.fileSize
            && abs(originalDate.timeIntervalSince(candidateDate)) < 0.001
    }

    /// Reads the titles, the first and last typed prompts and the working directory of a
    /// transcript. A line is parsed only when its record type, which Claude Code writes
    /// near the start of the line, marks a title or a prompt. Tool results are user records
    /// too and make up most of a long transcript; they are skipped unparsed. A last record
    /// still being written is ignored.
    static func summarize(_ data: Data) -> Summary {
        var result = Summary()
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var start = 0
            while start < buffer.count {
                guard let newline = memchr(base + start, 0x0A, buffer.count - start) else { break }
                let end = base.distance(to: UnsafeRawPointer(newline))
                if end > start {
                    read(line: base + start, length: end - start, into: &result)
                }
                start = end + 1
            }
        }
        return result
    }

    private static func read(line: UnsafeRawPointer, length: Int, into result: inout Summary) {
        let head = min(length, headLength)
        func headContains(_ marker: StaticString) -> Bool {
            memmem(line, head, marker.utf8Start, marker.utf8CodeUnitCount) != nil
        }
        func record() -> [String: Any]? {
            try? JSONSerialization.jsonObject(with: Data(bytes: line, count: length)) as? [String: Any]
        }

        if headContains(#""type":"user""#) {
            guard
                headContains(#""type":"tool_result""#) == false,
                let record = record(),
                ClaudeSessionTransferService.isTypedUserRecord(record),
                let timestamp = record["timestamp"] as? String,
                let date = ClaudeTimestamp.parse(timestamp)
            else {
                return
            }
            if result.lastUserMessageAt.map({ date > $0 }) ?? true {
                result.lastUserMessageAt = date
            }
            if result.firstPrompt == nil {
                // A pasted prompt can be long; the list shows one line of it.
                result.firstPrompt = String(promptText(record).prefix(4 * maximumTitleLength))
                result.workingDirectory = record["cwd"] as? String
            }
        } else if headContains(#""type":"custom-title""#) {
            if let title = record()?["customTitle"] as? String, title.isEmpty == false {
                result.customTitle = title
            }
        } else if headContains(#""type":"ai-title""#) {
            if let title = record()?["aiTitle"] as? String, title.isEmpty == false {
                result.aiTitle = title
            }
        } else if headContains(#""type":"summary""#) {
            if let title = record()?["summary"] as? String, title.isEmpty == false {
                result.summary = title
            }
        }
    }

    private static func promptText(_ record: [String: Any]) -> String {
        let content = (record["message"] as? [String: Any])?["content"]
        if let text = content as? String { return text }
        let blocks = content as? [[String: Any]] ?? []
        return blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
    }

    /// Names a conversation the way `/rename` does in Claude Code: one `custom-title` record
    /// at the end of the transcript. Identical copies on other accounts get the same record
    /// and the same modification time, so they stay identical.
    static func rename(_ chat: RecentClaudeChat, to title: String, in profiles: [CodexProfile]) throws {
        let title = cleanTitle(title)
        guard title.isEmpty == false else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        func json(_ value: String) throws -> String {
            String(decoding: try encoder.encode(value), as: UTF8.self)
        }
        let record = #"{"type":"custom-title","customTitle":\#(try json(title)),"sessionId":\#(try json(chat.file.sessionID))}"#

        let copies = profiles.filter { chat.copiedToProfileIDs.contains($0.id) }.map {
            $0.homeURL.appending(path: "projects")
                .appending(path: chat.file.projectDirectoryName)
                .appending(path: chat.file.url.lastPathComponent)
        }
        let renamedAt = Date()
        for url in [chat.file.url] + copies {
            let handle = try FileHandle(forUpdating: url)
            do {
                let end = try handle.seekToEnd()
                // A record Claude Code is still writing would merge with this one.
                if end > 0 {
                    try handle.seek(toOffset: end - 1)
                    guard try handle.read(upToCount: 1) == Data([0x0A]) else {
                        throw ClaudeSessionTransferError.incompleteTranscript(sessionID: chat.file.sessionID)
                    }
                }
                try handle.write(contentsOf: Data((record + "\n").utf8))
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try FileManager.default.setAttributes([.modificationDate: renamedAt], ofItemAtPath: url.path)
        }
    }

    /// One line, no control characters, at most 100 characters.
    static func cleanTitle(_ value: String) -> String {
        let words = value
            .unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard words.count > maximumTitleLength else { return words }
        return String(words.prefix(maximumTitleLength - 1)) + "…"
    }
}
