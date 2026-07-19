import Foundation

/// Data shared from the app to its WidgetKit extension via an App Group. The app writes a
/// `WidgetSnapshot` on every pump update; Lock Screen / Home Screen widgets read the latest one.
/// Widgets can't drive Bluetooth themselves, so they show the last-published values plus an age.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public struct Point: Codable, Sendable, Equatable {
        public var t: Date
        public var mgdl: Int
        public init(t: Date, mgdl: Int) { self.t = t; self.mgdl = mgdl }
    }

    public var glucose: Int?
    public var trendAscii: String          // Latin-safe arrow ("^", "^^", "/", "->", "\\", "v", "vv")
    public var iobUnits: Double
    public var reservoirUnits: Double
    public var batteryPercent: Int
    public var lastBolusUnits: Double?
    public var lastBolusDate: Date?
    public var connected: Bool
    public var updatedAt: Date
    /// Recent readings for a sparkline (oldest→newest, capped small for App Group size).
    public var recentPoints: [Point]

    public init(glucose: Int? = nil, trendAscii: String = "", iobUnits: Double = 0,
                reservoirUnits: Double = 0, batteryPercent: Int = 0, lastBolusUnits: Double? = nil,
                lastBolusDate: Date? = nil, connected: Bool = false, updatedAt: Date = Date(),
                recentPoints: [Point] = []) {
        self.glucose = glucose; self.trendAscii = trendAscii; self.iobUnits = iobUnits
        self.reservoirUnits = reservoirUnits; self.batteryPercent = batteryPercent
        self.lastBolusUnits = lastBolusUnits; self.lastBolusDate = lastBolusDate
        self.connected = connected; self.updatedAt = updatedAt; self.recentPoints = recentPoints
    }

    /// Loop-style glucose bands. 0 = low, 1 = in-range, 2 = high, 3 = urgent-high, -1 = unknown.
    public static func rangeCategory(_ mgdl: Int?) -> Int {
        guard let g = mgdl else { return -1 }
        switch g {
        case ..<70: return 0
        case 70..<180: return 1
        case 180..<250: return 2
        default: return 3
        }
    }
    public var rangeCategory: Int { Self.rangeCategory(glucose) }

    public static let placeholder = WidgetSnapshot(
        glucose: 124, trendAscii: "->", iobUnits: 1.2, reservoirUnits: 142, batteryPercent: 80,
        lastBolusUnits: 2.5, lastBolusDate: Date().addingTimeInterval(-1800), connected: true,
        recentPoints: (0..<24).map { .init(t: Date().addingTimeInterval(Double($0 - 24) * 300), mgdl: 110 + ($0 % 6) * 8) })
}

/// App Group–backed store for the widget snapshot. Both the app and the widget read/write here.
public enum WidgetStore {
    /// Must match the App Group entitlement on both the app and the widget extension.
    public static let appGroup = "group.com.zgranowitz.controlx2"
    private static let key = "widgetSnapshot"
    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    public static func save(_ s: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        defaults?.set(data, forKey: key)
    }
    public static func load() -> WidgetSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

/// Deep links the widgets use to open the app. `bolus` opens the bolus-entry sheet (tap-to-bolus
/// is a link into the app's confirm flow — never a one-tap dispense).
public enum ControlX2DeepLink {
    public static let scheme = "controlx2"
    public static let bolus = URL(string: "controlx2://bolus")!
    public static let open = URL(string: "controlx2://open")!
}
