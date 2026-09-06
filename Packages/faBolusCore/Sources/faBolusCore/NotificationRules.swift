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

    // MARK: - Pump-mirror taxonomy (the `category` level of the cascade)

    /// The pump-mirror categories a pump notification is classified into — the `category` level of the
    /// cascade, not a new independent axis. One tunable rung per group; a single toggle governs every
    /// identity that lands in the same group. Ordered loudest-intent-first for readability only.
    public enum PumpMirrorGroup: String, Sendable, Codable, CaseIterable {
        /// Delivery stopped: every alarm and every malfunction. A KIND rule, so an unknown alarm or
        /// malfunction bit fails safe here rather than in a routine group.
        case deliveryStopped
        /// Running low on insulin or power.
        case runningLow
        /// Urgent low glucose.
        case urgentLowGlucose
        /// Glucose level and Control-IQ activity (high/low/rising/falling, Basal-IQ, Control-IQ).
        case glucoseAndControlIQ
        /// CGM sensor and transmitter — including the loss-of-coverage identities (sensor failed /
        /// expired, out of range, failed connection, transmitter expired, CGM error / unavailable).
        case cgmSensorAndTransmitter
        /// Pump reminders and routine housekeeping alerts.
        case pumpRoutine
    }

    /// Classify a pump notification into its pump-mirror group from its OWN identity — the pump kind,
    /// the bit id, and whether it is a malfunction (which decodes as `.alarm` with the dismissable flag
    /// false, so kind alone cannot tell it from a genuine alarm). Keyed on identity, never on the
    /// resolved title, so it is immune to the decoder's silent-degrade-to-unnamed-label behavior.
    ///
    /// The delivery-stopped group is a KIND rule: every alarm and every malfunction lands there, so an
    /// unknown alarm/malfunction bit fails safe. An ALERT id this table does not name resolves to the
    /// fail-safe cell (a loud group), NEVER to the routine group — the one alert id known to be missing
    /// from every decoder table is delivery-suspending, and a routine default would be silently wrong.
    public static func pumpMirrorGroup(kind: PumpAlertKind, id: Int, isMalfunction: Bool) -> PumpMirrorGroup {
        if kind == .alarm || isMalfunction { return .deliveryStopped }
        switch kind {
        case .alert:
            switch id {
            case 0, 1, 2, 3, 5, 7, 17: return .runningLow
            case 35, 50, 51: return .glucoseAndControlIQ
            case 19, 20, 22, 27, 28, 29, 39, 40, 41, 42, 44, 48: return .cgmSensorAndTransmitter
            case 6, 8, 11, 12, 13, 14, 15, 18, 23, 26, 33, 34: return .pumpRoutine
            // Fail-safe cell: an unnamed alert id is never routed to the most-ignorable group.
            default: return .runningLow
            }
        case .cgmAlert:
            switch id {
            case 1: return .urgentLowGlucose
            case 2, 3, 5, 6, 7, 8: return .glucoseAndControlIQ
            case 4, 9, 10, 11, 12, 13, 14, 16, 17, 18, 19, 20, 22, 25, 26, 27, 39:
                return .cgmSensorAndTransmitter
            // An unnamed CGM alert stays with sensor/transmitter (loud), never the routine group.
            default: return .cgmSensorAndTransmitter
            }
        case .reminder:
            return .pumpRoutine
        case .alarm:
            // Unreachable: handled by the KIND rule above. Kept total so the switch is exhaustive.
            return .deliveryStopped
        }
    }

    /// The fatigue-averse default intent for a group: safety groups (delivery-stopped, running low,
    /// urgent low glucose, CGM sensor/transmitter loss) default to `Alert` — a banner and sound that
    /// does not pierce Focus/DND; the user may raise any of them to the breakthrough rung. Non-safety
    /// groups (glucose level and Control-IQ activity, pump routine) default quieter. No group is silent
    /// by default, and none pierces DND by default (the pump remains the primary annunciator).
    public static func defaultIntent(for group: PumpMirrorGroup) -> Intent {
        switch group {
        case .deliveryStopped, .runningLow, .urgentLowGlucose, .cgmSensorAndTransmitter:
            return .alert
        case .glucoseAndControlIQ, .pumpRoutine:
            return .quiet
        }
    }

    // MARK: - Persisted rules model (fresh defaults, decode-tolerant, no migration)

    /// The persisted pump-mirror rules blob. Starts from FRESH fatigue-averse defaults and has no
    /// code path that reads or translates the legacy `notificationBroker.settings.v1` /
    /// `CategorySettings` blob — there is no migration (owner Amendment A: "existing users can just
    /// reset the app"). An absent override is NOT `.off` — it is "not yet overridden," and resolves
    /// through `defaultIntent(for:)` at `cascade(for:)`'s category level, so a fresh install, an
    /// upgrading install, and a decode failure all land in the same place: loud enough, never silent.
    public struct PersistedRules: Sendable, Equatable, Codable {
        /// The pump-mirror SOURCE-level override — Decision 1c's one-move "silence everything
        /// mirrored from the pump." `nil` ⇒ no source-level override; each group resolves at its
        /// own category-level default/override instead.
        public var sourceOverride: Rule?
        /// Per-`PumpMirrorGroup` category-level overrides, keyed by `PumpMirrorGroup.rawValue` (a
        /// `String`-keyed dictionary, mirroring `NotificationBroker.CategorySettings`'s own
        /// `[String: …]` persistence idiom — Swift's synthesized `Codable` for an enum-keyed
        /// dictionary is markedly less forgiving of an unrecognized/removed key than a `String` one).
        /// An absent group here is "not yet overridden," never "off."
        public var groupOverrides: [String: Rule]

        public init(sourceOverride: Rule? = nil, groupOverrides: [String: Rule] = [:]) {
            self.sourceOverride = sourceOverride
            self.groupOverrides = groupOverrides
        }

        // Hand-written, `decodeIfPresent`-based decode FROM THE START (the `ConnectionTelemetry`
        // pattern one file away) — so a field added to this struct later is automatically
        // decode-tolerant: it is one more `decodeIfPresent` line here, never a synthesized
        // non-optional property an older persisted blob could fail to satisfy.
        private enum CodingKeys: String, CodingKey {
            case sourceOverride, groupOverrides
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sourceOverride = try c.decodeIfPresent(Rule.self, forKey: .sourceOverride)
            groupOverrides = try c.decodeIfPresent([String: Rule].self, forKey: .groupOverrides) ?? [:]
        }

        /// The resolved cascade for `group`. The fatigue-averse default sits at the LEAST specific
        /// (`global`) level — never at `category` — so an explicit `sourceOverride` (more specific
        /// than `global`, less specific than `category`) can still silence the group in one move
        /// per Decision 1c; a `category`-level override, when the user has set one, wins over both.
        /// Never `.off` by omission: the only way any level is `.off` is an explicit user choice.
        public func cascade(for group: PumpMirrorGroup) -> Cascade {
            Cascade(
                global: Rule(intent: NotificationRules.defaultIntent(for: group)),
                source: sourceOverride,
                category: groupOverrides[group.rawValue])
        }
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
