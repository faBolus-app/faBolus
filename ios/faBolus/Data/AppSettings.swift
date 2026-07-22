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
    // Watch / Garmin default entry mode (sent to the remotes) — independent of the phone.
    public var watchDefaultBolusMode: BolusMode { didSet { d.set(watchDefaultBolusMode.rawValue, forKey: "watchDefaultBolusMode") } }
    // Phone increments (iPhone bolus entry + the Home-Screen widget).
    public var bolusIncrement: Double { didSet { d.set(bolusIncrement, forKey: "bolusIncrement"); syncWidgetConfig() } }
    public var carbIncrement: Double { didSet { d.set(carbIncrement, forKey: "carbIncrement"); syncWidgetConfig() } }
    // Watch / Garmin increments (sent to the remotes in the status payload) — independent of the phone.
    public var watchBolusIncrement: Double { didSet { d.set(watchBolusIncrement, forKey: "watchBolusIncrement") } }
    public var watchCarbIncrement: Double { didSet { d.set(watchCarbIncrement, forKey: "watchCarbIncrement") } }
    /// Chart series toggles. Glucose (left axis), the IOB line, and the bolus bars each toggle
    /// independently; IOB + bolus bars share the right (units) axis.
    public var showGlucoseAxis: Bool { didSet { d.set(showGlucoseAxis, forKey: "showGlucoseAxis") } }
    public var showIOBAxis: Bool { didSet { d.set(showIOBAxis, forKey: "showIOBAxis") } }
    public var showBolusBars: Bool { didSet { d.set(showBolusBars, forKey: "showBolusBars") } }

    /// Show the opt-in **Statistics** card on the dashboard (Time-in-Range, GMI, mean, CV over the
    /// in-memory ~24 h history). **Default OFF** so regular use stays clean. See [[GlucoseStatistics]].
    public var showStats: Bool { didSet { d.set(showStats, forKey: "showStats") } }

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

    /// Master opt-in for advanced pump control (suspend/resume, temp basal, modes, profiles,
    /// Control-IQ settings, limits, cartridge/fill, time sync). **Default OFF.** Even when on, each
    /// action is additionally gated on the pump advertising the capability (Mobi-only in practice)
    /// via `advancedControlAllowed(_:isMobi:)`. Insulin-affecting actions still go through the
    /// confirm/hold + max-bolus-clamp + WritePolicy interlocks.
    public var advancedControlEnabled: Bool { didSet { d.set(advancedControlEnabled, forKey: "advancedControlEnabled") } }

    /// **Read-only mode (this phone).** Turns the app into a safe viewer: bolusing and all pump control
    /// are disabled and their UI (Bolus tab, Pump Control) is hidden. **Default OFF.** Clearing pump
    /// alerts is also disabled by default while read-only, unless `readOnlyAllowAlertClear` is on.
    public var phoneReadOnly: Bool { didSet { d.set(phoneReadOnly, forKey: "phoneReadOnly") } }
    /// Sub-option of read-only mode: still allow clearing/snoozing pump alerts. **Default OFF.**
    public var readOnlyAllowAlertClear: Bool { didSet { d.set(readOnlyAllowAlertClear, forKey: "readOnlyAllowAlertClear") } }
    /// **Read-only mode for the Apple Watch + Garmin remotes.** They hide their bolus screen/button and
    /// can't deliver (the host refuses too); viewing stays. Independent of the phone flag. **Default OFF.**
    public var remotesReadOnly: Bool { didSet { d.set(remotesReadOnly, forKey: "remotesReadOnly") } }

    /// Keep the pump's clock aligned with this phone: sync at most once a day while connected, and
    /// immediately when the phone's clock or time zone changes (travel / DST). **Default ON.** Only
    /// active on pumps that honor the time write (**Mobi** — t:slim X2 doesn't accept it), gated on
    /// `capabilities.supportsTimeSync`; not insulin-affecting and independent of `advancedControlEnabled`.
    public var autoSyncPumpTime: Bool { didSet { d.set(autoSyncPumpTime, forKey: "autoSyncPumpTime") } }

    /// **Auto Exercise mode** — when a workout starts (via the Shortcuts automation the user sets up),
    /// switch the pump into Control-IQ Exercise mode, and back to normal when it ends. **Default OFF.**
    /// Auto-switching applies only to a **Mobi** (t:slim X2 can't; it gets a reminder if `modeReminders`
    /// is on). See [[jwoglom-parity-roadmap]].
    public var autoExerciseMode: Bool { didSet { d.set(autoExerciseMode, forKey: "autoExerciseMode") } }
    /// **Auto Sleep mode** — when the iPhone enters Sleep Focus (via the Shortcuts automation), switch
    /// the pump into Sleep mode, and back when it ends. **Default OFF.** Mobi-only auto-switch.
    public var autoSleepMode: Bool { didSet { d.set(autoSleepMode, forKey: "autoSleepMode") } }
    /// **Mode reminders** — when an auto mode-switch can't be applied automatically (a t:slim, or the
    /// pump isn't connected), post a notification reminding the user to switch modes on the pump
    /// themselves. **Default OFF.**
    public var modeReminders: Bool { didSet { d.set(modeReminders, forKey: "modeReminders") } }

    /// Master gate for the Bluetooth remote peripheral (Mac + remote iPhone). **Default OFF.** While
    /// off, the phone never advertises a BLE service, so there's no added attack surface or battery
    /// cost. Unlike the Apple Watch / Garmin links (bound to your own paired device, not discoverable
    /// by third parties), the BLE peripheral advertises openly — hence the opt-in + warning. The link
    /// is authenticated (one-time code + token) and end-to-end encrypted ([[SealedTransport]]).
    public var remoteBluetoothEnabled: Bool { didSet { d.set(remoteBluetoothEnabled, forKey: "remoteBluetoothEnabled") } }

    /// Reverse approval (opt-in): a bolus started on **this** phone must be approved by a paired remote
    /// (e.g. a parent) before it delivers. **Default OFF.** Only takes effect when a remote is paired;
    /// if no paired remote responds within the timeout the bolus is aborted (safe default).
    public var requireRemoteBolusApproval: Bool { didSet { d.set(requireRemoteBolusApproval, forKey: "requireRemoteBolusApproval") } }

    /// User-defined auto-rules for pump alerts (time-of-day / kind / glucose → auto-snooze or
    /// auto-dismiss), persisted as JSON. **Alarms are never auto-acted** regardless of rules — the
    /// engine hard-excludes them. See [[AlertRuleEngine]].
    public var alertRules: [AlertRule] {
        didSet { d.set((try? JSONEncoder().encode(alertRules)) ?? Data(), forKey: "alertRules") }
    }

    /// Upload glucose + boluses + pump status to a Nightscout site. **Default OFF** — this publishes
    /// health data off-device, so it's strictly opt-in. Uses the same `nightscout.url` + token the
    /// follower source uses (plus an optional API secret). See [[NightscoutUploader]].
    public var nightscoutUploadEnabled: Bool { didSet { d.set(nightscoutUploadEnabled, forKey: "nightscoutUploadEnabled") } }

    /// Child (locked) mode: a PIN-protected mode a parent enables on a child's device. When on, only
    /// the features in `childAllowed` are permitted; everything that dispenses insulin is blocked by
    /// default. The PIN hash lives in the Keychain ([[ChildMode]]), not here.
    /// Show the extended (combo) bolus controls on the bolus screen. **Default OFF** to keep the
    /// screen simple. When on, the user can split a dose into now + over-a-duration.
    public var extendedBolusEnabled: Bool { didSet { d.set(extendedBolusEnabled, forKey: "extendedBolusEnabled") } }
    /// Show the collapsible "reasoning" breakdown (IOB, carb+correction, max-safe hint) under the
    /// recommendation. Default ON but collapsed; turn off to remove it entirely.
    public var showBolusReasoning: Bool { didSet { d.set(showBolusReasoning, forKey: "showBolusReasoning") } }

    public var childModeEnabled: Bool { didSet { d.set(childModeEnabled, forKey: "childModeEnabled") } }
    public var childAllowed: Set<ChildFeature> {
        didSet { d.set((try? JSONEncoder().encode(childAllowed)) ?? Data(), forKey: "childAllowed") }
    }
    /// Whether `feature` is currently permitted (always true when child mode is off).
    public func childAllows(_ feature: ChildFeature) -> Bool {
        !childModeEnabled || childAllowed.contains(feature)
    }

    /// Whether the advanced-control surface should be shown/enabled: opt-in ON **and** the pump is a
    /// Mobi (advanced control is rejected by t:slim X2). This is the single gate the control UI uses.
    public func advancedControlAllowed(isMobi: Bool) -> Bool {
        advancedControlEnabled && isMobi
    }

    /// Garmin remote layout: the swipe order of its screens and which one opens first. Pushed to
    /// the watch in the status payload; the Garmin app persists it locally so it survives restarts.
    public var garminScreenOrder: [String] { didSet { d.set(garminScreenOrder, forKey: "garminScreenOrder") } }
    public var garminDefaultScreen: String { didSet { d.set(garminDefaultScreen, forKey: "garminDefaultScreen") } }
    /// How the Garmin BG complication presents: "numericColor" (numeric value with range-coloring +
    /// a Latin trend in the unit slot) or "stringTrend" (a plain "124 ^" string, no color). Mirrored.
    public var garminComplicationDisplay: String { didSet { d.set(garminComplicationDisplay, forKey: "garminComplicationDisplay") } }
    /// Which Garmin store app the phone pairs with: "beta" (id a1b2c3d4…) or "official" (id ded131…).
    /// Developer setting; applied when the Garmin remote (re)registers — reopen the app after changing.
    public var garminTargetApp: String { didSet { d.set(garminTargetApp, forKey: "garminTargetApp") } }
    public static let complicationDisplayOptions = ["numericColor", "stringTrend"]
    public static func complicationDisplayLabel(_ id: String) -> String {
        id == "stringTrend" ? "Value + trend (no color)" : "Value + color + trend"
    }

    /// Which detail rows show, and in what order, on the **phone** Details card. Phone-only.
    public var detailsOrder: [String] { didSet { d.set(detailsOrder, forKey: "detailsOrder") } }
    /// Which detail rows show, and in what order, on the **watch/Garmin** Details page — independent
    /// of the phone's. Mirrored to the remotes.
    public var watchDetailsOrder: [String] { didSet { d.set(watchDetailsOrder, forKey: "watchDetailsOrder") } }
    /// Which status pills show, and in what order, on the phone dashboard.
    public var pillsOrder: [String] { didSet { d.set(pillsOrder, forKey: "pillsOrder") } }
    /// Which time ranges the watch history chart cycles through when tapped (subset of 3/6/12/24 h).
    /// Mirrored to the watch. At least one is always kept.
    public var watchChartRanges: [Int] { didSet { d.set(watchChartRanges, forKey: "watchChartRanges") } }

    /// Detail rows available on the Details card / watch Details page, in default order.
    public static let detailFields: [String] =
        ["iob", "reservoir", "battery", "cgm", "lastBolus", "carbRatio", "isf", "target", "maxBolus"]
    public static func detailFieldLabel(_ id: String) -> String {
        switch id {
        case "iob": return "Active insulin (IOB)"
        case "reservoir": return "Reservoir"
        case "battery": return "Pump battery"
        case "cgm": return "CGM"
        case "lastBolus": return "Last bolus"
        case "carbRatio": return "Carb ratio"
        case "isf": return "Correction factor (ISF)"
        case "target": return "Target glucose"
        case "maxBolus": return "Max bolus"
        default: return id
        }
    }
    /// Status pills available on the dashboard, in default order (first 6 shown by default).
    public static let pillItems: [String] =
        ["iob", "reservoir", "battery", "cgm", "basal", "controlIQ", "lastBolus", "carbRatio", "isf", "target", "maxBolus", "cob"]
    public static func pillLabel(_ id: String) -> String {
        switch id {
        case "iob": return "Active insulin"
        case "reservoir": return "Reservoir"
        case "battery": return "Pump battery"
        case "cgm": return "CGM"
        case "basal": return "Basal / Suspended"
        case "controlIQ": return "Control-IQ"
        case "lastBolus": return "Last bolus"
        case "carbRatio": return "Carb ratio"
        case "isf": return "Correction (ISF)"
        case "target": return "Target glucose"
        case "maxBolus": return "Max bolus"
        case "cob": return "Active carbs (COB)"
        default: return id
        }
    }
    /// Pills shown by default when the user hasn't customized (the original set).
    public static let defaultPills: [String] = ["iob", "reservoir", "battery", "cgm", "basal", "controlIQ"]
    /// The watch history-chart tap-through ranges available to enable.
    public static let chartRangeOptions: [Int] = [3, 6, 12, 24]

    /// Restore a reorder/hide list: keep stored ids that are known + unique, in stored order; fall
    /// back to the full list if nothing valid is stored (never leave the surface empty).
    private static func restoreOrder(_ stored: [String]?, all: [String]) -> [String] {
        var order: [String] = []
        for s in stored ?? all where all.contains(s) && !order.contains(s) { order.append(s) }
        return order.isEmpty ? all : order
    }

    // Smallest is 0.05 U — the pump's real minimum increment (sub-0.05 doses are rejected by the
    // pump, so a 0.01 option was misleading). Any previously-persisted 0.01 is clamped up in init.
    public static let bolusIncrements: [Double] = [0.05, 0.1, 0.5, 1, 2]
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
    public static let garminScreens: [String] = ["glance", "glucose", "alerts", "history", "details"]
    public static func garminScreenLabel(_ id: String) -> String {
        switch id {
        case "glance": return "Glance (glucose + bolus)"
        case "glucose": return "Glucose only (no bolus button)"
        case "alerts": return "Alerts"
        case "history": return "History plot"
        case "details": return "Details"
        default: return id
        }
    }

    private let d = UserDefaults.standard

    private init() {
        defaultBolusMode = BolusMode(rawValue: d.string(forKey: "defaultBolusMode") ?? "carbs") ?? .carbs
        // Watch default: fall back to the phone default for existing users who never set it separately.
        watchDefaultBolusMode = BolusMode(rawValue: d.string(forKey: "watchDefaultBolusMode")
            ?? d.string(forKey: "defaultBolusMode") ?? "carbs") ?? .carbs
        let bi = d.object(forKey: "bolusIncrement") as? Double
        // Clamp to the 0.05 minimum: a user who previously chose the (now-removed) 0.01 option would
        // otherwise land on a value absent from `bolusIncrements`, showing an empty Picker.
        bolusIncrement = max(0.05, bi ?? 0.05)
        let ci = d.object(forKey: "carbIncrement") as? Double
        carbIncrement = ci ?? 5
        watchBolusIncrement = max(0.05, (d.object(forKey: "watchBolusIncrement") as? Double) ?? (bi ?? 0.05))
        watchCarbIncrement = (d.object(forKey: "watchCarbIncrement") as? Double) ?? (ci ?? 5)
        showGlucoseAxis = (d.object(forKey: "showGlucoseAxis") as? Bool) ?? true
        showIOBAxis = (d.object(forKey: "showIOBAxis") as? Bool) ?? true
        showBolusBars = (d.object(forKey: "showBolusBars") as? Bool) ?? true
        showStats = (d.object(forKey: "showStats") as? Bool) ?? false
        glucoseStaleMinutes = (d.object(forKey: "glucoseStaleMinutes") as? Int) ?? 6
        glucoseHideDelayMinutes = d.object(forKey: "glucoseHideDelayMinutes") as? Int    // nil = Never
        advancedControlEnabled = (d.object(forKey: "advancedControlEnabled") as? Bool) ?? false
        phoneReadOnly = (d.object(forKey: "phoneReadOnly") as? Bool) ?? false
        readOnlyAllowAlertClear = (d.object(forKey: "readOnlyAllowAlertClear") as? Bool) ?? false
        remotesReadOnly = (d.object(forKey: "remotesReadOnly") as? Bool) ?? false
        autoSyncPumpTime = (d.object(forKey: "autoSyncPumpTime") as? Bool) ?? true
        autoExerciseMode = (d.object(forKey: "autoExerciseMode") as? Bool) ?? false
        autoSleepMode = (d.object(forKey: "autoSleepMode") as? Bool) ?? false
        modeReminders = (d.object(forKey: "modeReminders") as? Bool) ?? false
        remoteBluetoothEnabled = (d.object(forKey: "remoteBluetoothEnabled") as? Bool) ?? false
        requireRemoteBolusApproval = (d.object(forKey: "requireRemoteBolusApproval") as? Bool) ?? false
        alertRules = d.data(forKey: "alertRules").flatMap { try? JSONDecoder().decode([AlertRule].self, from: $0) } ?? []
        nightscoutUploadEnabled = (d.object(forKey: "nightscoutUploadEnabled") as? Bool) ?? false
        extendedBolusEnabled = (d.object(forKey: "extendedBolusEnabled") as? Bool) ?? false
        showBolusReasoning = (d.object(forKey: "showBolusReasoning") as? Bool) ?? true
        childModeEnabled = (d.object(forKey: "childModeEnabled") as? Bool) ?? false
        childAllowed = d.data(forKey: "childAllowed").flatMap { try? JSONDecoder().decode(Set<ChildFeature>.self, from: $0) } ?? ChildFeature.defaultAllowed
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
        let cd = d.string(forKey: "garminComplicationDisplay") ?? "numericColor"
        garminComplicationDisplay = Self.complicationDisplayOptions.contains(cd) ? cd : "numericColor"
        let gt = d.string(forKey: "garminTargetApp") ?? "beta"   // default to beta (official listing is dormant)
        garminTargetApp = (gt == "official") ? "official" : "beta"
        detailsOrder = Self.restoreOrder(d.array(forKey: "detailsOrder") as? [String], all: Self.detailFields)
        watchDetailsOrder = Self.restoreOrder(d.array(forKey: "watchDetailsOrder") as? [String], all: Self.detailFields)
        // Default to the original 6 pills (the full option set is larger); honor a saved selection.
        pillsOrder = Self.restoreOrder(d.array(forKey: "pillsOrder") as? [String] ?? Self.defaultPills, all: Self.pillItems)
        let storedRanges = (d.array(forKey: "watchChartRanges") as? [Int])?
            .filter { Self.chartRangeOptions.contains($0) }
        watchChartRanges = (storedRanges?.isEmpty ?? true) ? Self.chartRangeOptions : storedRanges!.sorted()
        applyFreshness()   // didSet doesn't fire during init; push thresholds into faBolusCore now
    }

    // MARK: - Backup / restore (see SettingsBackup + BackupModels)

    /// Snapshot the non-secret preferences for a backup. Excludes derived/cache keys and all secrets
    /// (those live in the Keychain — see SettingsBackup). `nil`-valued optionals are omitted.
    public func backupSnapshot() -> [String: BackupValue] {
        var m: [String: BackupValue] = [
            "defaultBolusMode": .string(defaultBolusMode.rawValue),
            "bolusIncrement": .double(bolusIncrement),
            "carbIncrement": .double(carbIncrement),
            "extendedBolusEnabled": .bool(extendedBolusEnabled),
            "showBolusReasoning": .bool(showBolusReasoning),
            "watchDefaultBolusMode": .string(watchDefaultBolusMode.rawValue),
            "watchBolusIncrement": .double(watchBolusIncrement),
            "watchCarbIncrement": .double(watchCarbIncrement),
            "showGlucoseAxis": .bool(showGlucoseAxis),
            "showIOBAxis": .bool(showIOBAxis),
            "showBolusBars": .bool(showBolusBars),
            "showStats": .bool(showStats),
            "detailsOrder": .stringArray(detailsOrder),
            "watchDetailsOrder": .stringArray(watchDetailsOrder),
            "pillsOrder": .stringArray(pillsOrder),
            "watchChartRanges": .intArray(watchChartRanges),
            "glucoseStaleMinutes": .int(glucoseStaleMinutes),
            "advancedControlEnabled": .bool(advancedControlEnabled),
            "autoSyncPumpTime": .bool(autoSyncPumpTime),
            "autoExerciseMode": .bool(autoExerciseMode),
            "autoSleepMode": .bool(autoSleepMode),
            "modeReminders": .bool(modeReminders),
            "phoneReadOnly": .bool(phoneReadOnly),
            "readOnlyAllowAlertClear": .bool(readOnlyAllowAlertClear),
            "remotesReadOnly": .bool(remotesReadOnly),
            "remoteBluetoothEnabled": .bool(remoteBluetoothEnabled),
            "requireRemoteBolusApproval": .bool(requireRemoteBolusApproval),
            "garminScreenOrder": .stringArray(garminScreenOrder),
            "garminDefaultScreen": .string(garminDefaultScreen),
            "garminComplicationDisplay": .string(garminComplicationDisplay),
            "garminTargetApp": .string(garminTargetApp),
            "nightscoutUploadEnabled": .bool(nightscoutUploadEnabled),
            "childModeEnabled": .bool(childModeEnabled),
        ]
        if let hide = glucoseHideDelayMinutes { m["glucoseHideDelayMinutes"] = .int(hide) }
        if let d1 = d.data(forKey: "alertRules") { m["alertRules"] = .data(d1) }
        if let d2 = d.data(forKey: "childAllowed") { m["childAllowed"] = .data(d2) }
        return m
    }

    /// Apply a backed-up preferences dict. Assigns the real properties (so `didSet` persists + updates
    /// the live UI). Keys absent from the backup are left unchanged.
    public func applyBackup(_ m: [String: BackupValue]) {
        func b(_ k: String) -> Bool? { if case .bool(let v)? = m[k] { return v }; return nil }
        func i(_ k: String) -> Int? { if case .int(let v)? = m[k] { return v }; return nil }
        func dbl(_ k: String) -> Double? { if case .double(let v)? = m[k] { return v }; return nil }
        func s(_ k: String) -> String? { if case .string(let v)? = m[k] { return v }; return nil }
        func sa(_ k: String) -> [String]? { if case .stringArray(let v)? = m[k] { return v }; return nil }
        func ia(_ k: String) -> [Int]? { if case .intArray(let v)? = m[k] { return v }; return nil }
        func dat(_ k: String) -> Data? { if case .data(let v)? = m[k] { return v }; return nil }

        if let v = s("defaultBolusMode"), let mode = BolusMode(rawValue: v) { defaultBolusMode = mode }
        if let v = dbl("bolusIncrement") { bolusIncrement = v }
        if let v = dbl("carbIncrement") { carbIncrement = v }
        if let v = b("extendedBolusEnabled") { extendedBolusEnabled = v }
        if let v = b("showBolusReasoning") { showBolusReasoning = v }
        if let v = s("watchDefaultBolusMode"), let mode = BolusMode(rawValue: v) { watchDefaultBolusMode = mode }
        if let v = dbl("watchBolusIncrement") { watchBolusIncrement = v }
        if let v = dbl("watchCarbIncrement") { watchCarbIncrement = v }
        if let v = b("showGlucoseAxis") { showGlucoseAxis = v }
        if let v = b("showIOBAxis") { showIOBAxis = v }
        if let v = b("showBolusBars") { showBolusBars = v }
        if let v = b("showStats") { showStats = v }
        if let v = sa("detailsOrder") { detailsOrder = v }
        if let v = sa("watchDetailsOrder") { watchDetailsOrder = v }
        if let v = sa("pillsOrder") { pillsOrder = v }
        if let v = ia("watchChartRanges") { watchChartRanges = v }
        if let v = i("glucoseStaleMinutes") { glucoseStaleMinutes = v }
        if let v = i("glucoseHideDelayMinutes") { glucoseHideDelayMinutes = v }
        if let v = b("advancedControlEnabled") { advancedControlEnabled = v }
        if let v = b("autoExerciseMode") { autoExerciseMode = v }
        if let v = b("autoSleepMode") { autoSleepMode = v }
        if let v = b("modeReminders") { modeReminders = v }
        if let v = b("autoSyncPumpTime") { autoSyncPumpTime = v }
        if let v = b("phoneReadOnly") { phoneReadOnly = v }
        if let v = b("readOnlyAllowAlertClear") { readOnlyAllowAlertClear = v }
        if let v = b("remotesReadOnly") { remotesReadOnly = v }
        if let v = b("remoteBluetoothEnabled") { remoteBluetoothEnabled = v }
        if let v = b("requireRemoteBolusApproval") { requireRemoteBolusApproval = v }
        if let v = sa("garminScreenOrder") { garminScreenOrder = v }
        if let v = s("garminDefaultScreen") { garminDefaultScreen = v }
        if let v = s("garminComplicationDisplay") { garminComplicationDisplay = v }
        if let v = s("garminTargetApp") { garminTargetApp = v }
        if let v = b("nightscoutUploadEnabled") { nightscoutUploadEnabled = v }
        if let v = b("childModeEnabled") { childModeEnabled = v }
        if let data = dat("alertRules"), let rules = try? JSONDecoder().decode([AlertRule].self, from: data) { alertRules = rules }
        if let data = dat("childAllowed"), let set = try? JSONDecoder().decode(Set<ChildFeature>.self, from: data) { childAllowed = set }
        applyFreshness(); syncWidgetConfig()
    }
}
