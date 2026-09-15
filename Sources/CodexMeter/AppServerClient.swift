import Darwin
import Foundation

enum AppServerClientError: Error, LocalizedError {
    case missingCodexExecutable(URL)
    case missingProfileHome(URL)
    case launchFailed(String)
    case timedOut(TimeInterval)
    case exitedWithoutResponse(status: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case let .missingCodexExecutable(url):
            "Codex executable not found at \(url.path)."
        case let .missingProfileHome(url):
            "CODEX_HOME does not exist at \(url.path)."
        case let .launchFailed(message):
            "Could not launch codex app-server: \(message)"
        case let .timedOut(seconds):
            "Codex app-server did not return rate limits within \(Int(seconds)) seconds."
        case let .exitedWithoutResponse(status, stderr):
            stderr.isEmpty
                ? "Codex app-server exited with status \(status) before returning rate limits."
                : "Codex app-server exited with status \(status): \(stderr)"
        }
    }
}

struct AppServerClient: Sendable {
    let codexExecutableURL: URL
    let timeout: TimeInterval

    init(
        codexExecutableURL: URL = URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
        timeout: TimeInterval = 12
    ) {
        self.codexExecutableURL = codexExecutableURL
        self.timeout = timeout
    }

    @concurrent
    func fetchRateLimits(for profile: CodexProfile) async throws -> QuotaSnapshot {
        try Task.checkCancellation()
        return try fetchRateLimitsSynchronously(for: profile)
    }

    private func fetchRateLimitsSynchronously(for profile: CodexProfile) throws -> QuotaSnapshot {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: codexExecutableURL.path) else {
            throw AppServerClientError.missingCodexExecutable(codexExecutableURL)
        }
        guard fileManager.fileExists(atPath: profile.homeURL.path) else {
            throw AppServerClientError.missingProfileHome(profile.homeURL)
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = codexExecutableURL
        process.arguments = ["app-server", "--stdio"]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["CODEX_HOME": profile.homeURL.path],
            uniquingKeysWith: { _, profileValue in profileValue }
        )
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw AppServerClientError.launchFailed(error.localizedDescription)
        }

        defer {
            try? inputPipe.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
            }
        }

        let messages = [
            #"{"method":"initialize","id":0,"params":{"clientInfo":{"name":"codex_meter","title":"CodexMeter","version":"0.1.0"}}}"#,
            #"{"method":"initialized","params":{}}"#,
            #"{"method":"account/rateLimits/read","id":2,"params":{}}"#,
        ].joined(separator: "\n") + "\n"

        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: Data(messages.utf8))
        } catch {
            throw AppServerClientError.launchFailed("Could not write the RPC request: \(error.localizedDescription)")
        }

        let output = outputPipe.fileHandleForReading
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()

        while Date() < deadline {
            try Task.checkCancellation()

            var descriptor = pollfd(
                fd: output.fileDescriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let remainingMilliseconds = max(1, Int32(deadline.timeIntervalSinceNow * 1_000))
            let pollResult = Darwin.poll(&descriptor, 1, remainingMilliseconds)

            if pollResult < 0 {
                throw AppServerClientError.launchFailed(String(cString: strerror(errno)))
            }
            if pollResult == 0 {
                throw AppServerClientError.timedOut(timeout)
            }

            if descriptor.revents & Int16(POLLIN | POLLHUP) != 0 {
                let chunk = try output.read(upToCount: 16_384) ?? Data()
                if chunk.isEmpty {
                    break
                }
                buffer.append(chunk)

                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    guard line.isEmpty == false else { continue }
                    if let snapshot = try RateLimitParser.parseResponseLine(Data(line)) {
                        return snapshot
                    }
                }
            }

            if process.isRunning == false {
                break
            }
        }

        process.waitUntilExit()
        let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(decoding: stderrData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw AppServerClientError.exitedWithoutResponse(
            status: process.terminationStatus,
            stderr: stderr
        )
    }
}
