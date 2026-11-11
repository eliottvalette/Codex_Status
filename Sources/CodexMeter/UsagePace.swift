import Foundation

struct WeeklyObservation: Codable {
    let date: Date
    let used: Double
    let reset: Date
    let capacity: Double
}

struct PaceValue {
    let percent: Int

    var label: String { "Cycle \(percent)%" }

}

enum UsagePace {
    static let day: TimeInterval = 86_400
    static let week = 7 * day
    static func observation(_ snapshot: QuotaSnapshot) -> WeeklyObservation? {
        guard let window = snapshot.weeklyWindow,
              let reset = window.resetsAt,
              let plan = snapshot.planType?.lowercased(),
              ["pro", "prolite", "plus"].contains(plan),
              window.usedPercent.isFinite,
              (0...100).contains(window.usedPercent)
        else { return nil }
        return WeeklyObservation(
            date: snapshot.fetchedAt, used: window.usedPercent / 100,
            reset: reset, capacity: plan == "plus" ? 1 : 10
        )
    }

    static func currentObservations(_ statuses: [ProfileStatus], now: Date) -> [String: WeeklyObservation] {
        var current: [String: WeeklyObservation] = [:]
        for status in statuses {
            guard status.errorMessage == nil,
                  let snapshot = status.snapshot,
                  now.timeIntervalSince(snapshot.fetchedAt) <= 600,
                  let observation = observation(snapshot),
                  observation.reset > now
            else { continue }
            current[status.id] = observation
        }
        return current
    }

    // Spend the capacity that expires first before drawing on later-resetting accounts.
    // Replenishment replaces the remaining balance; unused capacity does not accumulate.
    static func sustainableRate(_ accounts: [WeeklyObservation], now: Date) -> Double? {
        guard !accounts.isEmpty, accounts.allSatisfy({ $0.reset > now }) else { return nil }
        let renewalRate = accounts.reduce(0) { $0 + $1.capacity } / week
        func canSustain(_ rate: Double) -> Bool {
            var balances = accounts.map { (1 - $0.used) * $0.capacity }
            var resets = accounts.map(\.reset)
            var time = now
            let end = now.addingTimeInterval(2 * week)
            while time < end {
                let next = min(resets.min()!, end)
                var demand = rate * next.timeIntervalSince(time)
                for index in accounts.indices.sorted(by: { resets[$0] < resets[$1] }) {
                    let spent = min(balances[index], demand)
                    balances[index] -= spent
                    demand -= spent
                }
                if demand > 1e-9 { return false }
                time = next
                for index in accounts.indices where resets[index] <= time {
                    balances[index] = accounts[index].capacity
                    resets[index] = resets[index].addingTimeInterval(week)
                }
            }
            return true
        }
        var lower = 0.0
        var upper = renewalRate
        for _ in 0..<50 {
            let middle = (lower + upper) / 2
            if canSustain(middle) { lower = middle } else { upper = middle }
        }
        return lower > 1e-12 ? lower : nil
    }

    static func value(current: [String: WeeklyObservation], now: Date) -> PaceValue? {
        guard let sustainable = sustainableRate(Array(current.values), now: now) else { return nil }
        var totalRate = 0.0
        for account in current.values {
            // Weekly quota usage is cumulative from this account's own cycle start.
            let start = account.reset.addingTimeInterval(-week)
            let elapsed = account.date.timeIntervalSince(start)
            guard elapsed > 0, elapsed <= week else { return nil }
            totalRate += account.used * account.capacity / elapsed
        }
        let ratio = totalRate / sustainable * 100
        guard ratio.isFinite, ratio >= 0, ratio < Double(Int.max) else { return nil }
        return PaceValue(percent: Int(ratio.rounded()))
    }
}
