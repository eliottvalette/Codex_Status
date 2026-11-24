import Foundation

enum ProfileProvider: String, Hashable, Sendable {
    case codex
    case claude

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }
}

struct CodexProfile: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let homeURL: URL
    let provider: ProfileProvider

    init(id: String, displayName: String, homeURL: URL, provider: ProfileProvider = .codex) {
        self.id = id
        self.displayName = displayName
        self.homeURL = homeURL
        self.provider = provider
    }

    /// The same profile under another name, as shown in the app.
    func named(_ displayName: String) -> CodexProfile {
        CodexProfile(id: id, displayName: displayName, homeURL: homeURL, provider: provider)
    }

    /// The profiles the app tracks: the compiled Codex list, then every Claude Code profile
    /// found under the home directory. When Claude profiles exist and none of the Codex
    /// directories do, the Codex list is left out.
    static func launchProfiles(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        codex: [CodexProfile] = configured
    ) -> [CodexProfile] {
        let claude = ClaudeProfiles.discover(home: home)
        guard claude.isEmpty == false else { return codex }
        let hasCodexHome = codex.contains { FileManager.default.fileExists(atPath: $0.homeURL.path) }
        return (hasCodexHome ? codex : []) + claude
    }

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

/// A weekly limit that applies to one model only, such as Claude's "Weekly · Fable".
struct ModelQuotaWindow: Equatable, Sendable {
    let name: String
    let window: QuotaWindow

    /// Short enough to sit above a ring.
    var label: String {
        String(name.uppercased().prefix(7)).trimmingCharacters(in: .whitespaces)
    }
}

struct QuotaSnapshot: Equatable, Sendable {
    let planType: String?
    let shortWindow: QuotaWindow?
    let weeklyWindow: QuotaWindow?
    let modelWindows: [ModelQuotaWindow]
    let availableResetCredits: Int?
    let earliestResetCreditExpiresAt: Date?
    let fetchedAt: Date

    init(
        planType: String?,
        shortWindow: QuotaWindow?,
        weeklyWindow: QuotaWindow?,
        modelWindows: [ModelQuotaWindow] = [],
        availableResetCredits: Int? = nil,
        earliestResetCreditExpiresAt: Date? = nil,
        fetchedAt: Date
    ) {
        self.planType = planType
        self.shortWindow = shortWindow
        self.weeklyWindow = weeklyWindow
        self.modelWindows = modelWindows
        self.availableResetCredits = availableResetCredits
        self.earliestResetCreditExpiresAt = earliestResetCreditExpiresAt
        self.fetchedAt = fetchedAt
    }

    /// The per-model window with the least left, among those in use.
    var tightestModelWindow: ModelQuotaWindow? {
        modelWindows
            .filter { $0.window.state != .dormant }
            .min(by: { $0.window.remainingPercent < $1.window.remainingPercent })
    }

    /// Every window that limits the account, single-model ones included.
    var allWindows: [QuotaWindow] {
        [shortWindow, weeklyWindow].compactMap { $0 } + modelWindows.map(\.window)
    }
}

/// Who a Claude profile is signed in as, from `claude auth status`.
enum AccountSignIn: Equatable, Sendable {
    case signedIn(email: String?)
    case signedOut

    var email: String? {
        if case let .signedIn(email) = self { return email }
        return nil
    }
}

struct ProfileStatus: Identifiable, Sendable {
    var profile: CodexProfile
    var snapshot: QuotaSnapshot?
    var signIn: AccountSignIn?
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

struct LowestRemainingQuota: Equatable, Sendable {
    let provider: ProfileProvider
    let percent: Int

    /// The tightest quota window across all profiles, with the provider it belongs to.
    static func find(in statuses: [ProfileStatus]) -> LowestRemainingQuota? {
        statuses
            .flatMap { status -> [LowestRemainingQuota] in
                guard let snapshot = status.snapshot else { return [] }
                return snapshot.allWindows.map {
                    LowestRemainingQuota(
                        provider: status.profile.provider,
                        percent: Int($0.remainingPercent.rounded())
                    )
                }
            }
            .min(by: { $0.percent < $1.percent })
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
