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
                let chunk = try PipeReader.readAvailableBytes(
                    from: output.fileDescriptor,
                    maximumCount: 16_384
                )
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

    @concurrent
    func sendActivationTurn(for profile: CodexProfile) async throws {
        try Task.checkCancellation()
        try sendActivationTurnSynchronously(for: profile)
    }

    private func sendActivationTurnSynchronously(for profile: CodexProfile) throws {
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

        let initialMessages = [
            #"{"method":"initialize","id":0,"params":{"clientInfo":{"name":"codex_meter","title":"CodexMeter","version":"0.1.0"}}}"#,
            #"{"method":"initialized","params":{}}"#,
            #"{"method":"thread/start","id":1,"params":{"ephemeral":true,"cwd":"\#(profile.homeURL.path)"}}"#,
        ].joined(separator: "\n") + "\n"

        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: Data(initialMessages.utf8))
        } catch {
            throw AppServerClientError.launchFailed("Could not write initial activation request: \(error.localizedDescription)")
        }

        let outputHandle = outputPipe.fileHandleForReading
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        var turnStarted = false

        while Date() < deadline {
            var descriptor = pollfd(
                fd: outputHandle.fileDescriptor,
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
                let chunk = try PipeReader.readAvailableBytes(
                    from: outputHandle.fileDescriptor,
                    maximumCount: 16_384
                )
                if chunk.isEmpty {
                    break
                }
                buffer.append(chunk)

                while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[..<newlineIndex]
                    buffer.removeSubrange(...newlineIndex)
                    guard line.isEmpty == false else { continue }
                    guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                        continue
                    }

                    if turnStarted == false, let responseId = object["id"] as? Int, responseId == 1 {
                        guard
                            let result = object["result"] as? [String: Any],
                            let thread = result["thread"] as? [String: Any],
                            let threadIdentifier = thread["id"] as? String
                        else {
                            throw AppServerClientError.launchFailed("thread/start did not return thread id")
                        }

                        let turnRequest: [String: Any] = [
                            "method": "turn/start",
                            "id": 2,
                            "params": [
                                "threadId": threadIdentifier,
                                "input": [
                                    ["type": "text", "text": "Reply exactly OK.", "text_elements": []]
                                ]
                            ]
                        ]
                        let turnData = try JSONSerialization.data(withJSONObject: turnRequest)
                        try inputPipe.fileHandleForWriting.write(contentsOf: turnData + Data([0x0A]))
                        turnStarted = true
                    }

                    if let method = object["method"] as? String, method == "turn/completed" {
                        return
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

enum PipeReaderError: Error, LocalizedError {
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case let .readFailed(message):
            "Could not read codex app-server output: \(message)"
        }
    }
}

enum PipeReader {
    static func readAvailableBytes(from fileDescriptor: Int32, maximumCount: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: maximumCount)

        while true {
            let count = Darwin.read(fileDescriptor, &bytes, maximumCount)
            if count >= 0 {
                return Data(bytes.prefix(count))
            }
            if errno == EINTR {
                continue
            }
            throw PipeReaderError.readFailed(String(cString: strerror(errno)))
        }
    }
}
