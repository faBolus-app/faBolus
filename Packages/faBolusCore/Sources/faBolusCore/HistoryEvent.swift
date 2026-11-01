import Foundation

/// A backend-neutral history-log entry for the Logbook (Workstream B2). The pump session maps its
/// own decoded events (TandemKit's typed `HistoryLogEvent`s) onto this, so the UI never depends on a
/// specific pump library — mirroring how `PumpAlert` abstracts notifications.
public struct HistoryEvent: Identifiable, Sendable, Equatable {
    public enum Category: String, Sendable, CaseIterable {
        case bolus, carbs, bg, basal, tempRate, mode, cartridge, alarm, alert, reminder, pumping
        /// Control-IQ auto-corrected (`bolusSource == 7` on a `BolusDeliveryHistoryLog`). Display-only,
        /// never a dose input.
        case autoCorrection
        /// A Control-IQ automatic bolus the pump rejected (`AaAutoBolusRejectedHistoryLog`). Never
        /// speculates why: the record carries no reason. Rendered amber (informational, not an alarm),
        /// distinct from `.alarm`.
        case couldNotDeliver
        case other

        /// SF Symbol for the row icon.
        public var symbol: String {
            switch self {
            case .bolus: return "drop.fill"
            case .carbs: return "fork.knife"
            case .bg: return "drop.triangle"
            case .basal: return "waveform.path.ecg"
            case .tempRate: return "timer"
            case .mode: return "moon.zzz.fill"
            case .cartridge: return "cross.vial.fill"
            case .alarm: return "exclamationmark.triangle.fill"
            case .alert: return "bell.fill"
            case .reminder: return "bell.badge"
            case .pumping: return "pause.circle.fill"
            case .autoCorrection: return "bolt.circle.fill"
            // Non-filled + amber (never red, never the alarm glyph) — informational, not an alarm.
            case .couldNotDeliver: return "exclamationmark.triangle"
            case .other: return "circle.fill"
            }
        }
    }

    public let id: UInt32  // pump sequence number (stable, monotonic)
    public let date: Date
    public let category: Category
    public let title: String
    public let detail: String
    public init(id: UInt32, date: Date, category: Category, title: String, detail: String = "") {
        self.id = id
        self.date = date
        self.category = category
        self.title = title
        self.detail = detail
    }

    /// The logbook's order: newest first, and the later record first when two share a time (pump records
    /// often do), so the order is the same wherever the logbook is read from.
    public static func newestFirst(_ a: HistoryEvent, _ b: HistoryEvent) -> Bool {
        a.date != b.date ? a.date > b.date : a.id > b.id
    }
}
