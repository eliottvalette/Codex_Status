import Foundation
import Testing
@testable import CodexMeter

@Suite("Current weekly cycle pace")
struct UsagePaceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func account(used: Double, elapsedDays: Double, capacity: Double = 1) -> WeeklyObservation {
        WeeklyObservation(
            date: now, used: used,
            reset: now.addingTimeInterval((7 - elapsedDays) * UsagePace.day), capacity: capacity
        )
    }

    @Test("Each account contributes usage divided by its own cycle age")
    func staggeredCycles() throws {
        let current = [
            "pro": account(used: 0.2, elapsedDays: 2, capacity: 10),
            "plus": account(used: 0.4, elapsedDays: 4),
        ]
        let sustainable = try #require(UsagePace.sustainableRate(Array(current.values), now: now))
        let value = try #require(UsagePace.value(current: current, now: now))
        let expected = Int((1.1 / (sustainable * UsagePace.day) * 100).rounded())
        #expect(value.percent == expected)
    }

    @Test("A renewed account contributes only usage in its new cycle")
    func resetClearsUsage() throws {
        let before = try #require(UsagePace.value(
            current: ["a": account(used: 0.99, elapsedDays: 6.9)], now: now
        ))
        let after = try #require(UsagePace.value(
            current: ["a": account(used: 0, elapsedDays: 0.01)], now: now
        ))
        #expect(before.percent > 0)
        #expect(after.percent == 0)
    }

    @Test("Invalid cycle ages and missing accounts suppress the indicator")
    func invalidInputs() {
        #expect(UsagePace.value(current: [:], now: now) == nil)
        #expect(UsagePace.value(current: ["a": account(used: 0.1, elapsedDays: 0)], now: now) == nil)
        #expect(UsagePace.value(current: ["a": account(used: 0.1, elapsedDays: -1)], now: now) == nil)
        #expect(UsagePace.value(current: ["a": account(used: 0.1, elapsedDays: 8)], now: now) == nil)
    }

    @Test("Staggered replenishment prevents a false shared reset")
    func staggeredResets() throws {
        let early = account(used: 0, elapsedDays: 6)
        let late = account(used: 1, elapsedDays: 1)
        let rate = try #require(UsagePace.sustainableRate([early, late], now: now))
        #expect(rate * UsagePace.day <= 2.0 / 6 + 1e-6)
        let delayed = account(used: 1, elapsedDays: 0)
        let delayedRate = try #require(UsagePace.sustainableRate([early, delayed], now: now))
        #expect(delayedRate < rate)
    }

    @Test("Unavailable and stale accounts do not contribute")
    func unavailableAccounts() {
        func status(_ id: String, age: TimeInterval = 0, error: String? = nil) -> ProfileStatus {
            ProfileStatus(
                profile: CodexProfile(id: id, displayName: id, homeURL: URL(fileURLWithPath: "/tmp/\(id)")),
                snapshot: QuotaSnapshot(
                    planType: "prolite", shortWindow: nil,
                    weeklyWindow: QuotaWindow(
                        durationMinutes: 10_080, usedPercent: 10,
                        resetsAt: now.addingTimeInterval(4 * UsagePace.day), state: .active
                    ), fetchedAt: now.addingTimeInterval(-age)
                ), errorMessage: error
            )
        }
        let current = UsagePace.currentObservations([
            status("valid"), status("stale", age: 601), status("signed-out", error: "401 Unauthorized"),
        ], now: now)
        #expect(current.count == 1)
        #expect(current["valid"]?.capacity == 10)
        #expect(current["valid"]?.used == 0.1)
    }
}
