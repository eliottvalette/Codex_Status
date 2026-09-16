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

    @Test("Handles nullable resetsAt and windowDurationMins per official protocol")
    func handlesNullableProtocolFields() throws {
        let response = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":0,"windowDurationMins":null,"resetsAt":null},"secondary":{"usedPercent":10,"windowDurationMins":10080,"resetsAt":null},"planType":"plus"}}}"#
        let parsedSnapshot = try RateLimitParser.parseResponseLine(Data(response.utf8))
        let snapshot = try #require(parsedSnapshot)

        #expect(snapshot.shortWindow == nil)
        #expect(snapshot.weeklyWindow?.usedPercent == 10)
        #expect(snapshot.weeklyWindow?.resetsAt == nil)
        #expect(snapshot.weeklyWindow?.durationMinutes == 10080)
        #expect(snapshot.weeklyWindow?.state == .active)
    }

    @Test("Parses availableResetCredits and earliest expiration from rateLimitResetCredits")
    func parsesAvailableResetCreditsAndEarliestExpiration() throws {
        let response = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":0,"windowDurationMins":300,"resetsAt":1789487671},"secondary":null,"planType":"plus"},"rateLimitResetCredits":{"availableCount":2,"credits":[{"status":"available","expiresAt":1789949608},{"status":"available","expiresAt":1791075943}]}}}"#
        let parsedSnapshot = try RateLimitParser.parseResponseLine(Data(response.utf8))
        let snapshot = try #require(parsedSnapshot)

        #expect(snapshot.availableResetCredits == 2)
        #expect(snapshot.earliestResetCreditExpiresAt == Date(timeIntervalSince1970: 1789949608))
    }

    @Test("Formats profile status header title with credit count and remaining days")
    func formatsHeaderTitleWithCreditsAndDays() {
        let profile = CodexProfile(
            id: "codex",
            displayName: "codex",
            homeURL: URL(fileURLWithPath: "/tmp/codex")
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let statusWithoutSnapshot = ProfileStatus(profile: profile)
        #expect(statusWithoutSnapshot.headerTitle(relativeTo: now) == "codex")

        let snapshotWithCreditsAndExpiration = QuotaSnapshot(
            planType: "plus",
            shortWindow: nil,
            weeklyWindow: nil,
            availableResetCredits: 3,
            earliestResetCreditExpiresAt: now.addingTimeInterval(4.8 * 86_400),
            fetchedAt: now
        )
        var statusWithCredits = ProfileStatus(profile: profile, snapshot: snapshotWithCreditsAndExpiration)
        #expect(statusWithCredits.headerTitle(relativeTo: now) == "codex - 3 - 5d")

        let snapshotExpired = QuotaSnapshot(
            planType: "plus",
            shortWindow: nil,
            weeklyWindow: nil,
            availableResetCredits: 1,
            earliestResetCreditExpiresAt: now.addingTimeInterval(-100),
            fetchedAt: now
        )
        statusWithCredits.snapshot = snapshotExpired
        #expect(statusWithCredits.headerTitle(relativeTo: now) == "codex - 1 - 0d")
    }
}
