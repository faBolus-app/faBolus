import Foundation
import faBolusCore
import Observation
import WidgetKit

public enum BolusMode: String, Sendable, CaseIterable { case carbs, units }

/// User preferences, persisted to UserDefaults. Shared to the remotes (Garmin/Watch) via the
/// status payload so the watch honors the same defaults + increments.
@MainActor
@Observable
public final class AppSettings {
    public static let shared = AppSettings()

    public var defaultBolusMode: BolusMode { didSet { d.set(defaultBolusMode.rawValue, forKey: "defaultBolusMode"); syncWidgetConfig() } }
    // Phone increments (iPhone bolus entry + the Home-Screen widget).
    public var bolusIncrement: Double { didSet { d.set(bolusIncrement, forKey: "bolusIncrement"); syncWidgetConfig() } }
    public var carbIncrement: Double { didSet { d.set(carbIncrement, forKey: "carbIncrement"); syncWidgetConfig() } }
    // Watch / Garmin increments (sent to the remotes in the status payload) — independent of the phone.
    public var watchBolusIncrement: Double { didSet { d.set(watchBolusIncrement, forKey: "watchBolusIncrement") } }
    public var watchCarbIncrement: Double { didSet { d.set(watchCarbIncrement, forKey: "watchCarbIncrement") } }
    /// Chart y-axis toggles (glucose + IOB overlay).
    public var showGlucoseAxis: Bool { didSet { d.set(showGlucoseAxis, forKey: "showGlucoseAxis") } }
    public var showIOBAxis: Bool { didSet { d.set(showIOBAxis, forKey: "showIOBAxis") } }

    /// Minutes after which a CGM reading is **stale**: shown de-emphasized and no longer used to
    /// auto-fill a bolus correction. A stale reading is never used regardless of whether it's still
    /// shown (greyed) or hidden. Also propagated to the remotes.
    public var glucoseStaleMinutes: Int { didSet { d.set(glucoseStaleMinutes, forKey: "glucoseStaleMinutes"); applyFreshness() } }
    /// Minutes **after it goes stale** to keep showing the greyed value before hiding it ("--").
    /// `0` = hide immediately when stale (no greyed stage); `nil` = never hide (always show greyed).
    public var glucoseHideDelayMinutes: Int? {
        didSet {
            if let v = glucoseHideDelayMinutes { d.set(v, forKey: "glucoseHideDelayMinutes") } else { d.removeObject(forKey: "glucoseHideDelayMinutes") }
            applyFreshness()
        }
    }

    public static let glucoseStaleOptions: [Int] = [4, 5, 6, 8, 10, 15, 20]
    /// Delay after stale before hiding. `0` = immediately; `nil` = never.
    public static let glucoseHideDelayOptions: [Int?] = [0, 5, 10, 15, 30, 45, nil]

    /// Push the freshness thresholds into faBolusCore. Called at launch + whenever they change.
    /// `hideAfter` is an absolute age = stale age + the hide delay (nil delay → never hide).
    public func applyFreshness() {
        GlucoseFreshness.staleAfter = TimeInterval(glucoseStaleMinutes) * 60
        GlucoseFreshness.hideAfter = glucoseHideDelayMinutes.map { GlucoseFreshness.staleAfter + TimeInterval($0) * 60 }
    }

    /// Garmin remote layout: the swipe order of its screens and which one opens first. Pushed to
    /// the watch in the status payload; the Garmin app persists it locally so it survives restarts.
    public var garminScreenOrder: [String] { didSet { d.set(garminScreenOrder, forKey: "garminScreenOrder") } }
    public var garminDefaultScreen: String { didSet { d.set(garminDefaultScreen, forKey: "garminDefaultScreen") } }

    public static let bolusIncrements: [Double] = [0.01, 0.05, 0.1, 0.5, 1, 2]
    public static let carbIncrements: [Double] = [1, 5, 10, 15]

    /// Mirror the phone increments + default mode to the App Group so the Quick-Bolus widget's
    /// − / + step and starting units/carbs mode match. (Max bolus is mirrored by `WidgetPublisher`.)
    public func syncWidgetConfig() {
        WidgetBolusStore.increment = bolusIncrement
        WidgetBolusStore.carbIncrement = carbIncrement
        WidgetBolusStore.defaultMode = defaultBolusMode.rawValue
        WidgetCenter.shared.reloadTimelines(ofKind: "FaBolusQuickBolus")
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
        watchBolusIncrement = (d.object(forKey: "watchBolusIncrement") as? Double) ?? (bi ?? 0.05)
        watchCarbIncrement = (d.object(forKey: "watchCarbIncrement") as? Double) ?? (ci ?? 5)
        showGlucoseAxis = (d.object(forKey: "showGlucoseAxis") as? Bool) ?? true
        showIOBAxis = (d.object(forKey: "showIOBAxis") as? Bool) ?? true
        glucoseStaleMinutes = (d.object(forKey: "glucoseStaleMinutes") as? Int) ?? 6
        glucoseHideDelayMinutes = d.object(forKey: "glucoseHideDelayMinutes") as? Int    // nil = Never
        // Restore the Garmin screen selection + order (the enabled subset, in swipe order),
        // dropping unknown/duplicate ids. Hidden screens stay hidden. Fall back to all screens
        // only if nothing valid is stored, so the watch is never left with no screens.
        let stored = (d.array(forKey: "garminScreenOrder") as? [String]) ?? Self.garminScreens
        var order: [String] = []
        for s in stored where Self.garminScreens.contains(s) && !order.contains(s) { order.append(s) }
        if order.isEmpty { order = Self.garminScreens }
        garminScreenOrder = order
        let def = d.string(forKey: "garminDefaultScreen") ?? "glance"
        garminDefaultScreen = order.contains(def) ? def : (order.first ?? "glance")
        applyFreshness()   // didSet doesn't fire during init; push thresholds into faBolusCore now
    }
}
