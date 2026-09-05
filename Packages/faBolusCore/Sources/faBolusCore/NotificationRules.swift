import Foundation

/// The shared, unified notification-rules engine: an abstract urgency ladder, a first-class
/// pump-mirror/app-own source dimension, a `global → source → category → per-notification` cascade
/// with inheritance, and a pure per-surface (phone + watch) resolver. This is the ONE resolver both
/// `NotificationBroker.decide` (phone) and `RemoteStatusComposer` (watch) read, so the two consumers
/// cannot diverge by construction — "notify" cannot mean two different things again.
///
/// A rule stores an abstract intent, never a platform mechanism: each surface renders only the
/// rungs it can honor and maps intent → native mechanism on its own (iOS →
/// `UNNotificationInterruptionLevel`, Garmin → `Toybox.Attention`) — this type never picks a native
/// value.
public enum NotificationRules {

    /// The abstract urgency intent a rule stores, ordered `off < quiet < alert < urgent`.
    public enum Intent: Int, Comparable, Sendable, Codable, CaseIterable {
        case off = 0, quiet = 1, alert = 2, urgent = 3
        public static func < (a: Intent, b: Intent) -> Bool { a.rawValue < b.rawValue }
    }

    /// Whether a notification originates from the pump's own annunciation (mirrored onto the
    /// phone/watch) or is generated entirely by the app. First-class cascade scope (Decision 1c) —
    /// distinct from `NotificationBroker.Category.isPumpSourced`, which is a display-only UI axis.
    public enum Source: String, Sendable, Codable, CaseIterable {
        case pumpMirror, appOwn
    }

    /// One cascade level's rule. `intent` is the abstract phone-side intent this level asserts
    /// (`nil` ⇒ inherit from the level above). `watchOverride` optionally overrides the default
    /// follow-phone watch behavior at this same level (`nil` ⇒ inherit / follow phone).
    public struct Rule: Sendable, Equatable, Codable {
        public var intent: Intent?
        public var watchOverride: Intent?
        public init(intent: Intent? = nil, watchOverride: Intent? = nil) {
            self.intent = intent
            self.watchOverride = watchOverride
        }
    }

    /// The four cascade levels bundled as one value, most specific last. A convenience wrapper
    /// around `resolve(global:source:category:perNotification:timeSensitiveAvailable:)` for a
    /// caller that wants to pass one rule set rather than four separate optionals.
    public struct Cascade: Sendable, Equatable, Codable {
        public var global: Rule?
        public var source: Rule?
        public var category: Rule?
        public var perNotification: Rule?
        public init(
            global: Rule? = nil, source: Rule? = nil, category: Rule? = nil,
            perNotification: Rule? = nil
        ) {
            self.global = global
            self.source = source
            self.category = category
            self.perNotification = perNotification
        }
    }

    /// Resolve one notification's phone AND watch intent through the
    /// `global → source → category → perNotification` cascade — most specific non-nil `intent`
    /// wins, and an unset level inherits from the level above. Pure: no `Date()`, no I/O, no
    /// singletons; same inputs → same output, every time.
    ///
    /// - `timeSensitiveAvailable`: when `false`, the phone result can NEVER be `.urgent` — the
    ///   rung is ABSENT (the ladder tops out at `.alert`), never a silently-degraded
    ///   alert-labelled-urgent (Decision 3 of the 2026-09-02 notification redesign).
    /// - The watch result NEVER carries `.urgent` — the Garmin ladder has no breakthrough rung, so
    ///   a phone `.urgent` follows to the watch's top rung (`.alert`), not to a non-existent
    ///   watch-urgent. Default watch behavior is "follow the resolved phone intent"; an explicit
    ///   `watchOverride` at any cascade level wins over that default when present.
    public static func resolve(
        global: Rule? = nil,
        source: Rule? = nil,
        category: Rule? = nil,
        perNotification: Rule? = nil,
        timeSensitiveAvailable: Bool
    ) -> (phone: Intent, watch: Intent) {
        // Most specific first, so `.first` on the compacted list is the winning non-nil value —
        // each unset level (a `nil` field, not a missing level) simply has nothing to contribute
        // and the search falls through to the next-least-specific level.
        let levels = [perNotification, category, source, global]

        let resolvedIntent = levels.compactMap(\.?.intent).first ?? .off
        let phone = timeSensitiveAvailable ? resolvedIntent : Swift.min(resolvedIntent, .alert)

        let watchOverride = levels.compactMap(\.?.watchOverride).first
        let watchFollowingPhone = watchOverride ?? phone
        // The Garmin ladder has no Urgent/breakthrough rung (Decision 1a/1d) — cap independently
        // of the phone's capability-gated cap above, so a watch override of `.urgent` (a caller
        // error, since the type permits it) still cannot leak an unrepresentable rung either.
        let watch = Swift.min(watchFollowingPhone, .alert)

        return (phone, watch)
    }

    /// Convenience overload taking one bundled `Cascade` instead of four separate optionals.
    public static func resolve(_ cascade: Cascade, timeSensitiveAvailable: Bool) -> (
        phone: Intent, watch: Intent
    ) {
        resolve(
            global: cascade.global, source: cascade.source, category: cascade.category,
            perNotification: cascade.perNotification, timeSensitiveAvailable: timeSensitiveAvailable)
    }
}

extension NotificationBroker.Category {
    /// The cascade SOURCE scope this category resolves under (Decision 1c): `.pumpAlert` is the
    /// sole pump-mirror category; every other `Category` case — including all five
    /// never-suppressible safety categories — is generated entirely by the app. Distinct from
    /// `isPumpSourced` (a display-only UI axis this rules engine never reads) even though the two
    /// happen to agree today; keeping them as separate accessors means a future category that is
    /// pump-sourced for DISPLAY but should cascade as `appOwn` (or vice versa) is one line, not a
    /// re-derivation.
    public var notificationSource: NotificationRules.Source {
        self == .pumpAlert ? .pumpMirror : .appOwn
    }
}
