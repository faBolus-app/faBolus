import Foundation
import Observation
import WidgetKit

public enum BolusMode: String, Sendable, CaseIterable { case carbs, units }

/// User preferences, persisted to UserDefaults. Shared to the remotes (Garmin/Watch) via the
/// status payload so the watch honors the same defaults + increments.
@MainActor
@Observable
public final class AppSettings {
    public static let shared = AppSettings()

    public var defaultBolusMode: BolusMode { didSet { d.set(defaultBolusMode.rawValue, forKey: "defaultBolusMode") } }
    public var bolusIncrement: Double { didSet { d.set(bolusIncrement, forKey: "bolusIncrement") } }
    public var carbIncrement: Double { didSet { d.set(carbIncrement, forKey: "carbIncrement") } }
    /// Chart y-axis toggles (glucose + IOB overlay).
    public var showGlucoseAxis: Bool { didSet { d.set(showGlucoseAxis, forKey: "showGlucoseAxis") } }
    public var showIOBAxis: Bool { didSet { d.set(showIOBAxis, forKey: "showIOBAxis") } }

    /// Garmin remote layout: the swipe order of its screens and which one opens first. Pushed to
    /// the watch in the status payload; the Garmin app persists it locally so it survives restarts.
    public var garminScreenOrder: [String] { didSet { d.set(garminScreenOrder, forKey: "garminScreenOrder") } }
    public var garminDefaultScreen: String { didSet { d.set(garminDefaultScreen, forKey: "garminDefaultScreen") } }

    /// Preset dose delivered by the Quick-Bolus widget (via its 1-2-3 confirm). Mirrored to the
    /// App Group so the widget can display it.
    public var widgetBolusUnits: Double {
        didSet { d.set(widgetBolusUnits, forKey: "widgetBolusUnits"); syncWidgetPreset() }
    }

    public static let bolusIncrements: [Double] = [0.01, 0.05, 0.1, 0.5, 1, 2]
    public static let carbIncrements: [Double] = [1, 5, 10, 15]
    public static let widgetBolusOptions: [Double] = [0.5, 1, 2, 3, 5]

    /// Push the widget preset to the App Group and refresh the widget.
    public func syncWidgetPreset() {
        WidgetBolusStore.presetUnits = widgetBolusUnits
        WidgetCenter.shared.reloadAllTimelines()
    }
    /// The Garmin remote's swipeable screens, in the default order. `glance` is the primary HUD.
    public static let garminScreens: [String] = ["glance", "alerts", "history", "details"]
    public static func garminScreenLabel(_ id: String) -> String {
        switch id {
        case "glance": return "Glance (glucose HUD)"
        case "alerts": return "Alerts"
        case "history": return "History plot"
        case "details": return "Details"
        default: return id
        }
    }

    private let d = UserDefaults.standard

    private init() {
        defaultBolusMode = BolusMode(rawValue: d.string(forKey: "defaultBolusMode") ?? "carbs") ?? .carbs
        let bi = d.object(forKey: "bolusIncrement") as? Double
        bolusIncrement = bi ?? 0.05
        let ci = d.object(forKey: "carbIncrement") as? Double
        carbIncrement = ci ?? 5
        showGlucoseAxis = (d.object(forKey: "showGlucoseAxis") as? Bool) ?? true
        showIOBAxis = (d.object(forKey: "showIOBAxis") as? Bool) ?? true
        // Restore the Garmin order, dropping any unknown ids and appending any missing known ones
        // so every screen stays reachable even if the stored list is stale.
        let stored = (d.array(forKey: "garminScreenOrder") as? [String]) ?? Self.garminScreens
        var order = stored.filter { Self.garminScreens.contains($0) }
        for s in Self.garminScreens where !order.contains(s) { order.append(s) }
        garminScreenOrder = order
        let def = d.string(forKey: "garminDefaultScreen") ?? "glance"
        garminDefaultScreen = order.contains(def) ? def : (order.first ?? "glance")
        let wb = d.object(forKey: "widgetBolusUnits") as? Double
        widgetBolusUnits = wb ?? 1.0
    }
}
