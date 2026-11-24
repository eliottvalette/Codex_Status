import Foundation
import Observation

/// Choices from the settings menu, kept in the user defaults.
@MainActor
@Observable
final class AppSettings {
    /// What to do with recent chats on a Claude account whose limit is low.
    enum ChatMoves: String, CaseIterable, Sendable {
        case off
        case suggest
        case automatic

        var title: String {
            switch self {
            case .off: "Off"
            case .suggest: "Suggest moving them"
            case .automatic: "Move them automatically"
            }
        }
    }

    static let refreshChoices = [1, 2, 5, 10]

    var startsIdleClaudeWindows: Bool {
        didSet { defaults.set(startsIdleClaudeWindows, forKey: Key.startsIdleClaudeWindows) }
    }

    var refreshMinutes: Int {
        didSet { defaults.set(refreshMinutes, forKey: Key.refreshMinutes) }
    }

    var notifiesLowLimits: Bool {
        didSet { defaults.set(notifiesLowLimits, forKey: Key.notifiesLowLimits) }
    }

    var chatMoves: ChatMoves {
        didSet { defaults.set(chatMoves.rawValue, forKey: Key.chatMoves) }
    }

    /// Names given to accounts in the app, by profile ID.
    var accountNames: [String: String] {
        didSet { defaults.set(accountNames, forKey: Key.accountNames) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        startsIdleClaudeWindows = defaults.object(forKey: Key.startsIdleClaudeWindows) as? Bool ?? true
        let minutes = defaults.integer(forKey: Key.refreshMinutes)
        refreshMinutes = Self.refreshChoices.contains(minutes) ? minutes : 2
        notifiesLowLimits = defaults.bool(forKey: Key.notifiesLowLimits)
        chatMoves = defaults.string(forKey: Key.chatMoves).flatMap(ChatMoves.init(rawValue:)) ?? .suggest
        accountNames = defaults.dictionary(forKey: Key.accountNames) as? [String: String] ?? [:]
    }

    private enum Key {
        static let startsIdleClaudeWindows = "startsIdleClaudeWindows"
        static let refreshMinutes = "refreshMinutes"
        static let notifiesLowLimits = "notifiesLowLimits"
        static let chatMoves = "chatMoves"
        static let accountNames = "accountNames"
    }
}
