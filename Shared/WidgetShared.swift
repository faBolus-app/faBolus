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
    public var glucoseDate: Date?          // when the reading was taken (for 6-min staleness)
    public var trendArrow: String          // Unicode trend arrow (→ ↑ ↓ ⇈ ⇊ ↗ ↘), same as the app HUD
    public var iobUnits: Double
    public var reservoirUnits: Double
    public var batteryPercent: Int
    public var lastBolusUnits: Double?
    public var lastBolusDate: Date?
    public var connected: Bool
    public var updatedAt: Date
    /// Recent readings for a sparkline (oldest→newest, capped small for App Group size).
    public var recentPoints: [Point]

    public init(glucose: Int? = nil, glucoseDate: Date? = nil, trendArrow: String = "", iobUnits: Double = 0,
                reservoirUnits: Double = 0, batteryPercent: Int = 0, lastBolusUnits: Double? = nil,
                lastBolusDate: Date? = nil, connected: Bool = false, updatedAt: Date = Date(),
                recentPoints: [Point] = []) {
        self.glucose = glucose; self.glucoseDate = glucoseDate; self.trendArrow = trendArrow; self.iobUnits = iobUnits
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

    /// True when the reading is older than 6 minutes (don't show the number).
    public var isGlucoseStale: Bool {
        guard let d = glucoseDate else { return glucose != nil }
        return Date().timeIntervalSince(d) > 6 * 60
    }
    /// Glucose string, or "--" when missing/stale.
    public var displayGlucose: String {
        guard let g = glucose, !isGlucoseStale else { return "--" }
        return "\(g)"
    }

    public static let placeholder = WidgetSnapshot(
        glucose: 124, glucoseDate: Date(), trendArrow: "→", iobUnits: 1.2, reservoirUnits: 142, batteryPercent: 80,
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

/// A bolus the Quick-Bolus widget has confirmed (1-2-3) and handed to the app to deliver through
/// the validated signed path. The widget can't drive Bluetooth, so it writes this to the App Group
/// and opens the app, which delivers it (like a Garmin remote bolus) and shows progress + cancel.
public struct WidgetBolusRequest: Codable, Sendable, Equatable {
    public var units: Double
    public var requestId: String
    public var createdAt: Date
    public init(units: Double, requestId: String, createdAt: Date) {
        self.units = units; self.requestId = requestId; self.createdAt = createdAt
    }
}

/// App Group–backed state for the Quick-Bolus widget's 1-2-3 confirmation. The widget records tap
/// progress (reset on a wrong/late tap) and, on completing 1→2→3, a pending request the app
/// consumes. Mirrors the Garmin hold/tap confirm: the widget confirms, the phone delivers.
public enum WidgetBolusStore {
    private static var d: UserDefaults? { UserDefaults(suiteName: WidgetStore.appGroup) }
    /// Seconds allowed to complete the 1-2-3 sequence before it resets (a stray tap can't linger).
    public static let confirmTTL: TimeInterval = 20
    /// The app must consume a completed request within this window (else it's ignored as stale).
    public static let pendingTTL: TimeInterval = 60

    /// Preset dose the widget delivers. The app writes this from Settings; defaults to 1.0 U.
    public static var presetUnits: Double {
        get { let v = d?.double(forKey: "wbPreset") ?? 0; return v > 0 ? v : 1.0 }
        set { d?.set(newValue, forKey: "wbPreset") }
    }

    /// Current confirm progress (0/1/2), or 0 if it has timed out.
    public static func progress() -> Int {
        guard let d else { return 0 }
        let at = d.double(forKey: "wbProgAt")
        if at == 0 || Date().timeIntervalSince1970 - at > confirmTTL { return 0 }
        return d.integer(forKey: "wbProg")
    }
    public static func setProgress(_ n: Int) {
        d?.set(n, forKey: "wbProg")
        d?.set(Date().timeIntervalSince1970, forKey: "wbProgAt")
    }
    public static func resetProgress() { d?.set(0, forKey: "wbProg"); d?.set(0.0, forKey: "wbProgAt") }

    public static func setPending(_ r: WidgetBolusRequest) {
        guard let data = try? JSONEncoder().encode(r) else { return }
        d?.set(data, forKey: "wbPending")
    }
    /// Read and clear the pending request (returns nil if none or older than `pendingTTL`).
    public static func takePending() -> WidgetBolusRequest? {
        guard let data = d?.data(forKey: "wbPending"),
              let r = try? JSONDecoder().decode(WidgetBolusRequest.self, from: data) else { return nil }
        d?.removeObject(forKey: "wbPending")
        return Date().timeIntervalSince(r.createdAt) > pendingTTL ? nil : r
    }
}

/// Deep links the widgets use to open the app. `bolus` opens the bolus-entry sheet (tap-to-bolus
/// is a link into the app's confirm flow — never a one-tap dispense).
public enum ControlX2DeepLink {
    public static let scheme = "controlx2"
    public static let bolus = URL(string: "controlx2://bolus")!
    public static let open = URL(string: "controlx2://open")!
}
