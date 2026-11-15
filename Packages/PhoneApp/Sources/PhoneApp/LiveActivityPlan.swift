import Foundation

/// What to do with the Live Activities iOS lists for the app, so only one is ever on screen.
///
/// iOS ends a Live Activity after 8 hours but leaves it on the Lock Screen, frozen, for up to 4 more. Only
/// an active or stale one is live; starting a new one beside an ended one would show two cards, one of them
/// frozen. So a start first ends every listed card, an update ends every card but the one it updates, and
/// while the app is open a card nearing the 8-hour end is replaced before iOS freezes it. iOS lets an app
/// start one only from the foreground, so in the background an ended card stays until the app can replace
/// it.
public enum LiveActivityPlan {
    /// One listed Live Activity.
    public struct Listed: Equatable, Sendable {
        public let id: String
        /// Active or stale: still updated by iOS. An ended card isn't, though it may still be on screen.
        public let isLive: Bool
        /// When this app started it, if it recorded that; ActivityKit doesn't say.
        public let startedAt: Date?

        public init(id: String, isLive: Bool, startedAt: Date?) {
            self.id = id
            self.isLive = isLive
            self.startedAt = startedAt
        }
    }

    public struct Decision: Equatable, Sendable {
        /// The one to update, if any.
        public var update: String?
        /// The ones to end and take off the screen now.
        public var end: [String]
        /// Whether to start a new one.
        public var start: Bool
    }

    /// iOS ends a Live Activity at 8 hours; one older than this is replaced while the app is open. An
    /// hour's margin, as the app may be opened only now and then.
    public static let replaceAfter: TimeInterval = 7 * 3600

    public static func decide(_ listed: [Listed], appActive: Bool, now: Date) -> Decision {
        let live = listed.filter(\.isLive)
        // The newest live one is kept, so a replacement just started isn't the one ended.
        let keep = live.max { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
        let all = listed.map(\.id)
        guard let keep else {
            // Nothing live. An ended card is left up in the background, where nothing can replace it.
            return appActive ? Decision(update: nil, end: all, start: true) : Decision(update: nil, end: [], start: false)
        }
        if appActive, let started = keep.startedAt, now.timeIntervalSince(started) >= replaceAfter {
            return Decision(update: nil, end: all, start: true)
        }
        return Decision(update: keep.id, end: all.filter { $0 != keep.id }, start: false)
    }
}
