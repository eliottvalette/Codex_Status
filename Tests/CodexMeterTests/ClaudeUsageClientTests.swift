import Foundation
import Testing
@testable import CodexMeter

@Suite("Claude usage through the Claude Code command line")
struct ClaudeUsageClientTests {
    private let fetchedAt = Date(timeIntervalSince1970: 1_762_230_000)

    private func response(_ body: String, subtype: String = "success") -> Data {
        Data("""
            {"type":"control_response","response":{"subtype":"\(subtype)","request_id":"codex-meter-usage",\(body)}}
            """.utf8)
    }

    @Test("Reads the five-hour and weekly windows of a Claude plan")
    func parsesPlanWindows() throws {
        let line = response("""
            "response":{"session":{"total_cost_usd":0},"subscription_type":"max","rate_limits_available":true,
            "rate_limits":{"five_hour":{"utilization":6.0,"resets_at":"2025-11-04T04:59:59.943648+00:00"},
            "seven_day":{"utilization":35,"resets_at":"2025-11-06T03:59:59+00:00"},
            "seven_day_opus":{"utilization":0.0,"resets_at":null},"extra_usage":null},"behaviors":null}
            """)

        let snapshot = try #require(try ClaudeUsageParser.parseResponseLine(line, fetchedAt: fetchedAt))

        #expect(snapshot.planType == "max")
        #expect(snapshot.fetchedAt == fetchedAt)
        #expect(snapshot.shortWindow?.durationMinutes == 300)
        #expect(snapshot.shortWindow?.usedPercent == 6)
        #expect(snapshot.shortWindow?.state == .active)
        let shortReset = try #require(snapshot.shortWindow?.resetsAt)
        #expect(abs(shortReset.timeIntervalSince1970 - 1_762_232_399.943648) < 0.001)
        #expect(snapshot.weeklyWindow?.durationMinutes == 10_080)
        #expect(snapshot.weeklyWindow?.remainingPercent == 65)
        #expect(snapshot.weeklyWindow?.resetsAt == Date(timeIntervalSince1970: 1_762_401_599))
        #expect(snapshot.availableResetCredits == nil)
    }

