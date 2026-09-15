import Foundation
import Observation

@MainActor
@Observable
final class UsageStore {
    private(set) var statuses: [ProfileStatus]
    private(set) var isRefreshing = false

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
        while Task.isCancelled == false {
            await refresh()
            do {
                try await Task.sleep(for: refreshInterval)
            } catch {
                return
            }
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
                case let .success(snapshot):
                    statuses[index].snapshot = snapshot
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
