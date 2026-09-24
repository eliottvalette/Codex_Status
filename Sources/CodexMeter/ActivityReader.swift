import Foundation

enum ActivityReaderError: Error, LocalizedError {
    case invalidTimestamp(String)

    var errorDescription: String? {
        switch self {
        case let .invalidTimestamp(value):
            "Thread activity returned an invalid timestamp: \(value)"
        }
    }
}

enum ActivityReader {
    @concurrent
    static func latestActivity(for profile: CodexProfile) async throws -> Date? {
        let databaseURL = profile.homeURL.appending(path: "state_5.sqlite")
        let output = try SQLiteQueryRunner.query(
            databaseURL: databaseURL,
            sql: "SELECT MAX(updated_at) FROM threads;"
        )
        let value = String(
            decoding: output,
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else { return nil }
        guard let timestamp = TimeInterval(value) else {
            throw ActivityReaderError.invalidTimestamp(value)
        }
        return Date(timeIntervalSince1970: timestamp)
    }
}
