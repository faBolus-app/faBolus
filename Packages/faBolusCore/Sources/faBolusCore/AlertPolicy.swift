import Foundation

/// The user's alert settings: each category on or off, and how long the pump may be unreachable before
/// "Pump disconnected" notifies. Urgency isn't a setting; it is fixed per category.
///
/// Absent from a stored blob means on, so a fresh install, a category added later and a blob that
/// fails to decode all land on "on", never on silence.
public struct AlertPolicy: Sendable, Hashable, Codable {
    /// How long the pump may stay unreachable before "Pump disconnected" notifies. `never` turns the
    /// category off (owner decision 2026-11-01).
    public enum PumpDisconnectDelay: String, Sendable, Hashable, Codable, CaseIterable {
        case immediately, oneMinute, fiveMinutes, tenMinutes, fifteenMinutes, thirtyMinutes, never

        /// The delay in seconds, or `nil` for `never`.
        public var seconds: TimeInterval? {
            switch self {
            case .immediately: return 0
            case .oneMinute: return 60
            case .fiveMinutes: return 5 * 60
            case .tenMinutes: return 10 * 60
            case .fifteenMinutes: return 15 * 60
            case .thirtyMinutes: return 30 * 60
            case .never: return nil
            }
        }

        /// The default (owner decision 2026-11-01): quiet through brief drops.
        public static let standard: PumpDisconnectDelay = .fifteenMinutes
    }

    public var pumpDisconnectDelay: PumpDisconnectDelay
    private var off: Set<NotificationBroker.Category>

    /// Every category on, with the standard disconnect delay.
    public init(pumpDisconnectDelay: PumpDisconnectDelay = .standard) {
        self.pumpDisconnectDelay = pumpDisconnectDelay
        off = []
    }

    /// Whether `category` notifies. The bolus result is always on.
    public func isOn(_ category: NotificationBroker.Category) -> Bool {
        switch category {
        case .bolusReconciliation: return true
        case .pumpDisconnect: return pumpDisconnectDelay != .never
        default: return !off.contains(category)
        }
    }

    /// Turn a category on or off. Turning the bolus result off does nothing. "Pump disconnected" is off
    /// when its delay is `never`, so turning it off sets `never` and turning it back on restores the
    /// standard delay.
    public mutating func setOn(_ on: Bool, for category: NotificationBroker.Category) {
        switch category {
        case .bolusReconciliation:
            return
        case .pumpDisconnect:
            if !on {
                pumpDisconnectDelay = .never
            } else if pumpDisconnectDelay == .never {
                pumpDisconnectDelay = .standard
            }
        default:
            if on { off.remove(category) } else { off.insert(category) }
        }
    }

    /// The categories settings shows a switch for, in settings order.
    public static var switchableCategories: [NotificationBroker.Category] {
        NotificationBroker.Category.allCases.filter { $0.canBeTurnedOff && $0.deliversAsNotification }
    }

    // Categories are stored by raw value so an unknown one (written by a later build, or renamed) is
    // dropped instead of failing the whole decode, which would turn every category back on unnoticed.
    private enum CodingKeys: String, CodingKey { case pumpDisconnectDelay, off }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let delay = try? c.decodeIfPresent(String.self, forKey: .pumpDisconnectDelay)
        pumpDisconnectDelay = delay.flatMap(PumpDisconnectDelay.init(rawValue:)) ?? .standard
        let raw = (try? c.decodeIfPresent([String].self, forKey: .off)) ?? []
        // Only categories with a plain switch are kept; the bolus result and the disconnect delay never
        // come from this list.
        off = Set(
            raw.compactMap(NotificationBroker.Category.init(rawValue:))
                .filter { $0.canBeTurnedOff && $0 != .pumpDisconnect })
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pumpDisconnectDelay.rawValue, forKey: .pumpDisconnectDelay)
        try c.encode(off.map(\.rawValue).sorted(), forKey: .off)
    }
}
