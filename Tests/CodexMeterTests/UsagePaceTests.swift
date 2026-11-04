import Foundation
import Testing
@testable import CodexMeter

@Suite("Global weekly usage pace")
struct UsagePaceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(_ daysAgo: Double, used: Double, resetIn: Double = 4, capacity: Double = 1) -> WeeklyObservation {
        WeeklyObservation(
            date: now.addingTimeInterval(-daysAgo * UsagePace.day), used: used,
            reset: now.addingTimeInterval(resetIn * UsagePace.day), capacity: capacity
        )
    }

    private func status(_ id: String, plan: String = "plus", error: String? = nil, age: TimeInterval = 0) -> ProfileStatus {
        ProfileStatus(
            profile: CodexProfile(id: id, displayName: id, homeURL: URL(fileURLWithPath: "/tmp/\(id)")),
            snapshot: QuotaSnapshot(
                planType: plan, shortWindow: nil,
                weeklyWindow: QuotaWindow(
                    durationMinutes: 10_080, usedPercent: 10,
                    resetsAt: now.addingTimeInterval(4 * UsagePace.day), state: .active
                ),
                fetchedAt: now.addingTimeInterval(-age)
            ),
            errorMessage: error
        )
    }

    @Test("Prolite is normalized to ten Plus capacities")
    func proliteWeight() throws {
        let snapshot = try #require(status("bio", plan: "prolite").snapshot)
        let observation = try #require(UsagePace.observation(snapshot))
        #expect(observation.capacity == 10)
        #expect(observation.used == 0.1)
    }

    @Test("Signed-out accounts do not block pace or contribute stale capacity or usage")
    func signedOutAccount() {
        let statuses = [status("a"), status("ster", plan: "prolite", error: "401 Unauthorized")]
        let current = UsagePace.currentObservations(statuses, now: now)
        #expect(current.count == 1)
        #expect(current["ster"] == nil)
        let history = [
            "a": [sample(0.5, used: 0), sample(0, used: 0.1)],
            "ster": [sample(0.5, used: 0, capacity: 10), sample(0, used: 1, capacity: 10)],
        ]
        let values = UsagePace.values(history: history, current: current, now: now)
        let baseline = UsagePace.values(history: history, current: ["a": sample(0, used: 0.1)], now: now)
        #expect(values.count == 2)
        #expect(values.map(\.percent) == baseline.map(\.percent))
    }

    @Test("Missing and stale accounts are excluded; all unavailable accounts produce no indicator")
    func unavailableAccounts() {
        let missing = ProfileStatus(profile: status("missing").profile)
        let current = UsagePace.currentObservations([missing, status("stale", age: 601)], now: now)
        #expect(current.isEmpty)
        #expect(UsagePace.values(history: [:], current: current, now: now).isEmpty)
    }

    @Test("Partial history yields both windows immediately after usage changes")
    func partialHistory() {
        let latest = sample(0, used: 0.1)
        let values = UsagePace.values(
            history: ["a": [sample(0.5, used: 0), latest]], current: ["a": latest], now: now
        )
        #expect(values.count == 2)
        #expect(values.allSatisfy { $0.estimated })
        #expect(values[0].percent == values[1].percent)
        #expect(abs(values[0].coverage - UsagePace.day / 2) < 1)
    }

    @Test("Rolling windows diverge after three days")
    func rollingWindows() {
        let latest = sample(0, used: 0.5)
        let values = UsagePace.values(
            history: ["a": [sample(5, used: 0), sample(3, used: 0.4), latest]],
            current: ["a": latest], now: now
        )
        #expect(values.count == 2)
        #expect(values[0].percent < values[1].percent)
    }

    @Test("Complete regularly sampled history removes the estimate marker independently")
    func completeHistory() throws {
        let samples = (0...432).map { index in
            sample(3 - Double(index) / 144, used: Double(index) / 1_000)
        }
        let latest = try #require(samples.last)
        let values = UsagePace.values(history: ["a": samples], current: ["a": latest], now: now)
        #expect(values.count == 2)
        #expect(values[0].estimated == false)
        #expect(values[1].estimated)
    }

    @Test("Staggered replenishment prevents a false shared reset")
    func staggeredResets() throws {
        let early = sample(0, used: 0, resetIn: 1)
        let late = sample(0, used: 1, resetIn: 6)
        let rate = try #require(UsagePace.sustainableRate([early, late], now: now))
        // At most two Plus units can be consumed before the second account resets on day six.
        #expect(rate * UsagePace.day <= 2.0 / 6 + 1e-6)
        let delayed = sample(0, used: 1, resetIn: 7)
        let delayedRate = try #require(UsagePace.sustainableRate([early, delayed], now: now))
        #expect(delayedRate < rate)
    }

    @Test("Pro contributes ten Plus capacities")
    func proWeight() throws {
        let plus = try #require(UsagePace.sustainableRate([sample(0, used: 0)], now: now))
        let pro = try #require(UsagePace.sustainableRate([sample(0, used: 0, capacity: 10)], now: now))
        #expect(abs(pro / plus - 10) < 1e-6)
    }

    @Test("A reset does not erase observed consumption and makes the result approximate")
    func resetCrossing() {
        let latest = sample(0, used: 0.1, resetIn: 6)
        let history = [sample(2, used: 0.8, resetIn: -1), latest]
        let values = UsagePace.values(history: ["a": history], current: ["a": latest], now: now)
        #expect(values.count == 2)
        #expect(values.allSatisfy { $0.percent > 0 && $0.estimated })
    }

    @Test("Missing account history and stale reset times suppress the global result")
    func incompleteInputs() {
        let latest = sample(0, used: 0.2)
        #expect(UsagePace.values(history: [:], current: ["a": latest], now: now).isEmpty)
        #expect(UsagePace.sustainableRate([sample(0, used: 0.2, resetIn: -1)], now: now) == nil)
    }

    @Test("Observation history survives encoding without losing reset times")
    func persistenceRoundTrip() throws {
        let history = ["a": [sample(0.5, used: 0), sample(0, used: 0.1, capacity: 10)]]
        let data = try JSONEncoder().encode(history)
        let restored = try JSONDecoder().decode([String: [WeeklyObservation]].self, from: data)
        #expect(restored["a"]?.last?.capacity == 10)
        #expect(restored["a"]?.last?.reset == history["a"]?.last?.reset)
    }
}
