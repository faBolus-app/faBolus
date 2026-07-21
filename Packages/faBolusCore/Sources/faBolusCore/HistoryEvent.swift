import Foundation

/// A backend-neutral history-log entry for the Logbook (Workstream B2). Each `PumpBackend` maps its
/// own decoded events (PumpX2Kit's typed `HistoryLogEvent`s) onto this, so the UI never depends on a
/// specific pump library — mirroring how `PumpAlert` abstracts notifications.
public struct HistoryEvent: Identifiable, Sendable, Equatable {
    public enum Category: String, Sendable, CaseIterable {
        case bolus, carbs, bg, basal, tempRate, mode, cartridge, alarm, alert, reminder, pumping, other

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
            case .other: return "circle.fill"
            }
        }
    }

    public let id: UInt32          // pump sequence number (stable, monotonic)
    public let date: Date
    public let category: Category
    public let title: String
    public let detail: String
    public init(id: UInt32, date: Date, category: Category, title: String, detail: String = "") {
        self.id = id; self.date = date; self.category = category; self.title = title; self.detail = detail
    }
}
