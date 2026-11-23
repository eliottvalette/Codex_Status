import Foundation

enum SQLiteQueryRunnerError: Error, LocalizedError {
    case missingDatabase(URL)
    case invalidDatabaseURL(URL)
    case launchFailed(String)
    case queryFailed(status: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case let .missingDatabase(url):
            "SQLite database not found at \(url.path)."
        case let .invalidDatabaseURL(url):
            "Could not construct a SQLite URI for \(url.path)."
        case let .launchFailed(message):
            "Could not launch sqlite3: \(message)"
        case let .queryFailed(status, stderr):
            stderr.isEmpty
                ? "sqlite3 exited with status \(status)."
                : "sqlite3 failed: \(stderr)"
        }
    }
}

enum SQLiteQueryRunner {
    static func query(
        databaseURL: URL,
        sql: String,
        outputJSON: Bool = false
    ) throws -> Data {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw SQLiteQueryRunnerError.missingDatabase(databaseURL)
        }

        guard var components = URLComponents(
            url: databaseURL.standardizedFileURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw SQLiteQueryRunnerError.invalidDatabaseURL(databaseURL)
        }
        components.queryItems = [URLQueryItem(name: "mode", value: "rw")]
        guard let databaseURI = components.string else {
            throw SQLiteQueryRunnerError.invalidDatabaseURL(databaseURL)
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = (outputJSON ? ["-json"] : []) + [databaseURI, sql]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw SQLiteQueryRunnerError.launchFailed(error.localizedDescription)
        }

        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(
            decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SQLiteQueryRunnerError.queryFailed(
                status: process.terminationStatus,
                stderr: stderr
            )
        }
        return outputJSON && output.isEmpty ? Data("[]".utf8) : output
    }
}
