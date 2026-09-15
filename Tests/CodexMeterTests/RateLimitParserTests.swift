import Foundation
import Testing
@testable import CodexMeter

@Suite("Rate-limit response parsing")
struct RateLimitParserTests {
    @Test("Parses five-hour and weekly windows from the main Codex bucket")
    func parsesStandardMainBucket() throws {
        let response = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":95,"windowDurationMins":300,"resetsAt":1789487671},"secondary":{"usedPercent":66,"windowDurationMins":10080,"resetsAt":1789838904},"planType":"plus"},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":95,"windowDurationMins":300,"resetsAt":1789487671},"secondary":{"usedPercent":66,"windowDurationMins":10080,"resetsAt":1789838904},"planType":"plus"}}}}"#

        let parsedSnapshot = try RateLimitParser.parseResponseLine(
            Data(response.utf8),
            fetchedAt: .distantPast
        )
        let snapshot = try #require(parsedSnapshot)

        #expect(snapshot.planType == "plus")
        #expect(snapshot.shortWindow?.usedPercent == 95)
        #expect(snapshot.shortWindow?.remainingPercent == 5)
        #expect(snapshot.weeklyWindow?.usedPercent == 66)
        #expect(snapshot.fetchedAt == .distantPast)
    }

    @Test("Ignores model-specific buckets and keeps Bio's weekly-only main quota")
    func ignoresModelSpecificBucket() throws {
        let response = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":50,"windowDurationMins":10080,"resetsAt":1789810623},"secondary":null,"planType":"prolite"},"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":50,"windowDurationMins":10080,"resetsAt":1789810623},"secondary":null,"planType":"prolite"},"codex_bengalfox":{"limitId":"codex_bengalfox","primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1789500847},"secondary":{"usedPercent":0,"windowDurationMins":10080,"resetsAt":1790087647},"planType":"prolite"}}}}"#

        let parsedSnapshot = try RateLimitParser.parseResponseLine(Data(response.utf8))
        let snapshot = try #require(parsedSnapshot)

        #expect(snapshot.planType == "prolite")
        #expect(snapshot.shortWindow == nil)
        #expect(snapshot.weeklyWindow?.usedPercent == 50)
    }

    @Test("Rejects a response without the main Codex bucket")
    func rejectsMissingMainBucket() {
        let response = #"{"id":2,"result":{"rateLimits":null,"rateLimitsByLimitId":{"codex_bengalfox":{"limitId":"codex_bengalfox","primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1789500847},"secondary":null,"planType":"prolite"}}}}"#

        #expect(throws: RateLimitParserError.missingMainCodexBucket) {
            try RateLimitParser.parseResponseLine(Data(response.utf8))
        }
    }

    @Test("Ignores unrelated app-server notifications")
    func ignoresNotifications() throws {
        let notification = #"{"method":"account/rateLimits/updated","params":{}}"#
        let snapshot = try RateLimitParser.parseResponseLine(Data(notification.utf8))
        #expect(snapshot == nil)
    }
}
