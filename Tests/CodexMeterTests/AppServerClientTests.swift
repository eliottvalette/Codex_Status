import Foundation
import Testing
@testable import CodexMeter

@Suite("App-server client and error handling")
struct AppServerClientTests {
    @Test("Formats error descriptions correctly")
    func formatsErrorDescriptions() {
        let timeoutError = AppServerClientError.timedOut(12)
        #expect(timeoutError.errorDescription == "Codex app-server did not return rate limits within 12 seconds.")

        let exitWithoutStderr = AppServerClientError.exitedWithoutResponse(status: 1, stderr: "")
        #expect(exitWithoutStderr.errorDescription == "Codex app-server exited with status 1 before returning rate limits.")

        let exitWithStderr = AppServerClientError.exitedWithoutResponse(status: 2, stderr: "fatal error")
        #expect(exitWithStderr.errorDescription == "Codex app-server exited with status 2: fatal error")
    }

    @Test("Collects exit error without throwing or blocking when process is still running")
    func collectsErrorWhileProcessRunning() throws {
        let client = AppServerClient()
        let process = Process()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        process.standardError = errorPipe

        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let collectedError = client.collectExitedWithoutResponseError(process: process, errorPipe: errorPipe)
        switch collectedError {
        case let .exitedWithoutResponse(status, stderr):
            #expect(status == -1)
            #expect(stderr.isEmpty)
        default:
            Issue.record("Expected exitedWithoutResponse error")
        }
    }

    @Test("Collects exit status and stderr when process has exited")
    func collectsErrorWhenProcessExited() throws {
        let client = AppServerClient()
        let process = Process()
        let errorPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo 'sample error' >&2; exit 42"]
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let collectedError = client.collectExitedWithoutResponseError(process: process, errorPipe: errorPipe)
        switch collectedError {
        case let .exitedWithoutResponse(status, stderr):
            #expect(status == 42)
            #expect(stderr == "sample error")
        default:
            Issue.record("Expected exitedWithoutResponse error")
        }
    }
}