    @Test("Treats a window with no reset time, or one already past, as idle")
    func classifiesIdleWindows() throws {
        let line = response("""
            "response":{"subscription_type":"pro","rate_limits_available":true,
            "rate_limits":{"five_hour":{"utilization":0,"resets_at":null},
            "seven_day":{"utilization":80,"resets_at":"2025-11-01T00:00:00Z"}}}
            """)

        let snapshot = try #require(try ClaudeUsageParser.parseResponseLine(line, fetchedAt: fetchedAt))

        #expect(snapshot.shortWindow == QuotaWindow(
            durationMinutes: 300, usedPercent: 0, resetsAt: nil, state: .dormant
        ))
        #expect(snapshot.weeklyWindow == QuotaWindow(
            durationMinutes: 10_080, usedPercent: 0, resetsAt: nil, state: .dormant
        ))
    }

    @Test("Accepts missing windows, epoch reset times and usage without a reset time")
    func toleratesShapeChanges() throws {
        let line = response("""
            "response":{"subscription_type":null,"rate_limits_available":true,
            "rate_limits":{"five_hour":null,"seven_day":{"utilization":140,"resets_at":1762300000}}}
            """)
        let snapshot = try #require(try ClaudeUsageParser.parseResponseLine(line, fetchedAt: fetchedAt))
        #expect(snapshot.planType == nil)
        #expect(snapshot.shortWindow == nil)
        #expect(snapshot.weeklyWindow?.usedPercent == 100)
        #expect(snapshot.weeklyWindow?.resetsAt == Date(timeIntervalSince1970: 1_762_300_000))

        let unknownReset = response("""
            "response":{"rate_limits":{"five_hour":{"utilization":12.5,"resets_at":null}}}
            """)
        let window = try #require(
            try ClaudeUsageParser.parseResponseLine(unknownReset, fetchedAt: fetchedAt)?.shortWindow
        )
        #expect(window.usedPercent == 12.5)
        #expect(window.state == .active)
        #expect(window.resetsAt == nil)
    }

    @Test("Reads the weekly limits of single models and picks the tightest one in use")
    func parsesModelWindows() throws {
        let line = response("""
            "response":{"subscription_type":"max","rate_limits_available":true,
            "rate_limits":{"five_hour":null,
            "seven_day":{"utilization":75,"resets_at":"2025-11-06T03:59:59+00:00","limit_dollars":null,"locked_reason":null},
            "seven_day_opus":{"utilization":0.0,"resets_at":null},
            "seven_day_sonnet":{"utilization":40,"resets_at":"2025-11-06T03:59:59+00:00"},
            "model_scoped":[{"display_name":"Fable","utilization":84,"resets_at":"2025-11-06T03:59:59.320797+00:00"},
            {"display_name":"sonnet","utilization":41,"resets_at":"2025-11-06T03:59:59+00:00"},
            {"display_name":"","utilization":99,"resets_at":null}]}}
            """)

        let snapshot = try #require(try ClaudeUsageParser.parseResponseLine(line, fetchedAt: fetchedAt))

        #expect(snapshot.shortWindow == nil)
        #expect(snapshot.weeklyWindow?.remainingPercent == 25)
        // `model_scoped` wins over the older field of the same model; an idle window stays listed.
        #expect(snapshot.modelWindows.map(\.name) == ["Fable", "sonnet", "Opus"])
        #expect(snapshot.modelWindows.map(\.window.usedPercent) == [84, 41, 0])
        #expect(snapshot.modelWindows[0].window.durationMinutes == 10_080)
        #expect(snapshot.modelWindows[2].window.state == .dormant)
        let tightest = try #require(snapshot.tightestModelWindow)
        #expect(tightest.name == "Fable")
        #expect(tightest.label == "FABLE")
        #expect(tightest.window.remainingPercent == 16)

        let status = ProfileStatus(
            profile: CodexProfile(
                id: "claude", displayName: "claude", homeURL: URL(fileURLWithPath: "/nowhere"), provider: .claude
            ),
            snapshot: snapshot
        )
        #expect(LowestRemainingQuota.find(in: [status]) == LowestRemainingQuota(provider: .claude, percent: 16))
    }

    @Test("Reads the reply of Claude Code 2.1.331, which also lists every limit under `limits`")
    func parsesCurrentReplyShape() throws {
        // The shape of a real reply with the numbers changed. Fields the app does not use
        // are trimmed to a few representatives.
        let line = response("""
            "response":{"subscription_type":"max","rate_limits_available":true,"behaviors":null,"session":null,
            "rate_limits":{"five_hour":null,
            "seven_day":{"utilization":60,"resets_at":"2025-11-06T09:00:00.272408+00:00","limit_dollars":null,
            "used_dollars":null,"remaining_dollars":null,"locked_reason":null},
            "seven_day_oauth_apps":null,"seven_day_opus":null,"seven_day_sonnet":null,"pace":null,
            "limits":[{"kind":"weekly_all","group":"weekly","percent":60,"resets_at":"2025-11-06T09:00:00.272408+00:00",
            "severity":"warning","is_active":false,"scope":null},
            {"kind":"weekly_scoped","group":"weekly","percent":70,"resets_at":"2025-11-06T09:00:00.272560+00:00",
            "severity":"warning","is_active":true,"scope":{"model":{"display_name":"Fable","id":null},"surface":null}}],
            "seven_day_breakdown":{"rows":[{"key":"claude_code","display_name":"Claude Code","percent":100}]},
            "weekly_scoped_shares":[{"limit_index":1,"used_percent_of_weekly":43,"allowance_percent_of_weekly":50}],
            "model_scoped":[{"display_name":"Fable","utilization":70,"resets_at":"2025-11-06T09:00:00.272560+00:00"}]}}
            """)

        let snapshot = try #require(try ClaudeUsageParser.parseResponseLine(line, fetchedAt: fetchedAt))

        #expect(snapshot.shortWindow == nil)
        #expect(snapshot.weeklyWindow?.remainingPercent == 40)
        #expect(snapshot.modelWindows.map(\.name) == ["Fable"])
        #expect(snapshot.tightestModelWindow?.window.remainingPercent == 30)
        #expect(snapshot.tightestModelWindow?.window.state == .active)
    }

    @Test("Shows no model ring when no model limit is in use")
    func ignoresIdleModelWindows() throws {
        let line = response("""
            "response":{"rate_limits":{"seven_day":{"utilization":10,"resets_at":"2025-11-06T03:59:59+00:00"},
            "seven_day_opus":{"utilization":0.0,"resets_at":null}}}
            """)
        let snapshot = try #require(try ClaudeUsageParser.parseResponseLine(line, fetchedAt: fetchedAt))
        #expect(snapshot.modelWindows.count == 1)
        #expect(snapshot.tightestModelWindow == nil)
        #expect(ModelQuotaWindow(name: "A very long model name", window: snapshot.modelWindows[0].window).label == "A VERY")
    }

    @Test("Reports profiles without plan limits and errors from Claude Code")
    func rejectsUnavailableUsage() {
        let apiKeyProfile = response("""
            "response":{"subscription_type":null,"rate_limits_available":false,"rate_limits":null}
            """)
        #expect(throws: ClaudeUsageError.planLimitsUnavailable) {
            try ClaudeUsageParser.parseResponseLine(apiKeyProfile)
        }
        // A signed-in plan whose limits Claude Code could not fetch, for example after a 429.
        let unfetched = response("""
            "response":{"subscription_type":null,"rate_limits_available":true,"rate_limits":null}
            """)
        #expect(throws: ClaudeUsageError.usageTemporarilyUnavailable) {
            try ClaudeUsageParser.parseResponseLine(unfetched)
        }
        #expect(ClaudeUsageError.usageTemporarilyUnavailable.errorDescription?.contains("/login") == false)
        // Claude Code 2.1.112 answers the usage request this way.
        #expect(throws: ClaudeUsageError.unsupportedVersion) {
            try ClaudeUsageParser.parseResponseLine(response(
                #""error":"Unsupported control request subtype: get_usage""#, subtype: "error"
            ))
        }
        #expect(throws: ClaudeUsageError.serverError("Usage is temporarily unavailable")) {
            try ClaudeUsageParser.parseResponseLine(response(
                #""error":"Usage is temporarily unavailable""#, subtype: "error"
            ))
        }
        #expect(ClaudeUsageError.unsupportedVersion.errorDescription?.contains("claude update") == true)
        #expect(throws: ClaudeUsageError.missingResult) {
            try ClaudeUsageParser.parseResponseLine(response(#""note":"empty""#))
        }
    }

    @Test("Ignores every other line Claude Code prints")
    func ignoresUnrelatedLines() throws {
        for line in [
            #"{"type":"system","subtype":"init","session_id":"abc"}"#,
            #"{"type":"control_response","response":{"subtype":"success","request_id":"other","response":{}}}"#,
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#,
            "not json",
            "[1,2,3]",
        ] {
            #expect(try ClaudeUsageParser.parseResponseLine(Data(line.utf8)) == nil)
        }
    }

    @Test("Recognizes the result of the activation request")
    func parsesActivationResult() throws {
        #expect(try ClaudeUsageParser.parseActivationLine(
            Data(#"{"type":"result","subtype":"success","is_error":false,"result":"OK"}"#.utf8)
        ) == true)
        #expect(try ClaudeUsageParser.parseActivationLine(Data(#"{"type":"assistant"}"#.utf8)) == nil)
        #expect(throws: ClaudeUsageError.activationFailed("Not logged in · Please run /login")) {
            try ClaudeUsageParser.parseActivationLine(Data(
                #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"#.utf8
            ))
        }
    }

    @Test("Activates an idle window at most once per cooldown")
    func limitsActivation() {
        func snapshot(short: WindowActivityState?, weekly: WindowActivityState?) -> QuotaSnapshot {
            func window(_ state: WindowActivityState?) -> QuotaWindow? {
                state.map { QuotaWindow(durationMinutes: 300, usedPercent: 0, resetsAt: nil, state: $0) }
            }
            return QuotaSnapshot(
                planType: "max", shortWindow: window(short), weeklyWindow: window(weekly), fetchedAt: fetchedAt
            )
        }
        let idle = snapshot(short: .dormant, weekly: .active)
        let now = fetchedAt

        #expect(ClaudeActivationPolicy.shouldActivate(idle, lastAttempt: nil, now: now, isEnabled: true))
        #expect(ClaudeActivationPolicy.shouldActivate(idle, lastAttempt: nil, now: now, isEnabled: false) == false)
        #expect(ClaudeActivationPolicy.shouldActivate(
            idle, lastAttempt: now.addingTimeInterval(-600), now: now, isEnabled: true
        ) == false)
        #expect(ClaudeActivationPolicy.shouldActivate(
            idle, lastAttempt: now.addingTimeInterval(-3_600), now: now, isEnabled: true
        ))
        // A running five-hour window means the weekly one is running too.
        #expect(ClaudeActivationPolicy.hasIdleWindow(snapshot(short: .active, weekly: .dormant)) == false)
        #expect(ClaudeActivationPolicy.hasIdleWindow(snapshot(short: nil, weekly: .dormant)))
        #expect(ClaudeActivationPolicy.hasIdleWindow(snapshot(short: nil, weekly: nil)) == false)
    }

    @Test("Asks Claude Code for usage with the profile's own configuration directory")
    func fetchesThroughCommandLine() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let record = home.appending(path: "invocation.txt")
        let executable = try script(in: home, """
            read request
            {
              printf '%s\\n' "config=${CLAUDE_CONFIG_DIR-unset}" "key=${ANTHROPIC_API_KEY-unset}"
              printf '%s\\n' "$request"
              printf 'arg=%s\\n' "$@"
            } >> '\(record.path)'
            echo '{"type":"system","subtype":"init"}'
            echo '{"type":"control_response","response":{"subtype":"success","request_id":"codex-meter-usage","response":{"subscription_type":"team","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":42,"resets_at":null}}}}}'
            sleep 5
            """)
        let client = ClaudeUsageClient(cli: ClaudeCLI(executableURL: executable, home: home), timeout: 4)
        let work = try profile(".claude-work", in: home)
        let standard = try profile(".claude", in: home)

        let started = Date()
        let snapshot = try await client.fetchRateLimits(for: work)
        _ = try await client.fetchRateLimits(for: standard)

        #expect(Date().timeIntervalSince(started) < 4, "the process is stopped once it answers")
        #expect(snapshot.planType == "team")
        #expect(snapshot.shortWindow?.usedPercent == 42)
        let invocations = try String(contentsOf: record, encoding: .utf8)
        #expect(invocations.contains("config=\(work.homeURL.path)\n"))
        #expect(invocations.contains("config=unset\n"), "the default directory runs without CLAUDE_CONFIG_DIR")
        #expect(invocations.contains("key=unset\n"))
        #expect(invocations.contains(#"{"type":"control_request","request_id":"codex-meter-usage","request":{"subtype":"get_usage","skip_behaviors":true}}"#))
        for argument in ["--print", "--input-format", "stream-json", "--no-session-persistence",
                         "--strict-mcp-config", #"{"disableAllHooks":true}"#] {
            #expect(invocations.contains("arg=\(argument)\n"))
        }
    }

    @Test("Sends one small request to start an idle window")
    func sendsActivationTurn() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let record = home.appending(path: "invocation.txt")
        let executable = try script(in: home, """
            printf 'arg=%s\\n' "$@" >> '\(record.path)'
            if read unexpected; then echo "stdin=open" >> '\(record.path)'; fi
            echo '{"type":"result","subtype":"success","is_error":false,"result":"OK"}'
            """)
        let client = ClaudeUsageClient(cli: ClaudeCLI(executableURL: executable, home: home), activationTimeout: 5)

        try await client.sendActivationTurn(for: try profile(".claude-work", in: home))

        let invocation = try String(contentsOf: record, encoding: .utf8)
        #expect(invocation.hasPrefix("arg=--print\narg=Reply exactly OK.\narg=--model\narg=haiku\n"))
        #expect(invocation.contains("arg=--tools\narg=\narg=--settings\n"))
        #expect(invocation.contains("stdin=open") == false)
    }

    @Test("Reports a missing executable, a silent process and an early exit")
    func reportsCommandLineFailures() async throws {
        let home = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let work = try profile(".claude-work", in: home)

        let missing = ClaudeUsageClient(cli: ClaudeCLI(executableURL: home.appending(path: "absent"), home: home))
        await #expect(throws: ClaudeCLIError.missingExecutable) {
            try await missing.fetchRateLimits(for: work)
        }

        let silent = ClaudeUsageClient(
            cli: ClaudeCLI(executableURL: try script(in: home, "sleep 5", name: "silent"), home: home),
            timeout: 0.5
        )
        await #expect(throws: ClaudeCLIError.timedOut(0.5)) {
            try await silent.fetchRateLimits(for: work)
        }

        let failing = ClaudeUsageClient(
            cli: ClaudeCLI(
                executableURL: try script(in: home, "echo 'Invalid API key' >&2\nexit 3", name: "failing"),
                home: home
            ),
            timeout: 5
        )
        await #expect(throws: ClaudeCLIError.exitedWithoutResponse(status: 3, stderr: "Invalid API key")) {
            try await failing.fetchRateLimits(for: work)
        }

        let gone = CodexProfile(
            id: "gone", displayName: "gone", homeURL: home.appending(path: ".claude-gone"), provider: .claude
        )
        await #expect(throws: ClaudeCLIError.missingProfileHome(gone.homeURL)) {
            try await failing.fetchRateLimits(for: gone)
        }
    }

    @Test("Builds the environment for a Finder-launched app")
    func buildsEnvironment() throws {
        let home = URL(fileURLWithPath: "/Users/tester")
        let cli = ClaudeCLI(home: home)
        let executable = home.appending(path: ".local/bin/claude")
        let base = ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": "/elsewhere", "ANTHROPIC_API_KEY": "sk-test", "HOME": home.path]
        func profile(_ name: String) -> CodexProfile {
            CodexProfile(id: name, displayName: name, homeURL: home.appending(path: name), provider: .claude)
        }

        let named = cli.environment(for: profile(".claude-work"), executable: executable, base: base)
        #expect(named["CLAUDE_CONFIG_DIR"] == "/Users/tester/.claude-work")
        #expect(named["ANTHROPIC_API_KEY"] == nil)
        #expect(named["HOME"] == home.path)
        #expect(named["PATH"] == "/Users/tester/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")

        let standard = cli.environment(for: profile(".claude"), executable: executable, base: base)
        #expect(standard["CLAUDE_CONFIG_DIR"] == nil)
        #expect(ClaudeCLI.executableCandidates(home: home).first == executable)
    }

    private func profile(_ name: String, in home: URL) throws -> CodexProfile {
        let url = home.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return CodexProfile(id: String(name.dropFirst()), displayName: name, homeURL: url, provider: .claude)
    }

    private func script(in directory: URL, _ body: String, name: String = "claude") throws -> URL {
        let url = directory.appending(path: name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "CodexMeterTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
