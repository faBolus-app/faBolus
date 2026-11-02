import Foundation
import Observation
import RemoteHost
import WidgetContent
import faBolusCore

/// How a bolus is entered by default: through the calculator from carbs, or as units.
public enum BolusEntryMode: String, Codable, Sendable, CaseIterable {
    case carbs, units
}

/// The user's settings, one stored value each. The phone's screens, the watch's config, the widgets and
/// the Live Activity all read these same values, so no setting the phone and the watch share has a
/// second copy. Pairing, the alert switches and the CGM source keep their own stores (`PumpSession`,
/// `AlertCoordinator`, `GlucoseSourceRegistry`).
@Observable @MainActor
public final class AppSettings {
    @ObservationIgnored let defaults: UserDefaults

    // MARK: Bolus

    public var defaultBolusMode: BolusEntryMode { didSet { set(defaultBolusMode.rawValue, .defaultBolusMode) } }
    /// The units step of the bolus screen and the watch.
    public var bolusIncrement: Double { didSet { set(bolusIncrement, .bolusIncrement) } }
    /// The carbs step of the bolus screen and the watch.
    public var carbIncrement: Int { didSet { set(carbIncrement, .carbIncrement) } }
    /// Show the calculator's working on the bolus screen.
    public var showBolusReasoning: Bool { didSet { set(showBolusReasoning, .showBolusReasoning) } }

    public static let bolusIncrements: [Double] = [0.05, 0.1, 0.5, 1, 2]
    public static let carbIncrements: [Int] = [1, 5, 10, 15]

    // MARK: Glucose display and chart

    public var glucoseUnit: GlucoseUnit { didSet { set(glucoseUnit.rawValue, .glucoseUnit) } }
    public var showGlucoseUnitLabels: Bool { didSet { set(showGlucoseUnitLabels, .showGlucoseUnitLabels) } }
    public var showGlucoseAxis: Bool { didSet { set(showGlucoseAxis, .showGlucoseAxis) } }
    public var showIOBAxis: Bool { didSet { set(showIOBAxis, .showIOBAxis) } }
    public var showBolusBars: Bool { didSet { set(showBolusBars, .showBolusBars) } }
    /// The glucose chart's bounds, on the phone and (unless the watch override is set) the watch.
    public var glucosePlotFloor: Int { didSet { set(glucosePlotFloor, .glucosePlotFloor) } }
    public var glucosePlotCeiling: Int { didSet { set(glucosePlotCeiling, .glucosePlotCeiling) } }
    /// The watch's own chart bounds, ahead of the shared ones; `nil` follows the phone's.
    public var watchPlotFloor: Int? { didSet { set(watchPlotFloor, .watchPlotFloor) } }
    public var watchPlotCeiling: Int? { didSet { set(watchPlotCeiling, .watchPlotCeiling) } }
    public var showStats: Bool { didSet { set(showStats, .showStats) } }
    /// The phone's Details rows, in order (`DetailsField`). Rows not listed are hidden.
    public var detailsOrder: [String] { didSet { set(detailsOrder, .detailsOrder) } }
    /// The dashboard's status pills, in order (`StatusPill`).
    public var pillsOrder: [String] { didSet { set(pillsOrder, .pillsOrder) } }

    // MARK: Freshness

    /// Glucose older than this many minutes is shown marked as stale.
    public var glucoseStaleMinutes: Int { didSet { set(glucoseStaleMinutes, .glucoseStaleMinutes) } }
    /// Minutes after going stale that a reading is hidden; `nil` never hides.
    public var glucoseHideDelayMinutes: Int? { didSet { set(glucoseHideDelayMinutes, .glucoseHideDelayMinutes) } }
    /// Reservoir, battery, basal and Control-IQ older than this many minutes are shown marked as stale.
    public var pumpStatusStaleMinutes: Int { didSet { set(pumpStatusStaleMinutes, .pumpStatusStaleMinutes) } }

    public static let glucoseStaleOptions = [4, 5, 6, 8, 10, 15, 20]
    public static let glucoseHideDelayOptions: [Int?] = [0, 5, 10, 15, 30, 45, nil]
    public static let pumpStatusStaleOptions = [5, 10, 15, 20, 30, 60]

