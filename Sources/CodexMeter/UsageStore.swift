import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class UsageStore {
    private(set) var statuses: [ProfileStatus]
    private(set) var isRefreshing = false
    private(set) var isActivating = false
    private(set) var transferSourceID: String?
    private(set) var transferDestinationID: String?
    private(set) var transferFeedback: TransferFeedback?
    private(set) var recentChats: [RecentClaudeChat] = []
    private(set) var isSyncing = false
    private var hasPendingActivationCycle = false
    private var feedbackClearTask: Task<Void, Never>?

    private var lastClaudeActivationAttempts: [String: Date] = [:]

    private let clients: ProviderClients
    private let transferService: SessionTransferService
    private let claudeTransferService: ClaudeSessionTransferService
    private let chatCatalog: ClaudeChatCatalog
    private let refreshInterval: Duration

    init(
        profiles: [CodexProfile] = CodexProfile.launchProfiles(),
        client: AppServerClient = AppServerClient(),
        claudeClient: ClaudeUsageClient = ClaudeUsageClient(),
        transferService: SessionTransferService = SessionTransferService(),
        claudeTransferService: ClaudeSessionTransferService = ClaudeSessionTransferService(),
        chatCatalog: ClaudeChatCatalog = ClaudeChatCatalog(),
        refreshInterval: Duration = .seconds(120)
    ) {
        statuses = profiles.map {
            ProfileStatus(
                profile: $0,
                snapshot: nil,
                errorMessage: nil,
                lastActivity: nil,
                activityErrorMessage: nil,
                isRefreshing: false
            )
        }
        clients = ProviderClients(codex: client, claude: claudeClient)
        self.transferService = transferService
        self.claudeTransferService = claudeTransferService
        self.chatCatalog = chatCatalog
        self.refreshInterval = refreshInterval
    }

    func paceValue(relativeTo now: Date) -> PaceValue? {
        let current = UsagePace.currentObservations(statuses, now: now)
        return UsagePace.value(current: current, now: now)
    }

    var isTransferring: Bool {
        transferDestinationID != nil || isSyncing
    }

    func syncRecentConversations() async {
        guard !isTransferring else { return }
        feedbackClearTask?.cancel()
        transferSourceID = nil
        isSyncing = true
        defer { isSyncing = false }
        transferFeedback = TransferFeedback(style: .progress, message: "Syncing the last 10 days…")
        do {
            let result = try await transferService.syncRecentSessions(across: statuses.map(\.profile))
            if result.issues.isEmpty {
                transferFeedback = TransferFeedback(
                    style: .success,
                    message: "Sync complete · \(result.updatedCount) copies updated"
                )
                scheduleFeedbackClear()
            } else {
                transferFeedback = TransferFeedback(
                    style: .failure,
                    message: "Sync finished · \(result.updatedCount) updated · \(result.issues.count) skipped",
                    detail: result.issues.joined(separator: "\n")
                )
            }
        } catch {
            transferFeedback = TransferFeedback(style: .failure, message: error.localizedDescription)
        }
    }

    func cancelTransferSelection() {
        guard isTransferring == false else { return }
        transferSourceID = nil
        transferFeedback = nil
    }

    func handleProfileTap(_ profileID: String) async {
        guard isTransferring == false else { return }
        guard let tappedProfile = statuses.first(where: { $0.id == profileID })?.profile else {
            transferFeedback = TransferFeedback(
                style: .failure,
                message: "Unknown account: \(profileID)"
            )
            return
        }

        guard let sourceID = transferSourceID else {
            feedbackClearTask?.cancel()
            transferFeedback = nil
            transferSourceID = tappedProfile.id
            return
        }

        guard sourceID != tappedProfile.id else { return }

        guard let sourceProfile = statuses.first(where: { $0.id == sourceID })?.profile else {
            transferSourceID = nil
            transferFeedback = TransferFeedback(
                style: .failure,
                message: "Source account not found: \(sourceID)"
            )
            return
        }

        // Codex and Claude Code store conversations in formats the other cannot resume.
        guard sourceProfile.provider == tappedProfile.provider else {
            feedbackClearTask?.cancel()
            transferFeedback = TransferFeedback(
                style: .failure,
                message: "\(sourceProfile.displayName) → pick another \(sourceProfile.provider.displayName) account"
            )
            return
        }

        transferDestinationID = tappedProfile.id
        transferFeedback = TransferFeedback(
            style: .progress,
            message: "Copying to \(tappedProfile.displayName)…"
        )

        do {
            let result: SessionTransferResult
            switch sourceProfile.provider {
            case .codex:
                result = try await transferService.transferRecentSessions(
                    from: sourceProfile,
                    to: tappedProfile
                )
            case .claude:
                result = try await claudeTransferService.transferRecentSessions(
                    from: sourceProfile,
                    to: tappedProfile
                )
            }
            transferSourceID = nil
            transferDestinationID = nil

            let message: String
            let sessionLabel = result.sessionCount == 1 ? "conversation" : "conversations"
            if result.alreadyPresentCount == 0 {
                message = "✓ \(result.sessionCount) \(sessionLabel) copied to \(tappedProfile.displayName)"
            } else if result.copiedCount == 0 {
                message = "✓ \(result.sessionCount) \(sessionLabel) already present on \(tappedProfile.displayName)"
            } else {
                let copiedLabel = result.copiedCount == 1 ? "conversation copied" : "conversations copied"
                message = "✓ \(result.copiedCount) \(copiedLabel), \(result.alreadyPresentCount) already present"
            }
            transferFeedback = TransferFeedback(style: .success, message: message)
            scheduleFeedbackClear()
        } catch {
            transferSourceID = nil
            transferDestinationID = nil
            transferFeedback = TransferFeedback(style: .failure, message: error.localizedDescription)
        }
    }

    var claudeProfiles: [CodexProfile] {
        statuses.map(\.profile).filter { $0.provider == .claude }
    }

    /// The list of recent chats only has a use when a chat can go to another account.
    var showsRecentChats: Bool {
        claudeProfiles.count >= 2
    }

    func reloadRecentChats() async {
        guard showsRecentChats else {
            recentChats = []
            return
        }
        recentChats = await chatCatalog.recentChats(in: claudeProfiles)
    }

    /// Copies one conversation from the recent-chats list. The original stays where it is.
    func copyChat(_ chat: RecentClaudeChat, to destinationID: String) async {
        guard isTransferring == false else { return }
        guard
            let source = claudeProfiles.first(where: { $0.id == chat.profileID }),
            let destination = claudeProfiles.first(where: { $0.id == destinationID })
        else {
            transferFeedback = TransferFeedback(
                style: .failure,
                message: "Unknown account: \(destinationID)"
            )
            return
        }

        feedbackClearTask?.cancel()
        transferSourceID = nil
        transferDestinationID = destination.id
        transferFeedback = TransferFeedback(
            style: .progress,
            message: "Copying to \(destination.displayName)…"
        )

        do {
            let result = try await claudeTransferService.transferSession(
                chat.file, from: source, to: destination
            )
            let title = chat.title.count > 32 ? chat.title.prefix(31) + "…" : chat.title
            let message = result.copiedCount == 0
                ? "✓ “\(title)” already on \(destination.displayName)"
                : "✓ “\(title)” copied to \(destination.displayName)"
            transferFeedback = TransferFeedback(style: .success, message: message)
            scheduleFeedbackClear()
        } catch {
            transferFeedback = TransferFeedback(style: .failure, message: error.localizedDescription)
        }
        transferDestinationID = nil
        await reloadRecentChats()
    }

    private func scheduleFeedbackClear() {
        feedbackClearTask?.cancel()
        feedbackClearTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            self?.transferFeedback = nil
        }
    }

    var lowestRemainingPercent: Int? {
        statuses
            .compactMap(\.snapshot)
            .flatMap { [$0.shortWindow, $0.weeklyWindow] }
            .compactMap { $0 }
            .map { Int($0.remainingPercent.rounded()) }
            .min()
    }

    var lowestRemaining: LowestRemainingQuota? {
        LowestRemainingQuota.find(in: statuses)
    }

    var mostRecentProfileID: String? {
        statuses
            .compactMap { status in
                status.lastActivity.map { (status.id, $0) }
            }
            .max(by: { $0.1 < $1.1 })?
            .0
    }

    func monitor() async {
        let wakeTask = Task { [weak self] in
            let wakeNotifications = NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification)
            for await _ in wakeNotifications {
                guard let self else { break }
                await self.performActivationCycle()
            }
        }
        defer {
            wakeTask.cancel()
        }

        await performActivationCycle()

        while Task.isCancelled == false {
            do {
                try await Task.sleep(for: refreshInterval)
            } catch {
                return
            }
            await refresh()
        }
    }

    func refresh() async {
        guard isRefreshing == false else { return }
        isRefreshing = true
        for index in statuses.indices {
            statuses[index].isRefreshing = true
        }

        let profiles = statuses.map(\.profile)
        let clients = self.clients

        await withTaskGroup(of: FetchResult.self) { group in
            for profile in profiles {
                group.addTask {
                    let activityOutcome: ActivityOutcome
                    do {
                        activityOutcome = .success(try await clients.latestActivity(for: profile))
                    } catch {
                        activityOutcome = .failure(error.localizedDescription)
                    }

                    do {
                        let snapshot = try await clients.fetchRateLimits(for: profile)
                        return FetchResult(
                            profileID: profile.id,
                            quotaOutcome: .success(snapshot),
                            activityOutcome: activityOutcome
                        )
                    } catch {
                        return FetchResult(
                            profileID: profile.id,
                            quotaOutcome: .failure(error.localizedDescription),
                            activityOutcome: activityOutcome
                        )
                    }
                }
            }

            for await result in group {
                guard let index = statuses.firstIndex(where: { $0.id == result.profileID }) else {
                    continue
                }
                statuses[index].isRefreshing = false
                switch result.quotaOutcome {
                case let .success(newSnapshot):
                    let previousSnapshot = statuses[index].snapshot
                    let updatedSnapshot = classifySnapshot(
                        newSnapshot: newSnapshot,
                        previousSnapshot: previousSnapshot,
                        provider: statuses[index].profile.provider
                    )
                    statuses[index].snapshot = updatedSnapshot
                    statuses[index].errorMessage = nil
                case let .failure(message):
                    statuses[index].errorMessage = message
                }

                switch result.activityOutcome {
                case let .success(date):
                    statuses[index].lastActivity = date
                    statuses[index].activityErrorMessage = nil
                case let .failure(message):
                    statuses[index].activityErrorMessage = message
                }
            }
        }

        await reloadRecentChats()
        isRefreshing = false
        await handlePostRefresh()
    }

    func performActivationCycle() async {
        if isActivating || isRefreshing {
            hasPendingActivationCycle = true
            return
        }
        hasPendingActivationCycle = true
        await refresh()
    }

    private var hasDormantOrUnconfirmedZeroUsageWindow: Bool {
        statuses.contains { status in
            guard let snapshot = status.snapshot else { return false }
            if status.profile.provider == .claude {
                return ClaudeActivationPolicy.shouldActivate(
                    snapshot, lastAttempt: lastClaudeActivationAttempts[status.id]
                )
            }
            let shortCandidate = snapshot.shortWindow.map { $0.usedPercent == 0 && $0.state != .active } ?? false
            let weeklyCandidate = snapshot.weeklyWindow.map { $0.usedPercent == 0 && $0.state != .active } ?? false
            return shortCandidate || weeklyCandidate
        }
    }

    private func handlePostRefresh() async {
        guard isActivating == false else { return }
        if hasPendingActivationCycle || hasDormantOrUnconfirmedZeroUsageWindow {
            hasPendingActivationCycle = false
            await runActivationCycle()
        }
    }

    private func runActivationCycle() async {
        guard isActivating == false else {
            hasPendingActivationCycle = true
            return
        }
        isActivating = true
        defer {
            isActivating = false
            if hasPendingActivationCycle {
                hasPendingActivationCycle = false
                Task { [weak self] in
                    await self?.performActivationCycle()
                }
            }
        }

        var dormantProfiles: [CodexProfile] = []
        var probeCandidateProfiles: [(profile: CodexProfile, snapshot: QuotaSnapshot)] = []

        for status in statuses {
            guard let snapshot = status.snapshot else { continue }
            if status.profile.provider == .claude {
                // Claude reports an idle window directly, so no second reading is needed.
                if ClaudeActivationPolicy.shouldActivate(
                    snapshot, lastAttempt: lastClaudeActivationAttempts[status.id]
                ) {
                    dormantProfiles.append(status.profile)
                }
                continue
            }
            let isShortDormant = snapshot.shortWindow?.state == .dormant
            let isWeeklyDormant = snapshot.weeklyWindow?.state == .dormant
            if isShortDormant || isWeeklyDormant {
                dormantProfiles.append(status.profile)
                continue
            }

            let isShortCandidate = snapshot.shortWindow.map { $0.usedPercent == 0 && $0.state != .active } ?? false
            let isWeeklyCandidate = snapshot.weeklyWindow.map { $0.usedPercent == 0 && $0.state != .active } ?? false
            if isShortCandidate || isWeeklyCandidate {
                probeCandidateProfiles.append((profile: status.profile, snapshot: snapshot))
            }
        }

        if probeCandidateProfiles.isEmpty == false {
            do {
                try await Task.sleep(for: .seconds(6))
            } catch {
                return
            }

            for candidate in probeCandidateProfiles {
                do {
                    let secondSnapshot = try await clients.fetchRateLimits(for: candidate.profile)
                    let elapsedSeconds = secondSnapshot.fetchedAt.timeIntervalSince(candidate.snapshot.fetchedAt)

                    let classifiedShortWindow = secondSnapshot.shortWindow.map { currentWindow in
                        var updated = currentWindow
                        updated.state = WindowClassifier.classify(
                            previous: candidate.snapshot.shortWindow,
                            current: currentWindow,
                            elapsedSeconds: elapsedSeconds
                        )
                        return updated
                    }

                    let classifiedWeeklyWindow = secondSnapshot.weeklyWindow.map { currentWindow in
                        var updated = currentWindow
                        updated.state = WindowClassifier.classify(
                            previous: candidate.snapshot.weeklyWindow,
                            current: currentWindow,
                            elapsedSeconds: elapsedSeconds
                        )
                        return updated
                    }

                    let updatedSnapshot = QuotaSnapshot(
                        planType: secondSnapshot.planType,
                        shortWindow: classifiedShortWindow,
                        weeklyWindow: classifiedWeeklyWindow,
                        availableResetCredits: secondSnapshot.availableResetCredits,
                        earliestResetCreditExpiresAt: secondSnapshot.earliestResetCreditExpiresAt,
                        fetchedAt: secondSnapshot.fetchedAt
                    )

                    if let profileIndex = statuses.firstIndex(where: { $0.id == candidate.profile.id }) {
                        statuses[profileIndex].snapshot = updatedSnapshot
                    }

                    let isDormant = (classifiedShortWindow?.state == .dormant) || (classifiedWeeklyWindow?.state == .dormant)
                    if isDormant {
                        dormantProfiles.append(candidate.profile)
                    }
                } catch {
                    continue
                }
            }
        }

        guard dormantProfiles.isEmpty == false else { return }

        var activatedProfiles: [CodexProfile] = []
        for profile in dormantProfiles {
            if profile.provider == .claude {
                lastClaudeActivationAttempts[profile.id] = .now
            }
            do {
                try await clients.sendActivationTurn(for: profile)
                activatedProfiles.append(profile)
            } catch {
                continue
            }
        }

        guard activatedProfiles.isEmpty == false else { return }

        var verificationFirstSnapshots: [(profile: CodexProfile, snapshot: QuotaSnapshot)] = []
        for profile in activatedProfiles {
            do {
                let firstSnapshot = try await clients.fetchRateLimits(for: profile)
                if profile.provider == .claude {
                    if let profileIndex = statuses.firstIndex(where: { $0.id == profile.id }) {
                        statuses[profileIndex].snapshot = firstSnapshot
                    }
                    continue
                }
                verificationFirstSnapshots.append((profile: profile, snapshot: firstSnapshot))
            } catch {
                continue
            }
        }

        guard verificationFirstSnapshots.isEmpty == false else { return }

        do {
            try await Task.sleep(for: .seconds(5))
        } catch {
            return
        }

        for verification in verificationFirstSnapshots {
            do {
                let verificationSecondSnapshot = try await clients.fetchRateLimits(for: verification.profile)
                let verificationElapsedSeconds = verificationSecondSnapshot.fetchedAt.timeIntervalSince(verification.snapshot.fetchedAt)

                let verifiedShortWindow = verificationSecondSnapshot.shortWindow.map { currentWindow in
                    var updated = currentWindow
                    updated.state = WindowClassifier.classify(
                        previous: verification.snapshot.shortWindow,
                        current: currentWindow,
                        elapsedSeconds: verificationElapsedSeconds
                    )
                    return updated
                }

                let verifiedWeeklyWindow = verificationSecondSnapshot.weeklyWindow.map { currentWindow in
                    var updated = currentWindow
                    updated.state = WindowClassifier.classify(
                        previous: verification.snapshot.weeklyWindow,
                        current: currentWindow,
                        elapsedSeconds: verificationElapsedSeconds
                    )
                    return updated
                }

                let verifiedSnapshot = QuotaSnapshot(
                    planType: verificationSecondSnapshot.planType,
                    shortWindow: verifiedShortWindow,
                    weeklyWindow: verifiedWeeklyWindow,
                    availableResetCredits: verificationSecondSnapshot.availableResetCredits,
                    earliestResetCreditExpiresAt: verificationSecondSnapshot.earliestResetCreditExpiresAt,
                    fetchedAt: verificationSecondSnapshot.fetchedAt
                )

                if let profileIndex = statuses.firstIndex(where: { $0.id == verification.profile.id }) {
                    statuses[profileIndex].snapshot = verifiedSnapshot
                }
            } catch {
                continue
            }
        }
    }

    private func classifySnapshot(
        newSnapshot: QuotaSnapshot,
        previousSnapshot: QuotaSnapshot?,
        provider: ProfileProvider
    ) -> QuotaSnapshot {
        guard provider == .codex, let previousSnapshot else {
            return newSnapshot
        }
        let elapsedSeconds = newSnapshot.fetchedAt.timeIntervalSince(previousSnapshot.fetchedAt)

        let updatedShortWindow = newSnapshot.shortWindow.map { currentWindow in
            var updated = currentWindow
            updated.state = WindowClassifier.classify(
                previous: previousSnapshot.shortWindow,
                current: currentWindow,
                elapsedSeconds: elapsedSeconds
            )
            return updated
        }

        let updatedWeeklyWindow = newSnapshot.weeklyWindow.map { currentWindow in
            var updated = currentWindow
            updated.state = WindowClassifier.classify(
                previous: previousSnapshot.weeklyWindow,
                current: currentWindow,
                elapsedSeconds: elapsedSeconds
            )
            return updated
        }

        return QuotaSnapshot(
            planType: newSnapshot.planType,
            shortWindow: updatedShortWindow,
            weeklyWindow: updatedWeeklyWindow,
            availableResetCredits: newSnapshot.availableResetCredits,
            earliestResetCreditExpiresAt: newSnapshot.earliestResetCreditExpiresAt,
            fetchedAt: newSnapshot.fetchedAt
        )
    }
}

private struct ProviderClients: Sendable {
    let codex: AppServerClient
    let claude: ClaudeUsageClient

    func latestActivity(for profile: CodexProfile) async throws -> Date? {
        switch profile.provider {
        case .codex:
            return try await ActivityReader.latestActivity(for: profile)
        case .claude:
            return try await ClaudeActivityReader.latestActivity(for: profile)
        }
    }

    func fetchRateLimits(for profile: CodexProfile) async throws -> QuotaSnapshot {
        switch profile.provider {
        case .codex:
            return try await codex.fetchRateLimits(for: profile)
        case .claude:
            return try await claude.fetchRateLimits(for: profile)
        }
    }

    func sendActivationTurn(for profile: CodexProfile) async throws {
        switch profile.provider {
        case .codex:
            try await codex.sendActivationTurn(for: profile)
        case .claude:
            try await claude.sendActivationTurn(for: profile)
        }
    }
}

private struct FetchResult: Sendable {
    let profileID: String
    let quotaOutcome: FetchOutcome
    let activityOutcome: ActivityOutcome
}

private enum FetchOutcome: Sendable {
    case success(QuotaSnapshot)
    case failure(String)
}

private enum ActivityOutcome: Sendable {
    case success(Date?)
    case failure(String)
}
