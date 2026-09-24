import Foundation
import Testing
@testable import CodexMeter

@Suite("SQLite query runner")
struct SQLiteQueryRunnerTests {
    @Test("Reads a WAL database when SQLite must recreate its sidecar files")
    func readsDatabaseWithoutExistingWALSidecars() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "CodexMeter SQLite Tests (UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appending(path: "state_5.sqlite")
        try runSQLite(
            databaseURL: databaseURL,
            sql: "PRAGMA journal_mode=WAL; CREATE TABLE threads (id TEXT); INSERT INTO threads VALUES ('one');"
        )

        try? FileManager.default.removeItem(atPath: databaseURL.path + "-shm")
        try? FileManager.default.removeItem(atPath: databaseURL.path + "-wal")

        let output = try SQLiteQueryRunner.query(
            databaseURL: databaseURL,
            sql: "SELECT COUNT(*) AS count FROM threads;",
            outputJSON: true
        )
        let rows = try JSONDecoder().decode([CountRow].self, from: output)

        #expect(rows == [CountRow(count: 1)])
    }

    private struct CountRow: Decodable, Equatable {
        let count: Int
    }

    private func runSQLite(databaseURL: URL, sql: String) throws {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databaseURL.path, sql]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        _ = outputPipe.fileHandleForReading.readDataToEndOfFile()

        let stderr = String(
            decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        #expect(process.terminationStatus == 0, Comment(rawValue: stderr))
    }
}
