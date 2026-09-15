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
            ProfileStatus(profile: $0, snapshot: nil, errorMessage: nil, isRefreshing: false)
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
                    do {
                        let snapshot = try await client.fetchRateLimits(for: profile)
                        return FetchResult(profileID: profile.id, outcome: .success(snapshot))
                    } catch {
                        return FetchResult(
                            profileID: profile.id,
                            outcome: .failure(error.localizedDescription)
                        )
                    }
                }
            }

            for await result in group {
                guard let index = statuses.firstIndex(where: { $0.id == result.profileID }) else {
                    continue
                }
                statuses[index].isRefreshing = false
                switch result.outcome {
                case let .success(snapshot):
                    statuses[index].snapshot = snapshot
                    statuses[index].errorMessage = nil
                case let .failure(message):
                    statuses[index].errorMessage = message
                }
            }
        }

        isRefreshing = false
    }
}

private struct FetchResult: Sendable {
    let profileID: String
    let outcome: FetchOutcome
}

private enum FetchOutcome: Sendable {
    case success(QuotaSnapshot)
    case failure(String)
}
