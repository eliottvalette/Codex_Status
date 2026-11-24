import Foundation

enum ClaudeUsageError: Error, Equatable, LocalizedError {
    case serverError(String)
    case unsupportedVersion
    case missingResult
    case planLimitsUnavailable
    case usageTemporarilyUnavailable
    case activationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .serverError(message):
            "Claude Code could not read usage: \(message)"
        case .unsupportedVersion:
            "This Claude Code is too old to report usage. Run `claude update`, then refresh."
        case .missingResult:
            "The Claude usage response did not contain a result."
        case .planLimitsUnavailable:
            "This profile has no Claude plan limits. Sign in with a Claude subscription using /login."
        case .usageTemporarilyUnavailable:
            "Usage is unavailable for now, usually because the usage service is limiting reads. The app tries again in 15 minutes."
        case let .activationFailed(message):
            "Claude Code could not start the usage window: \(message)"
        }
    }
}

/// Reads plan limits through Claude Code itself, so the app never handles credentials.
struct ClaudeUsageClient: Sendable {
    let cli: ClaudeCLI
    let timeout: TimeInterval
    let activationTimeout: TimeInterval

    init(
        cli: ClaudeCLI = ClaudeCLI(),
        timeout: TimeInterval = 20,
        activationTimeout: TimeInterval = 90
    ) {
        self.cli = cli
        self.timeout = timeout
        self.activationTimeout = activationTimeout
    }

    @concurrent
    func fetchRateLimits(for profile: CodexProfile) async throws -> QuotaSnapshot {
        try Task.checkCancellation()
        // A control request with no prompt: Claude Code answers from its usage data
        // without sending anything to a model.
        let request = #"{"type":"control_request","request_id":"\#(ClaudeUsageParser.requestID)","#
            + #""request":{"subtype":"get_usage","skip_behaviors":true}}"# + "\n"
        return try cli.run(
            arguments: [
                "--print", "--verbose",
                "--input-format", "stream-json",
                "--output-format", "stream-json",
            ] + ClaudeCLI.quietArguments,
            for: profile,
            input: Data(request.utf8),
            timeout: timeout,
            onLine: { try ClaudeUsageParser.parseResponseLine($0) }
        )
    }

    /// Asks Claude Code who the profile is signed in as. Never reads the stored sign-in.
    @concurrent
    func fetchSignIn(for profile: CodexProfile) async throws -> AccountSignIn {
        try Task.checkCancellation()
        // The answer is indented JSON over several lines.
        var output = Data()
        return try cli.run(
            arguments: ["auth", "status", "--json"],
            for: profile,
            timeout: timeout,
            onLine: { line in
                // Anything printed before the JSON, such as a warning, is not part of it.
                guard output.isEmpty == false || line.first == UInt8(ascii: "{") else { return nil }
                output.append(line)
                return ClaudeUsageParser.parseSignIn(output)
            }
        )
    }

    /// Sends one short request to the smallest model so an idle window starts counting.
    @concurrent
    func sendActivationTurn(for profile: CodexProfile) async throws {
        try Task.checkCancellation()
        _ = try cli.run(
            arguments: [
                "--print", "Reply exactly OK.",
                "--model", "haiku",
                "--system-prompt", "Reply exactly OK.",
                "--output-format", "json",
            ] + ClaudeCLI.quietArguments,
            for: profile,
            timeout: activationTimeout,
            onLine: { try ClaudeUsageParser.parseActivationLine($0) }
        )
    }
}

enum ClaudeUsageParser {
    static let requestID = "codex-meter-usage"
    private static let shortWindowMinutes = 300
    private static let weeklyWindowMinutes = 10_080

    /// Returns the snapshot when `data` is the answer to the usage request, `nil` for any
    /// other line Claude Code prints.
    static func parseResponseLine(_ data: Data, fetchedAt: Date = .now) throws -> QuotaSnapshot? {
        guard
            let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            envelope["type"] as? String == "control_response",
            let response = envelope["response"] as? [String: Any],
            response["request_id"] as? String == requestID
        else {
            return nil
        }

        if response["subtype"] as? String == "error" {
            let message = response["error"] as? String ?? "Unknown error"
            // Older versions answer every request they do not know with this text.
            if message.hasPrefix("Unsupported control request subtype") {
                throw ClaudeUsageError.unsupportedVersion
            }
            throw ClaudeUsageError.serverError(message)
        }
        guard let result = response["response"] as? [String: Any] else {
            throw ClaudeUsageError.missingResult
        }
        guard result["rate_limits_available"] as? Bool != false else {
            throw ClaudeUsageError.planLimitsUnavailable
        }
        // A signed-in plan with no limits in the answer means Claude Code could not fetch
        // them, for example after the usage service answered 429. That clears by itself.
        guard let rateLimits = result["rate_limits"] as? [String: Any] else {
            throw ClaudeUsageError.usageTemporarilyUnavailable
        }

        return QuotaSnapshot(
            planType: result["subscription_type"] as? String,
            shortWindow: window(
                rateLimits["five_hour"], durationMinutes: shortWindowMinutes, fetchedAt: fetchedAt
            ),
            weeklyWindow: window(
                rateLimits["seven_day"], durationMinutes: weeklyWindowMinutes, fetchedAt: fetchedAt
            ),
            modelWindows: modelWindows(rateLimits, fetchedAt: fetchedAt),
            fetchedAt: fetchedAt
        )
    }