    /// The one set of windows the phone, the watch, the widgets and the Live Activity use. IOB and the
    /// calculator settings keep their fixed windows: they guard doses (R7).
    public var freshness: FreshnessThresholds {
        let stale = TimeInterval(glucoseStaleMinutes * 60)
        return FreshnessThresholds(
            glucoseStaleAfter: stale, glucoseHideAfter: glucoseHideDelayMinutes.map { stale + TimeInterval($0 * 60) },
            pumpStatusStaleAfter: TimeInterval(pumpStatusStaleMinutes * 60))
    }

    // MARK: Access

    /// Nothing on the phone may change the pump except cancelling and clearing alerts.
    public var phoneReadOnly: Bool { didSet { set(phoneReadOnly, .phoneReadOnly) } }
    /// No remote may change the pump except cancelling and clearing alerts.
    public var remotesReadOnly: Bool { didSet { set(remotesReadOnly, .remotesReadOnly) } }
    /// The watch may send boluses. Off by default.
    public var garminBolusEnabled: Bool { didSet { set(garminBolusEnabled, .garminBolusEnabled) } }
    /// The largest bolus a remote may request; `nil` is no limit beyond the pump's.
    public var remoteBolusLimitUnits: Double? { didSet { set(remoteBolusLimitUnits, .remoteBolusLimitUnits) } }

    public static let remoteBolusLimitOptions: [Double] = [1, 2, 3, 5, 8, 10, 15, 20]

    // MARK: Watch

    public var watchDefaultBolusMode: BolusEntryMode {
        didSet { set(watchDefaultBolusMode.rawValue, .watchDefaultBolusMode) }
    }
    public var watchScreenOrder: [String] { didSet { set(watchScreenOrder, .watchScreenOrder) } }
    public var watchDefaultScreen: String { didSet { set(watchDefaultScreen, .watchDefaultScreen) } }
    public var watchDetailsOrder: [String] { didSet { set(watchDetailsOrder, .watchDetailsOrder) } }
    public var watchChartRanges: [Int] { didSet { set(watchChartRanges, .watchChartRanges) } }
    public var complicationSlots: [String] { didSet { set(complicationSlots, .complicationSlots) } }
    /// The complication slots name what they show ("IOB 1.25"). Off by default: the value alone.
    public var complicationNames: Bool { didSet { set(complicationNames, .complicationNames) } }

    // MARK: Live Activity

    public var liveActivityEnabled: Bool { didSet { set(liveActivityEnabled, .liveActivityEnabled) } }
    public var liveActivityLayout: LiveActivityLayout {
        didSet { set(try? JSONEncoder().encode(liveActivityLayout), .liveActivityLayout) }
    }

    // MARK: First run

