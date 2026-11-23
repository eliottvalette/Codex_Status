import Foundation

struct CodexProfile: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let homeURL: URL

    static let configured: [CodexProfile] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            CodexProfile(id: "codex", displayName: "codex", homeURL: home.appending(path: ".codex")),
            CodexProfile(id: "codex-yot", displayName: "codex-yot", homeURL: home.appending(path: ".codex-yot")),
            CodexProfile(id: "codex-matt", displayName: "codex-matt", homeURL: home.appending(path: ".codex-matt")),
            CodexProfile(id: "codex-bio", displayName: "codex-bio", homeURL: home.appending(path: ".codex-bio")),
        ]
    }()
}

enum WindowActivityState: String, Equatable, Sendable {
    case unavailable
    case unknown
    case dormant
    case active
}

struct QuotaWindow: Equatable, Sendable {
    let durationMinutes: Int?
    let usedPercent: Double
    let resetsAt: Date?
    var state: WindowActivityState

    var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }
}

enum WindowClassifier {
    static func classify(
        previous: QuotaWindow?,
        current: QuotaWindow,
        elapsedSeconds: TimeInterval
    ) -> WindowActivityState {
        if current.usedPercent > 0 {
            return .active
        }
        guard let previous, elapsedSeconds >= 3.0 else {
            return .unknown
        }
        guard let currentResetsAt = current.resetsAt, let previousResetsAt = previous.resetsAt else {
            return .unknown
        }
        let resetShift = currentResetsAt.timeIntervalSince(previousResetsAt)
        if abs(resetShift) <= 1.5 {
            return .active
        }
        let toleranceSeconds = max(2.5, elapsedSeconds * 0.05)
        if abs(resetShift - elapsedSeconds) <= toleranceSeconds {
            return .dormant
        }
        return .unknown
    }
}

struct QuotaSnapshot: Equatable, Sendable {
    let planType: String?
    let shortWindow: QuotaWindow?
    let weeklyWindow: QuotaWindow?
    let availableResetCredits: Int?
    let earliestResetCreditExpiresAt: Date?
    let fetchedAt: Date

    init(
        planType: String?,
        shortWindow: QuotaWindow?,
        weeklyWindow: QuotaWindow?,
        availableResetCredits: Int? = nil,
        earliestResetCreditExpiresAt: Date? = nil,
        fetchedAt: Date
    ) {
        self.planType = planType
        self.shortWindow = shortWindow
        self.weeklyWindow = weeklyWindow
        self.availableResetCredits = availableResetCredits
        self.earliestResetCreditExpiresAt = earliestResetCreditExpiresAt
        self.fetchedAt = fetchedAt
    }
}

struct ProfileStatus: Identifiable, Sendable {
    let profile: CodexProfile
    var snapshot: QuotaSnapshot?
    var errorMessage: String?
    var lastActivity: Date?
    var activityErrorMessage: String?
    var isRefreshing: Bool

    init(
        profile: CodexProfile,
        snapshot: QuotaSnapshot? = nil,
        errorMessage: String? = nil,
        lastActivity: Date? = nil,
        activityErrorMessage: String? = nil,
        isRefreshing: Bool = false
    ) {
        self.profile = profile
        self.snapshot = snapshot
        self.errorMessage = errorMessage
        self.lastActivity = lastActivity
        self.activityErrorMessage = activityErrorMessage
        self.isRefreshing = isRefreshing
    }

    var id: String { profile.id }

    var isStale: Bool {
        snapshot != nil && errorMessage != nil
    }

    func headerTitle(relativeTo now: Date = .now) -> String {
        guard let availableCredits = snapshot?.availableResetCredits else {
            return profile.displayName
        }
        if availableCredits > 0, let expiresAt = snapshot?.earliestResetCreditExpiresAt {
            let remainingSeconds = max(0, expiresAt.timeIntervalSince(now))
            if remainingSeconds < 2 * 86_400 {
                let hours = Int(remainingSeconds / 3_600)
                return "\(profile.displayName) - \(availableCredits) - \(hours / 24)d \(hours % 24)h"
            }
            let days = max(0, Int(ceil(remainingSeconds / 86_400)))
            return "\(profile.displayName) - \(availableCredits) - \(days)d"
        }
        return "\(profile.displayName) - \(availableCredits)"
    }
}

struct TransferFeedback: Equatable, Sendable {
    enum Style: Equatable, Sendable {
        case progress
        case success
        case failure
    }

    let style: Style
    let message: String
    var detail: String? = nil
}
