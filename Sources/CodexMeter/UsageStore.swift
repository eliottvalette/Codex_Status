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
    /// Claude accounts whose usage is not read again before this time.
    private var claudeUsagePausedUntil: [String: Date] = [:]
    /// Accounts that were low at the last refresh, so each one is announced once.
    private var lowAccountIDs: Set<String> = []

    let settings: AppSettings
    private let notifier: any LowLimitNotifier
    private let writeToClipboard: @MainActor (String) -> Void

    private let clients: ProviderClients
    private let transferService: SessionTransferService
    private let claudeTransferService: ClaudeSessionTransferService
    private let chatCatalog: ClaudeChatCatalog

    init(
        profiles: [CodexProfile] = CodexProfile.launchProfiles(),
        client: AppServerClient = AppServerClient(),
        claudeClient: ClaudeUsageClient = ClaudeUsageClient(),
        transferService: SessionTransferService = SessionTransferService(),
        claudeTransferService: ClaudeSessionTransferService = ClaudeSessionTransferService(),
        chatCatalog: ClaudeChatCatalog = ClaudeChatCatalog(),
        settings: AppSettings = AppSettings(),
        notifier: any LowLimitNotifier = SystemNotifier(),
        writeToClipboard: @escaping @MainActor (String) -> Void = UsageStore.writeToPasteboard
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
        self.settings = settings
        self.notifier = notifier
        self.writeToClipboard = writeToClipboard
    }

    static func writeToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func paceValue(relativeTo now: Date) -> PaceValue? {
        let current = UsagePace.currentObservations(statuses, now: now)
        return UsagePace.value(current: current, now: now)
    }

    var isTransferring: Bool {
        transferDestinationID != nil || isSyncing
    }

    var codexProfiles: [CodexProfile] {
        statuses.map(\.profile).filter { $0.provider == .codex }
    }

    /// The sync reads and writes Codex rollouts, so it covers Codex accounts only.
    var canSyncConversations: Bool {
        codexProfiles.count >= 2
    }

    func syncRecentConversations() async {
        guard !isTransferring, canSyncConversations else { return }
        feedbackClearTask?.cancel()
        transferSourceID = nil
        isSyncing = true
        defer { isSyncing = false }
        transferFeedback = TransferFeedback(style: .progress, message: "Syncing the last 10 days…")
        do {
            let result = try await transferService.syncRecentSessions(across: codexProfiles)
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

        guard let copiedCount = await copyChats([chat], from: source, to: destination) else { return }
        // The next step is to open it there, so the command that does it is ready to paste.
        writeToClipboard(chat.resumeCommand(in: destination))
        let title = chat.title.count > 32 ? chat.title.prefix(31) + "…" : chat.title
        let outcome = copiedCount == 0 ? "already on" : "copied to"
        report("✓ “\(title)” \(outcome) \(destination.displayName) · resume command copied", style: .success)
    }

    /// Copies the chats of a low account to the account with the most room.
    func moveChats(_ move: ChatMove) async {
        guard await copyChats(move.chats, from: move.source, to: move.destination) != nil else { return }
        let label = move.chats.count == 1 ? "chat" : "chats"
        report(
            "✓ \(move.chats.count) \(label) from \(move.source.displayName) copied to \(move.destination.displayName)",
            style: .success
        )
    }

    /// The move to suggest, or to make on its own, under the chat setting.
    var chatMove: ChatMove? {
        guard settings.chatMoves != .off else { return nil }
        return LowLimits.chatMove(statuses: statuses, chats: recentChats)
    }

    func copyResumeCommand(for chat: RecentClaudeChat) {
        guard let profile = claudeProfiles.first(where: { $0.id == chat.profileID }) else { return }
        writeToClipboard(chat.resumeCommand(in: profile))
        report("Resume command for \(profile.displayName) copied", style: .success)
    }

    func report(_ message: String, style: TransferFeedback.Style) {
        transferFeedback = TransferFeedback(style: style, message: message)
        if style == .success { scheduleFeedbackClear() }
    }

    /// Copies the chats one by one and reloads the list. Returns how many were written, or
    /// `nil` when another copy is running or this one failed, which the status line shows.
    private func copyChats(
        _ chats: [RecentClaudeChat],
        from source: CodexProfile,
        to destination: CodexProfile
    ) async -> Int? {
        guard isTransferring == false else { return nil }
        feedbackClearTask?.cancel()
        transferSourceID = nil
        transferDestinationID = destination.id
        transferFeedback = TransferFeedback(
            style: .progress,
            message: "Copying to \(destination.displayName)…"
        )
        var copiedCount: Int? = 0
        do {
            for chat in chats {
                copiedCount? += try await claudeTransferService.transferSession(
                    chat.file, from: source, to: destination
                ).copiedCount
            }
        } catch {
            copiedCount = nil
            report(error.localizedDescription, style: .failure)
        }
        transferDestinationID = nil
        await reloadRecentChats()
        return copiedCount
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
                try await Task.sleep(for: .seconds(settings.refreshMinutes * 60))
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
        let pausedIDs = Set(claudeUsagePausedUntil.filter { $0.value > .now }.keys)

        await withTaskGroup(of: FetchResult.self) { group in
            for profile in profiles {
                group.addTask {
                    let activityOutcome: ActivityOutcome
                    do {
                        activityOutcome = .success(try await clients.latestActivity(for: profile))
                    } catch {
                        activityOutcome = .failure(error.localizedDescription)
                    }

                    guard pausedIDs.contains(profile.id) == false else {
                        return FetchResult(profileID: profile.id, quotaOutcome: .paused, activityOutcome: activityOutcome)
                    }
                    do {
                        let snapshot = try await clients.fetchRateLimits(for: profile)
                        return FetchResult(
                            profileID: profile.id,
                            quotaOutcome: .success(snapshot),
                            activityOutcome: activityOutcome
                        )
                    } catch ClaudeUsageError.usageTemporarilyUnavailable {
                        return FetchResult(
                            profileID: profile.id,
                            quotaOutcome: .unavailable(ClaudeUsageError.usageTemporarilyUnavailable.localizedDescription),
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
                    claudeUsagePausedUntil[result.profileID] = nil
                case let .failure(message):
                    statuses[index].errorMessage = message
                case let .unavailable(message):
                    statuses[index].errorMessage = message
                    claudeUsagePausedUntil[result.profileID] = .now.addingTimeInterval(ClaudeUsagePolicy.retryDelay)
                case .paused:
                    break
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
        await handleLowLimits()
        await handlePostRefresh()
    }

    /// Announces each account that has just become low, and moves its chats when the
    /// setting asks for it.
    private func handleLowLimits() async {
        let low = LowLimits.lowIDs(in: statuses)
        if settings.notifiesLowLimits {
            for status in statuses where low.contains(status.id) && lowAccountIDs.contains(status.id) == false {
                if let alert = LowLimits.alert(for: status, in: statuses) {
                    notifier.notify(title: alert.title, body: alert.body)
                }
            }
        }
        lowAccountIDs = low
        if settings.chatMoves == .automatic, let chatMove {
            await moveChats(chatMove)
        }
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
                    snapshot, lastAttempt: lastClaudeActivationAttempts[status.id],
                    isEnabled: settings.startsIdleClaudeWindows
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
                    snapshot, lastAttempt: lastClaudeActivationAttempts[status.id],
                    isEnabled: settings.startsIdleClaudeWindows
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
    /// Claude Code answered without limits; reads pause for a while.
    case unavailable(String)
    /// Not read this time because reads are paused.
    case paused
}

private enum ActivityOutcome: Sendable {
    case success(Date?)
    case failure(String)
}
