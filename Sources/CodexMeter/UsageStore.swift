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
    private var hasPendingActivationCycle = false
    private var feedbackClearTask: Task<Void, Never>?

    private let client: AppServerClient
    private let transferService: SessionTransferService
    private let refreshInterval: Duration

    init(
        profiles: [CodexProfile] = CodexProfile.configured,
        client: AppServerClient = AppServerClient(),
        transferService: SessionTransferService = SessionTransferService(),
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
        self.client = client
        self.transferService = transferService
        self.refreshInterval = refreshInterval
    }

    func paceValue(relativeTo now: Date) -> PaceValue? {
        let current = UsagePace.currentObservations(statuses, now: now)
        return UsagePace.value(current: current, now: now)
    }

    var isTransferring: Bool {
        transferDestinationID != nil
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

        transferDestinationID = tappedProfile.id
        transferFeedback = TransferFeedback(
            style: .progress,
            message: "Copying to \(tappedProfile.displayName)…"
        )

        do {
            let result = try await transferService.transferRecentSessions(
                from: sourceProfile,
                to: tappedProfile
            )
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
        let client = self.client

        await withTaskGroup(of: FetchResult.self) { group in
            for profile in profiles {
                group.addTask {
                    let activityOutcome: ActivityOutcome
                    do {
                        activityOutcome = .success(try await ActivityReader.latestActivity(for: profile))
                    } catch {
                        activityOutcome = .failure(error.localizedDescription)
                    }

                    do {
                        let snapshot = try await client.fetchRateLimits(for: profile)
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
                        previousSnapshot: previousSnapshot
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
                    let secondSnapshot = try await client.fetchRateLimits(for: candidate.profile)
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
            do {
                try await client.sendActivationTurn(for: profile)
                activatedProfiles.append(profile)
            } catch {
                continue
            }
        }

        guard activatedProfiles.isEmpty == false else { return }

        var verificationFirstSnapshots: [(profile: CodexProfile, snapshot: QuotaSnapshot)] = []
        for profile in activatedProfiles {
            do {
                let firstSnapshot = try await client.fetchRateLimits(for: profile)
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
                let verificationSecondSnapshot = try await client.fetchRateLimits(for: verification.profile)
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

    private func classifySnapshot(newSnapshot: QuotaSnapshot, previousSnapshot: QuotaSnapshot?) -> QuotaSnapshot {
        guard let previousSnapshot else {
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
