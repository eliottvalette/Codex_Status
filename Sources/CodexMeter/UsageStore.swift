import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class UsageStore {
    private(set) var statuses: [ProfileStatus]
    private(set) var isRefreshing = false
    private(set) var isActivating = false

    private let client: AppServerClient
    private let refreshInterval: Duration

    init(
        profiles: [CodexProfile] = CodexProfile.configured,
        client: AppServerClient = AppServerClient(),
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
        self.refreshInterval = refreshInterval
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
    }

    func performActivationCycle() async {
        guard isActivating == false, isRefreshing == false else { return }
        isActivating = true
        defer { isActivating = false }

        await refresh()

        let candidateProfiles = statuses.compactMap { status -> (CodexProfile, QuotaSnapshot)? in
            guard let snapshot = status.snapshot else { return nil }
            let hasZeroUsageWindow = (snapshot.shortWindow?.usedPercent == 0) || (snapshot.weeklyWindow?.usedPercent == 0)
            return hasZeroUsageWindow ? (status.profile, snapshot) : nil
        }

        guard candidateProfiles.isEmpty == false else { return }

        do {
            try await Task.sleep(for: .seconds(6))
        } catch {
            return
        }

        var dormantProfiles: [CodexProfile] = []
        for (profile, previousSnapshot) in candidateProfiles {
            do {
                let secondSnapshot = try await client.fetchRateLimits(for: profile)
                let elapsedSeconds = secondSnapshot.fetchedAt.timeIntervalSince(previousSnapshot.fetchedAt)

                let classifiedShortWindow = secondSnapshot.shortWindow.map { currentWindow in
                    var updated = currentWindow
                    updated.state = WindowClassifier.classify(
                        previous: previousSnapshot.shortWindow,
                        current: currentWindow,
                        elapsedSeconds: elapsedSeconds
                    )
                    return updated
                }

                let classifiedWeeklyWindow = secondSnapshot.weeklyWindow.map { currentWindow in
                    var updated = currentWindow
                    updated.state = WindowClassifier.classify(
                        previous: previousSnapshot.weeklyWindow,
                        current: currentWindow,
                        elapsedSeconds: elapsedSeconds
                    )
                    return updated
                }

                let updatedSnapshot = QuotaSnapshot(
                    planType: secondSnapshot.planType,
                    shortWindow: classifiedShortWindow,
                    weeklyWindow: classifiedWeeklyWindow,
                    fetchedAt: secondSnapshot.fetchedAt
                )

                if let profileIndex = statuses.firstIndex(where: { $0.id == profile.id }) {
                    statuses[profileIndex].snapshot = updatedSnapshot
                }

                let isDormant = (classifiedShortWindow?.state == .dormant) || (classifiedWeeklyWindow?.state == .dormant)
                if isDormant {
                    dormantProfiles.append(profile)
                }
            } catch {
                continue
            }
        }

        guard dormantProfiles.isEmpty == false else { return }

        for profile in dormantProfiles {
            do {
                try await client.sendActivationTurn(for: profile)
            } catch {
                continue
            }

            do {
                let verificationFirstSnapshot = try await client.fetchRateLimits(for: profile)
                try await Task.sleep(for: .seconds(5))
                let verificationSecondSnapshot = try await client.fetchRateLimits(for: profile)
                let verificationElapsedSeconds = verificationSecondSnapshot.fetchedAt.timeIntervalSince(verificationFirstSnapshot.fetchedAt)

                let verifiedShortWindow = verificationSecondSnapshot.shortWindow.map { currentWindow in
                    var updated = currentWindow
                    updated.state = WindowClassifier.classify(
                        previous: verificationFirstSnapshot.shortWindow,
                        current: currentWindow,
                        elapsedSeconds: verificationElapsedSeconds
                    )
                    return updated
                }

                let verifiedWeeklyWindow = verificationSecondSnapshot.weeklyWindow.map { currentWindow in
                    var updated = currentWindow
                    updated.state = WindowClassifier.classify(
                        previous: verificationFirstSnapshot.weeklyWindow,
                        current: currentWindow,
                        elapsedSeconds: verificationElapsedSeconds
                    )
                    return updated
                }

                let verifiedSnapshot = QuotaSnapshot(
                    planType: verificationSecondSnapshot.planType,
                    shortWindow: verifiedShortWindow,
                    weeklyWindow: verifiedWeeklyWindow,
                    fetchedAt: verificationSecondSnapshot.fetchedAt
                )

                if let profileIndex = statuses.firstIndex(where: { $0.id == profile.id }) {
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
