import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

enum ClaudeCLIError: Error, Equatable, LocalizedError {
    case missingExecutable
    case missingProfileHome(URL)
    case launchFailed(String)
    case timedOut(TimeInterval)
    case exitedWithoutResponse(status: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable:
            "Claude Code executable not found. Looked in "
                + ClaudeCLI.executableCandidates(home: FileManager.default.homeDirectoryForCurrentUser)
                .map(\.path).joined(separator: ", ") + "."
        case let .missingProfileHome(url):
            "Claude configuration directory does not exist at \(url.path)."
        case let .launchFailed(message):
            "Could not run claude: \(message)"
        case let .timedOut(seconds):
            "Claude Code did not answer within \(Int(seconds)) seconds."
        case let .exitedWithoutResponse(status, stderr):
            stderr.isEmpty
                ? "Claude Code exited with status \(status) before answering."
                : "Claude Code exited with status \(status): \(stderr)"
        }
    }
}

/// Runs the Claude Code command line for one profile and reads its output line by line.
struct ClaudeCLI: Sendable {
    /// A fixed executable. When `nil`, the usual install locations are searched on each run.
    let executableURL: URL?
    let home: URL

    init(
        executableURL: URL? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.executableURL = executableURL
        self.home = home
    }

    /// Flags that keep a background run from touching the user's setup: no saved session,
    /// no MCP servers, no skills, no tools and no hooks.
    static let quietArguments = [
        "--no-session-persistence",
        "--strict-mcp-config",
        "--disable-slash-commands",
        "--tools", "",
        "--settings", #"{"disableAllHooks":true}"#,
    ]

    /// Variables that would replace the profile's own sign-in with another credential.
    private static let overridingCredentialVariables = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_TOKEN",
    ]

    static func executableCandidates(home: URL) -> [URL] {
        [
            home.appending(path: ".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            home.appending(path: ".claude/local/claude"),
        ]
    }

    func resolvedExecutable() throws -> URL {
        let candidates = executableURL.map { [$0] } ?? Self.executableCandidates(home: home)
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw ClaudeCLIError.missingExecutable
        }
        return executable
    }

    func environment(
        for profile: CodexProfile,
        executable: URL,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        for variable in Self.overridingCredentialVariables {
            environment.removeValue(forKey: variable)
        }
        if ClaudeProfiles.usesDefaultDirectory(profile, home: home) {
            environment.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        } else {
            environment["CLAUDE_CONFIG_DIR"] = profile.homeURL.path
        }
        // An app started from Finder has a bare PATH, and an npm install of claude needs node.
        let searchPath = [
            executable.deletingLastPathComponent().path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            base["PATH"] ?? "/usr/bin:/bin",
        ]
        environment["PATH"] = searchPath.joined(separator: ":")
        return environment
    }

    /// Starts claude, writes `input` if given, and passes each output line to `onLine`
    /// until it returns a value. The process is stopped as soon as that happens.
    func run<Output>(
        arguments: [String],
        for profile: CodexProfile,
        input: Data? = nil,
        timeout: TimeInterval,
        onLine: (Data) throws -> Output?
    ) throws -> Output {
        _ = Self.ignoresBrokenPipes
        let executable = try resolvedExecutable()
        guard FileManager.default.fileExists(atPath: profile.homeURL.path) else {
            throw ClaudeCLIError.missingProfileHome(profile.homeURL)
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment(for: profile, executable: executable)
        process.currentDirectoryURL = profile.homeURL
        process.standardInput = input == nil ? FileHandle.nullDevice : inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw ClaudeCLIError.launchFailed(error.localizedDescription)
        }
        defer {
            try? inputPipe.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
            }
        }

        if let input {
            // A failed write means claude already exited. Reading on reports why.
            try? inputPipe.fileHandleForWriting.write(contentsOf: input)
        }

        let outputDescriptor = outputPipe.fileHandleForReading.fileDescriptor
        let errorDescriptor = errorPipe.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = Data()
        var stderr = Data()
        var isErrorOpen = true

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw ClaudeCLIError.timedOut(timeout)
            }
            var descriptors = [
                pollfd(fd: outputDescriptor, events: Int16(POLLIN), revents: 0),
                pollfd(fd: isErrorOpen ? errorDescriptor : -1, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&descriptors, 2, Int32(max(1, min(remaining, 1) * 1_000)))
            if ready < 0 {
                if errno == EINTR { continue }
                throw ClaudeCLIError.launchFailed(String(cString: strerror(errno)))
            }
            if ready == 0 { continue }

            if descriptors[1].revents != 0 {
                let chunk = try Self.readAvailableBytes(from: errorDescriptor)
                if chunk.isEmpty {
                    isErrorOpen = false
                } else if stderr.count < 16_384 {
                    stderr.append(chunk)
                }
            }

            guard descriptors[0].revents != 0 else { continue }
            let chunk = try Self.readAvailableBytes(from: outputDescriptor)
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard line.isEmpty == false else { continue }
                if let output = try onLine(line) {
                    return output
                }
            }
        }

        // Standard output closed without an answer. Give the process a moment to exit.
        let exitDeadline = min(deadline, Date().addingTimeInterval(2))
        while process.isRunning, Date() < exitDeadline {
            usleep(20_000)
        }
        if isErrorOpen, stderr.count < 16_384 {
            var descriptor = pollfd(fd: errorDescriptor, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 0) > 0, let rest = try? Self.readAvailableBytes(from: errorDescriptor) {
                stderr.append(rest)
            }
        }
        throw ClaudeCLIError.exitedWithoutResponse(
            status: process.isRunning ? -1 : process.terminationStatus,
            stderr: String(decoding: stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Writing to a claude process that already exited must fail with an error, not end the app.
    private static let ignoresBrokenPipes: Bool = {
        signal(SIGPIPE, SIG_IGN)
        return true
    }()

    private static func readAvailableBytes(from descriptor: Int32) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(descriptor, &bytes, bytes.count)
            if count >= 0 {
                return Data(bytes.prefix(count))
            }
            if errno == EINTR { continue }
            throw ClaudeCLIError.launchFailed(String(cString: strerror(errno)))
        }
    }
}
