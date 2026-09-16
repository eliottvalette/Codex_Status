import Foundation

enum RateLimitParserError: Error, Equatable, LocalizedError {
    case invalidJSON
    case serverError(String)
    case missingResult
    case missingMainCodexBucket

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            "Codex app-server returned invalid JSON."
        case let .serverError(message):
            "Codex app-server error: \(message)"
        case .missingResult:
            "The rate-limit response did not contain a result."
        case .missingMainCodexBucket:
            "The rate-limit response did not contain the main 'codex' bucket."
        }
    }
}

enum RateLimitParser {
    private static let responseID = 2
    private static let shortWindowMinutes = 300
    private static let weeklyWindowMinutes = 10_080

    static func parseResponseLine(_ data: Data, fetchedAt: Date = .now) throws -> QuotaSnapshot? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let envelope = object as? [String: Any]
        else {
            throw RateLimitParserError.invalidJSON
        }

        guard let id = envelope["id"] as? Int, id == responseID else {
            return nil
        }

        if let error = envelope["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown server error"
            throw RateLimitParserError.serverError(message)
        }

        guard let resultObject = envelope["result"] else {
            throw RateLimitParserError.missingResult
        }

        let resultData = try JSONSerialization.data(withJSONObject: resultObject)
        let response = try JSONDecoder().decode(RateLimitsResult.self, from: resultData)

        let mainBucket: RateLimitBucket?
        if let buckets = response.rateLimitsByLimitId {
            mainBucket = buckets["codex"]
        } else if response.rateLimits?.limitId == "codex" {
            mainBucket = response.rateLimits
        } else {
            mainBucket = nil
        }

        guard let mainBucket else {
            throw RateLimitParserError.missingMainCodexBucket
        }

        let windows = [mainBucket.primary, mainBucket.secondary].compactMap { $0 }
        return QuotaSnapshot(
            planType: mainBucket.planType,
            shortWindow: windows.first(where: { $0.windowDurationMins == shortWindowMinutes })?.model,
            weeklyWindow: windows.first(where: { $0.windowDurationMins == weeklyWindowMinutes })?.model,
            fetchedAt: fetchedAt
        )
    }
}

private struct RateLimitsResult: Decodable {
    let rateLimits: RateLimitBucket?
    let rateLimitsByLimitId: [String: RateLimitBucket]?
}

private struct RateLimitBucket: Decodable {
    let limitId: String
    let primary: RateLimitWindowPayload?
    let secondary: RateLimitWindowPayload?
    let planType: String?
}

private struct RateLimitWindowPayload: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: TimeInterval?

    var model: QuotaWindow {
        QuotaWindow(
            durationMinutes: windowDurationMins,
            usedPercent: usedPercent,
            resetsAt: resetsAt.map { Date(timeIntervalSince1970: $0) },
            state: usedPercent > 0 ? .active : .unknown
        )
    }
}