    public var hasCompletedOnboarding: Bool { didSet { set(hasCompletedOnboarding, .hasCompletedOnboarding) } }
    public var notificationDisclosureShown: Bool {
        didSet { set(notificationDisclosureShown, .notificationDisclosureShown) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults
        func value<T>(_ key: Key) -> T? { d.object(forKey: key.rawValue) as? T }

        defaultBolusMode = (value(.defaultBolusMode)).flatMap(BolusEntryMode.init(rawValue:)) ?? .carbs
        bolusIncrement = value(.bolusIncrement).flatMap { Self.bolusIncrements.contains($0) ? $0 : nil } ?? 0.05
        carbIncrement = value(.carbIncrement).flatMap { Self.carbIncrements.contains($0) ? $0 : nil } ?? 5
        showBolusReasoning = value(.showBolusReasoning) ?? true

        glucoseUnit = value(.glucoseUnit).flatMap(GlucoseUnit.init(rawValue:)) ?? .mgdl
        showGlucoseUnitLabels = value(.showGlucoseUnitLabels) ?? false
        showGlucoseAxis = value(.showGlucoseAxis) ?? true
        showIOBAxis = value(.showIOBAxis) ?? true
        showBolusBars = value(.showBolusBars) ?? true
        let plot = GlucosePlotScale.resolve(
            storedFloor: value(.glucosePlotFloor), storedCeiling: value(.glucosePlotCeiling))
        glucosePlotFloor = plot.floor
        glucosePlotCeiling = plot.ceiling
        if let floor: Int = value(.watchPlotFloor), let ceiling: Int = value(.watchPlotCeiling) {
            let watch = GlucosePlotScale.resolve(storedFloor: floor, storedCeiling: ceiling)
            watchPlotFloor = watch.floor
            watchPlotCeiling = watch.ceiling
        } else {
            watchPlotFloor = nil
            watchPlotCeiling = nil
        }
        showStats = value(.showStats) ?? false
        detailsOrder = Self.restoreOrder(
            value(.detailsOrder), allowed: DetailsField.allIDs, fallback: DetailsField.defaultIDs)
        pillsOrder = Self.restoreOrder(value(.pillsOrder), allowed: StatusPill.allIDs, fallback: StatusPill.defaultIDs)

        glucoseStaleMinutes =
            value(.glucoseStaleMinutes).flatMap { Self.glucoseStaleOptions.contains($0) ? $0 : nil } ?? 6
        glucoseHideDelayMinutes = value(.glucoseHideDelayMinutes).flatMap {
            Self.glucoseHideDelayOptions.contains($0) ? $0 : nil
        }
        pumpStatusStaleMinutes =
            value(.pumpStatusStaleMinutes).flatMap { Self.pumpStatusStaleOptions.contains($0) ? $0 : nil } ?? 15

        phoneReadOnly = value(.phoneReadOnly) ?? false
        remotesReadOnly = value(.remotesReadOnly) ?? false
        garminBolusEnabled = value(.garminBolusEnabled) ?? false
        remoteBolusLimitUnits = value(.remoteBolusLimitUnits).flatMap { (v: Double) in v.isFinite && v > 0 ? v : nil }

        watchDefaultBolusMode = value(.watchDefaultBolusMode).flatMap(BolusEntryMode.init(rawValue:)) ?? .carbs
        let watch = WatchPreferences()
        let screens = Self.restoreOrder(
            value(.watchScreenOrder), allowed: WatchScreen.allIDs, fallback: watch.screenOrder)
        watchScreenOrder = screens
        let screen: String? = value(.watchDefaultScreen)
        watchDefaultScreen = screen.flatMap { screens.contains($0) ? $0 : nil } ?? screens[0]
        watchDetailsOrder = Self.restoreOrder(
            value(.watchDetailsOrder), allowed: DetailsField.allIDs, fallback: watch.detailsOrder)
        let ranges = (value(.watchChartRanges) as [Int]?)?.filter { Self.watchChartRangeOptions.contains($0) }
        watchChartRanges = (ranges?.isEmpty ?? true) ? watch.watchChartRanges : Array(Set(ranges!)).sorted()
        complicationSlots = Array(
            Self.restoreOrder(
                value(.complicationSlots), allowed: Self.complicationFields, fallback: watch.complicationSlots
            ).prefix(3))
        complicationNames = value(.complicationNames) ?? false

        liveActivityEnabled = value(.liveActivityEnabled) ?? false
        liveActivityLayout =
            (value(.liveActivityLayout) as Data?).flatMap {
                try? JSONDecoder().decode(LiveActivityLayout.self, from: $0)
            }
            ?? LiveActivityLayout()

        hasCompletedOnboarding = value(.hasCompletedOnboarding) ?? false
        notificationDisclosureShown = value(.notificationDisclosureShown) ?? false
    }

    public static let watchChartRangeOptions = [3, 6, 12, 24]
    public static let complicationFields = ["iob", "reservoir", "battery", "basal"]

    /// Stored ids that are known and unique, in stored order; the fallback when none is.
    nonisolated static func restoreOrder(_ stored: [String]?, allowed: [String], fallback: [String]) -> [String] {
        guard let stored else { return fallback }
        var out: [String] = []
        for id in stored where allowed.contains(id) && !out.contains(id) { out.append(id) }
        return out.isEmpty ? fallback : out
    }

    // MARK: Storage

    /// Every key this app stores. `settingsSurviveARelaunch` checks the values come back through them.
    public enum Key: String, CaseIterable, Sendable {
        case defaultBolusMode, bolusIncrement, carbIncrement, showBolusReasoning
        case glucoseUnit = "glucoseDisplayUnit"
        case showGlucoseUnitLabels, showGlucoseAxis, showIOBAxis, showBolusBars, glucosePlotFloor, glucosePlotCeiling
        case watchPlotFloor = "glucosePlotFloorSmall"
        case watchPlotCeiling = "glucosePlotCeilingSmall"
        case showStats, detailsOrder, pillsOrder
        case glucoseStaleMinutes, glucoseHideDelayMinutes, pumpStatusStaleMinutes
        case phoneReadOnly, remotesReadOnly, garminBolusEnabled
        case remoteBolusLimitUnits = "remoteBolusCeiling"
        case watchDefaultBolusMode
        case watchScreenOrder = "garminScreenOrder"
        case watchDefaultScreen = "garminDefaultScreen"
        case watchDetailsOrder, watchChartRanges
        case complicationSlots = "garminComplicationSlots"
        case complicationNames = "garminComplicationNames"
        case liveActivityEnabled, liveActivityLayout
        case hasCompletedOnboarding, notificationDisclosureShown
    }

    private func set(_ value: Any?, _ key: Key) {
        if let value { defaults.set(value, forKey: key.rawValue) } else { defaults.removeObject(forKey: key.rawValue) }
    }
}

/// A row on the Details card (the phone's and the watch's).
public enum DetailsField: String, CaseIterable, Sendable {
    case iob, reservoir, battery, cgm, lastBolus, carbRatio, isf, target, maxBolus
    /// When Control-IQ last auto-corrected. Off by default, and hidden while none is known.
    case autoCorrection

