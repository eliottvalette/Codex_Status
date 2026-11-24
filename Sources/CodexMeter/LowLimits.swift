import Foundation

/// Chats on a low Claude account that the account with the most room does not hold yet.
struct ChatMove: Equatable, Sendable {
    let source: CodexProfile
    let destination: CodexProfile
    let sourceRoom: Int
    let chats: [RecentClaudeChat]
}

/// An account is low when any of its windows has 10% or less left.
enum LowLimits {
    static let threshold = 10

    /// The least left on any window of the account, in percent, or `nil` with no reading.
    static func room(of status: ProfileStatus) -> Int? {
        guard let snapshot = status.snapshot else { return nil }
        let windows = [snapshot.shortWindow, snapshot.weeklyWindow].compactMap { $0 }
            + snapshot.modelWindows.map(\.window)
        return windows.map { Int($0.remainingPercent.rounded()) }.min()
    }

    static func lowIDs(in statuses: [ProfileStatus]) -> Set<String> {
        Set(statuses.filter { (room(of: $0) ?? 100) <= threshold }.map(\.id))
    }

    /// The other account of the same provider with the most room, when it is not low itself.
    static func roomiest(
        besides status: ProfileStatus,
        in statuses: [ProfileStatus]
    ) -> (status: ProfileStatus, room: Int)? {
        statuses
            .filter { $0.id != status.id && $0.profile.provider == status.profile.provider }
            .compactMap { other in room(of: other).map { (status: other, room: $0) } }
            .filter { $0.room > threshold }
            .max { $0.room < $1.room }
    }

    /// The notification for an account that has just become low.
    static func alert(for status: ProfileStatus, in statuses: [ProfileStatus]) -> (title: String, body: String)? {
        guard let room = room(of: status) else { return nil }
        let title = "\(status.profile.displayName) has \(room)% left"
        guard let best = roomiest(besides: status, in: statuses) else {
            return (title, "No other \(status.profile.provider.displayName) account has room left.")
        }
        return (title, "Most room left: \(best.status.profile.displayName) (\(best.room)%).")
    }

    /// The chats to move from the lowest Claude account that has some, or `nil`.
    static func chatMove(statuses: [ProfileStatus], chats: [RecentClaudeChat]) -> ChatMove? {
        let lowAccounts = statuses
            .filter { $0.profile.provider == .claude }
            .compactMap { status in room(of: status).map { (status: status, room: $0) } }
            .filter { $0.room <= threshold }
            .sorted { $0.room < $1.room }
        for low in lowAccounts {
            guard let best = roomiest(besides: low.status, in: statuses) else { continue }
            let pending = chats.filter {
                $0.profileID == low.status.id && $0.copiedToProfileIDs.contains(best.status.id) == false
            }
            if pending.isEmpty == false {
                return ChatMove(
                    source: low.status.profile,
                    destination: best.status.profile,
                    sourceRoom: low.room,
                    chats: pending
                )
            }
        }
        return nil
    }
}
