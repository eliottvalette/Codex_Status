import Foundation

enum ActivityReaderError: Error, LocalizedError {
    case missingDatabase(URL)
    case queryFailed(status: Int32, stderr: String)
    case invalidTimestamp(String)

    var errorDescription: String? {
        switch self {
        case let .missingDatabase(url):
            "Thread activity database not found at \(url.path)."
        case let .queryFailed(status, stderr):
            stderr.isEmpty
                ? "Could not read thread activity; sqlite3 exited with status \(status)."
                : "Could not read thread activity: \(stderr)"
        case let .invalidTimestamp(value):
            "Thread activity returned an invalid timestamp: \(value)"
        }
    }
}

enum ActivityReader {
    @concurrent
    static func latestActivity(for profile: CodexProfile) async throws -> Date? {
        let databaseURL = profile.homeURL.appending(path: "state_5.sqlite")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw ActivityReaderError.missingDatabase(databaseURL)
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly",
            databaseURL.path,
            "SELECT MAX(updated_at) FROM threads;",
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let stderr = String(
            decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw ActivityReaderError.queryFailed(status: process.terminationStatus, stderr: stderr)
        }

        let value = String(
            decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty == false else { return nil }
        guard let timestamp = TimeInterval(value) else {
            throw ActivityReaderError.invalidTimestamp(value)
        }
        return Date(timeIntervalSince1970: timestamp)
    }
}
