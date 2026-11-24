import Darwin
import Foundation

struct SyncComparisonCache: Codable {
    struct FileStamp: Codable, Equatable {
        let path: String
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        static func read(_ path: String) -> Self? {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            var info = stat()
            guard resolved.withCString({ lstat($0, &info) }) == 0,
                  info.st_mode & S_IFMT == S_IFREG else { return nil }
            return Self(
                path: resolved, device: info.st_dev, inode: info.st_ino, size: info.st_size,
                modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec
            )
        }
    }

    struct IndexedRollout: Codable, Equatable {
        let path: String
        let updated: Int64
        let recency: Int64
    }

    struct Entry: Codable {
        let sourcePath: String
        let destination: IndexedRollout
        let files: [String: FileStamp]
        let indexedParents: [String: String]
        let historySegments: [String: String]
        var issue: String? = nil

        func matches(
            sourcePath: String,
            destination: IndexedRollout?,
            indexedParents: [String: String],
            historySegments: [String: [String]]
        ) -> Bool {
            self.sourcePath == sourcePath
                && self.destination == destination
                && self.indexedParents.allSatisfy { indexedParents[$0.key] == $0.value }
                && self.historySegments.allSatisfy { historySegments[$0.key] == [$0.value] }
                && files.allSatisfy { FileStamp.read($0.key) == $0.value }
        }
    }

    var sources: [String: [String: Entry]] = [:]

    static func url(in profile: CodexProfile) -> URL {
        profile.homeURL.appending(path: "codex-meter-sync-comparisons-v1.json")
    }

    static func read(in profile: CodexProfile) throws -> Self {
        let url = url(in: profile)
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func save(in profile: CodexProfile) throws {
        try JSONEncoder().encode(self).write(to: Self.url(in: profile), options: .atomic)
    }
}