    public static var allIDs: [String] { allCases.map(\.rawValue) }
    public static let defaultIDs = [
        "iob", "reservoir", "battery", "cgm", "lastBolus", "carbRatio", "isf", "target", "maxBolus"
    ]

    public var label: String {
        switch self {
        case .iob: return "Active insulin (IOB)"
        case .reservoir: return "Reservoir"
        case .battery: return "Pump battery"
        case .cgm: return "CGM"
        case .lastBolus: return "Last bolus"
        case .carbRatio: return "Carb ratio"
        case .isf: return "Correction factor (ISF)"
        case .target: return "Target glucose"
        case .maxBolus: return "Max bolus"
        case .autoCorrection: return "Last auto-correction"
        }
    }
}

/// A status pill on the dashboard.
public enum StatusPill: String, CaseIterable, Sendable {
    case iob, reservoir, battery, cgm, basal, controlIQ, lastBolus, carbRatio, isf, target, maxBolus

    public static var allIDs: [String] { allCases.map(\.rawValue) }
    public static let defaultIDs = ["iob", "reservoir", "battery", "cgm", "basal", "controlIQ"]

    public var label: String {
        switch self {
        case .iob: return "Active insulin"
        case .reservoir: return "Reservoir"
        case .battery: return "Pump battery"
        case .cgm: return "CGM"
        case .basal: return "Basal / Suspended"
        case .controlIQ: return "Control-IQ"
        case .lastBolus: return "Last bolus"
        case .carbRatio: return "Carb ratio"
        case .isf: return "Correction (ISF)"
        case .target: return "Target glucose"
        case .maxBolus: return "Max bolus"
        }
    }
}

/// A screen of the watch app.
public enum WatchScreen: String, CaseIterable, Sendable {
    case glance, glucose, clock
    case bolusOnly = "bolusonly"
    case alerts, history, details

    public static var allIDs: [String] { allCases.map(\.rawValue) }

    public var label: String {
        switch self {
        case .glance: return "Glance (glucose + bolus)"
        case .glucose: return "Glucose only (no bolus button)"
        case .clock: return "Clock + glucose (no bolus)"
        case .bolusOnly: return "Bolus button only"
        case .alerts: return "Alerts"
        case .history: return "History plot"
        case .details: return "Details"
        }
    }
}
