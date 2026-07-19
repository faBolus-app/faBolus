import Foundation
import Observation

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

    public static let bolusIncrements: [Double] = [0.01, 0.05, 0.1, 0.5, 1, 2]
    public static let carbIncrements: [Double] = [1, 5, 10, 15]

    private let d = UserDefaults.standard

    private init() {
        defaultBolusMode = BolusMode(rawValue: d.string(forKey: "defaultBolusMode") ?? "carbs") ?? .carbs
        let bi = d.object(forKey: "bolusIncrement") as? Double
        bolusIncrement = bi ?? 0.05
        let ci = d.object(forKey: "carbIncrement") as? Double
        carbIncrement = ci ?? 5
        showGlucoseAxis = (d.object(forKey: "showGlucoseAxis") as? Bool) ?? true
        showIOBAxis = (d.object(forKey: "showIOBAxis") as? Bool) ?? true
    }
}