    /// Weekly limits for single models. Newer replies list them under `model_scoped`;
    /// the Opus and Sonnet fields are the older form of the same thing.
    private static func modelWindows(_ rateLimits: [String: Any], fetchedAt: Date) -> [ModelQuotaWindow] {
        var windows: [ModelQuotaWindow] = []
        func add(_ name: String, _ value: Any?) {
            guard
                name.isEmpty == false,
                windows.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) == false,
                let window = window(value, durationMinutes: weeklyWindowMinutes, fetchedAt: fetchedAt)
            else { return }
            windows.append(ModelQuotaWindow(name: name, window: window))
        }
        for case let entry as [String: Any] in rateLimits["model_scoped"] as? [Any] ?? [] {
            add(entry["display_name"] as? String ?? "", entry)
        }
        add("Opus", rateLimits["seven_day_opus"])
        add("Sonnet", rateLimits["seven_day_sonnet"])
        return windows
    }

    /// Returns the sign-in once `data` holds the whole answer of `claude auth status`.
    static func parseSignIn(_ data: Data) -> AccountSignIn? {
        guard let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard status["loggedIn"] as? Bool == true else { return .signedOut }
        return .signedIn(email: status["email"] as? String)
    }

    /// Returns `true` once the final result of the activation request arrives.
    static func parseActivationLine(_ data: Data) throws -> Bool? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["type"] as? String == "result"
        else {
            return nil
        }
        if object["is_error"] as? Bool == true {
            throw ClaudeUsageError.activationFailed(
                object["result"] as? String ?? object["subtype"] as? String ?? "Unknown error"
            )
        }
        return true
    }

    /// A window with no reset time has not started, and one whose reset time has passed is
    /// over. Both are idle, so Claude windows never need the two-reading check Codex does.
    private static func window(_ value: Any?, durationMinutes: Int, fetchedAt: Date) -> QuotaWindow? {
        guard let payload = value as? [String: Any] else { return nil }
        let usedPercent = min(100, max(0, (payload["utilization"] as? NSNumber)?.doubleValue ?? 0))
        let resetsAt: Date?
        switch payload["resets_at"] {
        case let text as String:
            resetsAt = ClaudeTimestamp.parse(text)
        case let seconds as NSNumber:
            resetsAt = Date(timeIntervalSince1970: seconds.doubleValue)
        default:
            resetsAt = nil
        }

        if let resetsAt, resetsAt > fetchedAt {
            return QuotaWindow(
                durationMinutes: durationMinutes, usedPercent: usedPercent,
                resetsAt: resetsAt, state: .active
            )
        }
        if resetsAt == nil, usedPercent > 0 {
            return QuotaWindow(
                durationMinutes: durationMinutes, usedPercent: usedPercent,
                resetsAt: nil, state: .active
            )
        }
        return QuotaWindow(
            durationMinutes: durationMinutes, usedPercent: 0, resetsAt: nil, state: .dormant
        )
    }
}

enum ClaudeUsagePolicy {
    /// After an answer without limits, the account's usage is not read again for this long,
    /// so the app does not keep asking a service that is limiting reads.
    static let retryDelay: TimeInterval = 900
}

enum ClaudeActivationPolicy {
    /// One attempt an hour at most, so a window that stays idle cannot drain quota.
    static let cooldown: TimeInterval = 3_600

    /// The five-hour window decides. Any request starts both windows, so an idle weekly
    /// window matters only for plans that report no five-hour window.
    static func hasIdleWindow(_ snapshot: QuotaSnapshot) -> Bool {
        if let shortWindow = snapshot.shortWindow {
            return shortWindow.state == .dormant
        }
        return snapshot.weeklyWindow?.state == .dormant
    }

    static func shouldActivate(
        _ snapshot: QuotaSnapshot,
        lastAttempt: Date?,
        now: Date = .now,
        isEnabled: Bool
    ) -> Bool {
        guard isEnabled, hasIdleWindow(snapshot) else { return false }
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= cooldown
    }
}

enum ClaudeActivityReader {
    /// The newest change to any conversation transcript of the profile.
    @concurrent
    static func latestActivity(for profile: CodexProfile) async throws -> Date? {
        try ClaudeSessionTransferService.transcriptFiles(in: profile).map(\.modifiedAt).max()
    }
}
