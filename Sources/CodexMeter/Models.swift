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

struct QuotaWindow: Equatable, Sendable {
    let durationMinutes: Int
    let usedPercent: Double
    let resetsAt: Date

    var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }
}

struct QuotaSnapshot: Equatable, Sendable {
    let planType: String?
    let shortWindow: QuotaWindow?
    let weeklyWindow: QuotaWindow?
    let fetchedAt: Date
}

struct ProfileStatus: Identifiable, Sendable {
    let profile: CodexProfile
    var snapshot: QuotaSnapshot?
    var errorMessage: String?
    var lastActivity: Date?
    var activityErrorMessage: String?
    var isRefreshing: Bool

    var id: String { profile.id }

    var isStale: Bool {
        snapshot != nil && errorMessage != nil
    }
}
