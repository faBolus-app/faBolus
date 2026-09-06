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

    // `syncWidgetConfig()` is preserved via the `onChange` hook wired at the end of `init`
    // (NOT inline in this setter) so it does not fire during construction — see Stored.swift
    // for why AppSettings uses composition rather than a `@Stored` attribute.
    private var _defaultBolusMode = Stored<BolusMode>(wrappedValue: .carbs, "defaultBolusMode")
    public var defaultBolusMode: BolusMode {
        get { _defaultBolusMode.wrappedValue }
        set {
            _defaultBolusMode.wrappedValue = newValue
            _defaultBolusMode.onChange?(newValue)  // two statements — see Stored.swift's onChange doc comment (exclusivity)
        }
    }
    // Watch / Garmin default entry mode (sent to the remotes) — independent of the phone.
    // The legacy phone-default fallback lives in `init`.
    private var _watchDefaultBolusMode = Stored<BolusMode>(wrappedValue: .carbs, "watchDefaultBolusMode")
    public var watchDefaultBolusMode: BolusMode {
        get { _watchDefaultBolusMode.wrappedValue }
        set { _watchDefaultBolusMode.wrappedValue = newValue }
    }
    // Phone increments (iPhone bolus entry + the Home-Screen widget).
    // `syncWidgetConfig()` preserved via the post-init `onChange` hook. The init `max(0.05, …)`
    // legacy clamp is still computed in `init`.
    private var _bolusIncrement = Stored<Double>(wrappedValue: 0.05, "bolusIncrement")
    public var bolusIncrement: Double {
        get { _bolusIncrement.wrappedValue }
        set {
            _bolusIncrement.wrappedValue = newValue
            _bolusIncrement.onChange?(newValue)  // two statements — see Stored.swift's onChange doc comment (exclusivity)
        }
    }
    // `syncWidgetConfig()` preserved via the post-init `onChange` hook.
    private var _carbIncrement = Stored<Double>(wrappedValue: 5, "carbIncrement")
    public var carbIncrement: Double {
        get { _carbIncrement.wrappedValue }
        set {
            _carbIncrement.wrappedValue = newValue
            _carbIncrement.onChange?(newValue)  // two statements — see Stored.swift's onChange doc comment (exclusivity)
        }
    }
    // Watch / Garmin increments (sent to the remotes in the status payload) — independent of the phone.
    // The phone-increment fallbacks live in `init`.
    private var _watchBolusIncrement = Stored<Double>(wrappedValue: 0.05, "watchBolusIncrement")
    public var watchBolusIncrement: Double {
        get { _watchBolusIncrement.wrappedValue }
        set { _watchBolusIncrement.wrappedValue = newValue }
    }
    private var _watchCarbIncrement = Stored<Double>(wrappedValue: 5, "watchCarbIncrement")
    public var watchCarbIncrement: Double {
        get { _watchCarbIncrement.wrappedValue }
        set { _watchCarbIncrement.wrappedValue = newValue }
    }
    /// Chart series toggles. Glucose (left axis), the IOB line, and the bolus bars each toggle
    /// independently; IOB + bolus bars share the right (units) axis.
    private var _showGlucoseAxis = Stored<Bool>(wrappedValue: true, "showGlucoseAxis")
    public var showGlucoseAxis: Bool {
        get { _showGlucoseAxis.wrappedValue }
        set { _showGlucoseAxis.wrappedValue = newValue }
    }
    /// Glucose display-unit preference. mg/dL `Int` stays canonical internally; this only selects
    /// which unit surfaces render/parse (`GlucoseUnit.format`/`.parse`). Default **mg/dL**.
    public var glucoseDisplayUnit: GlucoseUnit {
        didSet {
            d.set(glucoseDisplayUnit.rawValue, forKey: "glucoseDisplayUnit")
            // Re-publish the App-Group WidgetSnapshot displayUnit immediately so widgets reflect a
            // unit toggle without waiting for the next pump reading. Not syncWidgetConfig() (that
            // channel is for bolus increments).
            WidgetPublisher.republishDisplayUnit()
        }
    }
    /// Whether the persistent/ambient mg/dL·mmol/L unit CAPTION is shown on display-only readouts
    /// (status ring, HUD ISF/target, stats card, chart axis, history, widgets, complication, and the
    /// Live Activity). **Default OFF** — the number alone is shown on those ambient
    /// surfaces, keeping them visually quieter for a user who already knows their unit. This NEVER
    /// hides units from dose-confirmation dialogs (`BolusEntryView`), VoiceOver/accessibility strings,
    /// config/setup screens (`AlertRulesView`/`PumpWizardViews`/`CgmCredentialsView`), or the Settings
    /// unit picker itself — those are safety/clarity/setup contexts, not ambient display, and always
    /// keep the unit regardless of this flag. A display-format preference like `glucoseDisplayUnit`
    /// (NOT a per-device feature toggle), so it iCloud-syncs the same way — see `SettingsCatalog`.
    private var _showGlucoseUnitLabels = Stored<Bool>(wrappedValue: false, "showGlucoseUnitLabels")
    public var showGlucoseUnitLabels: Bool {
        get { _showGlucoseUnitLabels.wrappedValue }
        set {
            _showGlucoseUnitLabels.wrappedValue = newValue
            _showGlucoseUnitLabels.onChange?(newValue)  // two statements — see Stored.swift's onChange doc comment (exclusivity)
        }
    }
    // See Stored.swift for why AppSettings uses the private-field + computed-property COMPOSITION
    // form rather than the `@Stored("key") var` attribute directly.
    private var _showIOBAxis = Stored<Bool>(wrappedValue: true, "showIOBAxis")
    public var showIOBAxis: Bool {
        get { _showIOBAxis.wrappedValue }
        set { _showIOBAxis.wrappedValue = newValue }
    }
    private var _showBolusBars = Stored<Bool>(wrappedValue: true, "showBolusBars")
    public var showBolusBars: Bool {
        get { _showBolusBars.wrappedValue }
        set { _showBolusBars.wrappedValue = newValue }
    }

    /// Glucose plot Y-axis **ceiling**, canonical mg/dL. Discrete preset. The resolved-at-init pair
    /// always satisfies `floor < ceiling` via `GlucosePlotScale.resolve`.
    // `init` still routes every assignment through `GlucosePlotScale.resolve` before calling
    // this setter — Stored only replaces the raw `d.set(...)` plumbing, never the validation.
    private var _glucosePlotCeiling = Stored<Int>(wrappedValue: 300, "glucosePlotCeiling")
    public var glucosePlotCeiling: Int {
        get { _glucosePlotCeiling.wrappedValue }
        set { _glucosePlotCeiling.wrappedValue = newValue }
    }
    /// Glucose plot Y-axis **floor**, canonical mg/dL. Discrete preset. Capped at 50 by
    /// `GlucosePlotScale.floorOptions` so the `veryLow` (54) reference line always stays on-chart.
    // Validation is unchanged — see `glucosePlotCeiling` note above.
    private var _glucosePlotFloor = Stored<Int>(wrappedValue: 40, "glucosePlotFloor")
    public var glucosePlotFloor: Int {
        get { _glucosePlotFloor.wrappedValue }
        set { _glucosePlotFloor.wrappedValue = newValue }
    }
    /// Re-exposed option sets for the Settings UI — pinned to `GlucosePlotScale` so no second
    /// literal preset list ever exists.
    public static let glucosePlotFloorOptions: [Int] = GlucosePlotScale.floorOptions
    public static let glucosePlotCeilingOptions: [Int] = GlucosePlotScale.ceilingOptions

    /// Optional Watch/Garmin plot Y-axis **override**. Treated as one unit — the UI clears/sets both
    /// together; `nil` means "Same as phone" for both bounds, not per-bound.
    /// set, always snapped in-set via `GlucosePlotScale.resolve` (never assigned raw). `.remotes`,
    /// `backsUp: true` (same category as `watchChartRanges`), canonical mg/dL. Never iCloud-relevant
    /// beyond the normal `.remotes` default (this is a display preference, not command-adjacent).
    public var glucosePlotCeilingSmall: Int? {
        didSet {
            if let v = glucosePlotCeilingSmall {
                d.set(v, forKey: "glucosePlotCeilingSmall")
            } else {
                d.removeObject(forKey: "glucosePlotCeilingSmall")
            }
        }
    }
    /// See `glucosePlotCeilingSmall` — the paired floor half of the same override unit.
    public var glucosePlotFloorSmall: Int? {
        didSet {
            if let v = glucosePlotFloorSmall {
                d.set(v, forKey: "glucosePlotFloorSmall")
            } else {
                d.removeObject(forKey: "glucosePlotFloorSmall")
            }
        }
    }

    /// Show the opt-in **Statistics** card on the dashboard (Time-in-Range, GMI, mean, CV over the
    /// in-memory ~24 h history). **Default OFF** so regular use stays clean. See [[GlucoseStatistics]].
    private var _showStats = Stored<Bool>(wrappedValue: false, "showStats")
    public var showStats: Bool {
        get { _showStats.wrappedValue }
        set { _showStats.wrappedValue = newValue }
    }

    /// Persistent-history retention in days; **0 = keep everything** (default). Storage is ~1 MB/month,
    /// so the default is unlimited; this only exists for users who prefer data-minimization.
    // Force-set-1 (24h) pin lives in `init` as an explicit assignment through this setter.
    private var _historyRetentionDays = Stored<Int>(wrappedValue: 1, "historyRetentionDays")
    public var historyRetentionDays: Int {
        get { _historyRetentionDays.wrappedValue }
        set { _historyRetentionDays.wrappedValue = newValue }
    }

    /// Auto-sync pump history on connect. **Default ON** — the gap-aware sync (`TandemBackend`)
    /// runs automatically on every connect unless disabled here. Turning this OFF only suppresses
    /// the AUTOMATIC on-connect check; the "Sync now" manual trigger in `DataHistoryView` always
    /// runs the same gap-sync entry point regardless. Reachable in Data & History; a
    /// `SettingsCatalog` row, `backsUp: false` like `historyRetentionDays` (device-local sync
    /// preference, not backup/iCloud-relevant).
    private var _historySyncEnabled = Stored<Bool>(wrappedValue: true, "historySyncEnabled")
    public var historySyncEnabled: Bool {
        get { _historySyncEnabled.wrappedValue }
        set { _historySyncEnabled.wrappedValue = newValue }
    }

    /// Last time a pump-history gap-sync completed — feeds the "Last synced" row in
    /// `DataHistoryView`. Durable per-install marker, NOT a `SettingsCatalog` row (pure sync
    /// bookkeeping, mirrors `historyCoverage`'s own precedent) and never included in a settings backup.
    /// `nil` ⇒ never synced ("Never" / "Not synced yet").
    public var historyLastSyncedAt: Date? {
        didSet { d.set(historyLastSyncedAt?.timeIntervalSince1970 ?? 0, forKey: "historyLastSyncedAt") }
    }

    /// Persisted pump history-log sequence coverage — replaces the one-shot `didBackfill` gate.
    /// `TandemBackend` reads this on every connect to compute exactly which sequence windows are
    /// still missing, and writes back into it as gap-sync windows complete.
    /// Derived/rebuildable local sync bookkeeping, not a user preference — deliberately NOT a
    /// `SettingsCatalog` row (no UI surface at all; see the NOTE in `SettingsCatalog.swift`) and never
    /// included in a settings backup.
    public var historyCoverage: HistoryCoverageMap {
        didSet { if let data = try? JSONEncoder().encode(historyCoverage) { d.set(data, forKey: "historyCoverage") } }
    }

    /// The five orphaned `UserDefaults` keys the retired eating/Nudge surface left behind — no property
    /// on this type or any other reads them any more. Purged once at launch in `init`, guarded by
    /// `eatingResiduePurgeV1`. `internal` (not `private`) so `AppSettingsMigrationTests`/
    /// `AppSettingsStoredMigrationTests`-style suites can assert the purge without hardcoding the list twice.
    internal static let retiredEatingResidueKeys: [String] = [
        "eatingMealPlaces", "alertIntel", "eatingTriggerConfig", "eatingNudgesEnabled", "eatingLearnFromFeedback"
    ]

    /// Minutes after which a CGM reading is **stale**: shown de-emphasized and no longer used to
    /// auto-fill a bolus correction. A stale reading is never used regardless of whether it's still
    /// shown (greyed) or hidden. Also propagated to the remotes.
    // `applyFreshness()` preserved via the post-init `onChange` hook (the explicit unconditional
    // `applyFreshness()` call at the end of `init` is unchanged — it still pushes the launch-time
    // thresholds regardless of this hook).
    private var _glucoseStaleMinutes = Stored<Int>(wrappedValue: 6, "glucoseStaleMinutes")
    public var glucoseStaleMinutes: Int {
        get { _glucoseStaleMinutes.wrappedValue }
        set {
            _glucoseStaleMinutes.wrappedValue = newValue
            _glucoseStaleMinutes.onChange?(newValue)  // two statements — see Stored.swift's onChange doc comment (exclusivity)
        }
    }
    /// Minutes **after it goes stale** to keep showing the greyed value before hiding it ("--").
    /// `0` = hide immediately when stale (no greyed stage); `nil` = never hide (always show greyed).
    public var glucoseHideDelayMinutes: Int? {
        didSet {
            if let v = glucoseHideDelayMinutes {
                d.set(v, forKey: "glucoseHideDelayMinutes")
            } else {
                d.removeObject(forKey: "glucoseHideDelayMinutes")
            }
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


    /// **Read-only mode (this phone).** Turns the app into a safe viewer: bolusing and all pump control
    /// are disabled and their UI (Bolus tab, Pump Control) is hidden. **Default OFF.** Clearing pump
    /// alerts is also disabled by default while read-only, unless `readOnlyAllowAlertClear` is on.
    private var _phoneReadOnly = Stored<Bool>(wrappedValue: false, "phoneReadOnly")
    public var phoneReadOnly: Bool {
        get { _phoneReadOnly.wrappedValue }
        set { _phoneReadOnly.wrappedValue = newValue }
    }
    /// Sub-option of read-only mode: still allow clearing/snoozing pump alerts. **Default OFF.**
    private var _readOnlyAllowAlertClear = Stored<Bool>(wrappedValue: false, "readOnlyAllowAlertClear")
    public var readOnlyAllowAlertClear: Bool {
        get { _readOnlyAllowAlertClear.wrappedValue }
        set { _readOnlyAllowAlertClear.wrappedValue = newValue }
    }
    /// **Read-only mode for the Apple Watch + Garmin remotes.** They hide their bolus screen/button and
    /// can't deliver (the host refuses too); viewing stays. Independent of the phone flag. **Default OFF.**
    private var _remotesReadOnly = Stored<Bool>(wrappedValue: false, "remotesReadOnly")
    public var remotesReadOnly: Bool {
        get { _remotesReadOnly.wrappedValue }
        set { _remotesReadOnly.wrappedValue = newValue }
    }

    /// **Garmin bolusing allowed.** Explicit per-surface enable for delivering a bolus *from the
    /// Garmin watch*, **default OFF** so bolusing is off until the user opts in with the one-time warning.
    /// Independent of — and ANDed with — `remotesReadOnly` (read-only still wins). This replaces the old
    /// posture where the only control was the inverted `remotesReadOnly` and Garmin bolusing shipped ON.
    /// Command-adjacent: backed up (a restore is an explicit user action) but **never** iCloud-synced —
    /// an auto-synced value must not silently arm bolusing on another device.
    private var _garminBolusEnabled = Stored<Bool>(wrappedValue: false, "garminBolusEnabled")
    public var garminBolusEnabled: Bool {
        get { _garminBolusEnabled.wrappedValue }
        set { _garminBolusEnabled.wrappedValue = newValue }
    }
    /// **Optional remote-only per-bolus ceiling.** When set (a positive units value), a bolus started
    /// from a REMOTE surface (Apple Watch / Garmin) is capped at this many units *in addition to* the pump's
    /// own max bolus. `nil` = **off (default)** — the pump's max alone governs. The iPhone's own bolus never
    /// consults this (it is applied only at the remote `BolusGate` `maximum` seam — see
    /// `AppModel.remoteBolusMaximum`). Command-adjacent: backed up (a restore is an explicit user action) but
    /// **never** iCloud-synced — an auto-synced value must not silently relax the cap on another device.
    public var remoteBolusCeiling: Double? {
        didSet {
            if let v = remoteBolusCeiling, v > 0 {
                d.set(v, forKey: "remoteBolusCeiling")
            } else {
                d.removeObject(forKey: "remoteBolusCeiling")
            }
        }
    }
    /// The selectable remote-ceiling caps (units), and the value first applied when the user turns the limit
    /// on. Every option is well under the pump/backend hard max (25 U), so the ceiling can only ever lower it.
    public static let remoteBolusCeilingOptions: [Double] = [1, 2, 3, 5, 8, 10, 15, 20]
    public static let defaultRemoteBolusCeiling: Double = 5

    /// **RESIDUAL — no consumer.** Was the opt-in for the pump clock-sync write path
    /// (`GatedPumpWrite.syncTimeToNow`); that action, its capability, and the three backend
    /// implementations are retired, so this stored preference has no reader left. Its own removal is a
    /// separate, deliberate decision rather than an automatic follow-on of the write-path retirement —
    /// the decl and its `store` wire are left untouched here.
    private var _autoSyncPumpTime = Stored<Bool>(wrappedValue: false, "autoSyncPumpTime")
    public var autoSyncPumpTime: Bool {
        get { _autoSyncPumpTime.wrappedValue }
        set { _autoSyncPumpTime.wrappedValue = newValue }
    }

    /// **Auto Exercise mode** — switches the pump into Control-IQ Exercise mode when a workout starts,
    /// and back to normal when it ends. **Default OFF.** Auto-switching applies only to a **Mobi**
    /// (t:slim X2 cannot). Hidden and unregistered.
    private var _autoExerciseMode = Stored<Bool>(wrappedValue: false, "autoExerciseMode")
    public var autoExerciseMode: Bool {
        get { _autoExerciseMode.wrappedValue }
        set { _autoExerciseMode.wrappedValue = newValue }
    }
    /// **Auto Sleep mode** — switches the pump into Sleep mode when the iPhone enters Sleep Focus, and
    /// back when it ends. **Default OFF.** Mobi-only auto-switch. Hidden and unregistered.
    private var _autoSleepMode = Stored<Bool>(wrappedValue: false, "autoSleepMode")
    public var autoSleepMode: Bool {
        get { _autoSleepMode.wrappedValue }
        set { _autoSleepMode.wrappedValue = newValue }
    }

    /// Use iOS **Critical Alerts** (which alert even under Do Not Disturb / the ringer switch)
    /// for the never-suppressible safety notifications — WHEN the app holds the critical-alerts entitlement;
    /// it degrades gracefully to a normal notification when the entitlement isn't granted.
    /// **Default explicit OFF for t:slim**, DECOUPLED from `PumpModelStore.isMobi()` (the
    /// old default was "ON for a Mobi" — Simulated Mobi and all Mobi backends are gone, so
    /// that coupling is now to a permanently-stale flag). The user can still turn it on explicitly — the
    /// capability path (`NotificationCoordinator` read, `NotificationSettingsView` toggle)
    /// is KEPT. Local device pref: not backed up / iCloud-synced.
    private var _criticalAlertsEnabled = Stored<Bool>(wrappedValue: false, "criticalAlertsEnabled")
    public var criticalAlertsEnabled: Bool {
        get { _criticalAlertsEnabled.wrappedValue }
        set { _criticalAlertsEnabled.wrappedValue = newValue }
    }
    /// Opt-in (default OFF) for local notification telemetry — per-category delivered/dismissed/
    /// acted-upon counts the broker uses to tune defaults. Stored in the **App Group** (not `d`) so the
    /// broker, incl. the out-of-process mode-reminder intent, reads the same choice. Local-only, never
    /// uploaded. No settings toggle is wired yet; this is the opt-in the broker gates accrual on.
    public var notificationTelemetryEnabled: Bool {
        get {
            UserDefaults(suiteName: WidgetStore.appGroup)?.bool(forKey: NotificationRuntime.telemetryEnabledKey)
                ?? false
        }
        set {
            UserDefaults(suiteName: WidgetStore.appGroup)?.set(
                newValue, forKey: NotificationRuntime.telemetryEnabledKey)
        }
    }

    /// Show the collapsible "reasoning" breakdown (IOB, carb+correction, max-safe hint) under the
    /// recommendation. Default ON but collapsed; turn off to remove it entirely.
    private var _showBolusReasoning = Stored<Bool>(wrappedValue: true, "showBolusReasoning")
    public var showBolusReasoning: Bool {
        get { _showBolusReasoning.wrappedValue }
        set { _showBolusReasoning.wrappedValue = newValue }
    }

    /// Child (locked) mode: a PIN-protected mode a parent enables on a child's device. When on, only
    /// the features in `childAllowed` are permitted; everything that dispenses insulin is blocked by
    /// default. The PIN hash lived in the Keychain (`ChildModeStore`, now removed along with
    /// `ChildModeView.swift`, its only caller).
    ///
    /// FROZEN to `false` — belt-and-suspenders runtime gate. No setter can make this `true` again
    /// (including restore-from-backup). Forcing this input false = full adult access. See
    /// `ChildModeFreezeGuardTests`.
    public var childModeEnabled: Bool {
        get { false }
        // The empty setter IS the freeze: swallowing the write is what makes this
        // unreachable by any means, including restore-from-backup.
        set {}  // swiftlint:disable:this unused_setter_value
    }
    public var childAllowed: Set<ChildFeature> {
        didSet { d.set(Self.canonicalChildAllowedData(childAllowed), forKey: "childAllowed") }
    }
    /// Encode `childAllowed` deterministically. `Set` serializes to a JSON array in hash-iteration order,
    /// which Swift randomizes per process — so the *same* set of features encodes to different bytes across
    /// launches and devices, producing spurious iCloud sync diffs. Sorting by `rawValue` first makes the
    /// encoding canonical and seed-independent; decoding `Set<ChildFeature>` from the array is unaffected,
    /// so old blobs still load and no migration is needed. This is the only `Set`-backed persisted value.
    nonisolated static func canonicalChildAllowedData(_ set: Set<ChildFeature>) -> Data {
        (try? JSONEncoder().encode(set.sorted { $0.rawValue < $1.rawValue })) ?? Data()
    }
    /// Whether `feature` is currently permitted (always true when child mode is off).
    public func childAllows(_ feature: ChildFeature) -> Bool {
        !childModeEnabled || childAllowed.contains(feature)
    }

    /// Garmin remote layout: the swipe order of its screens and which one opens first. Pushed to
    /// the watch in the status payload; the Garmin app persists it locally so it survives restarts.
    public var garminScreenOrder: [String] { didSet { d.set(garminScreenOrder, forKey: "garminScreenOrder") } }
    // `init`'s screen-order validation computes the value then assigns it through this setter.
    private var _garminDefaultScreen = Stored<String>(wrappedValue: "glance", "garminDefaultScreen")
    public var garminDefaultScreen: String {
        get { _garminDefaultScreen.wrappedValue }
        set { _garminDefaultScreen.wrappedValue = newValue }
    }
    /// How the Garmin BG complication presents: "numericColor" (numeric value with range-coloring +
    /// a Latin trend in the unit slot) or "stringTrend" (a plain "124 ^" string, no color). Mirrored.
    // `init`'s option-set validation computes the value then assigns it through this setter.
    private var _garminComplicationDisplay = Stored<String>(wrappedValue: "numericColor", "garminComplicationDisplay")
    public var garminComplicationDisplay: String {
        get { _garminComplicationDisplay.wrappedValue }
        set { _garminComplicationDisplay.wrappedValue = newValue }
    }
    /// Whether the Garmin clock screen draws an analog face (true) or the digital readout (false, default).
    /// Pushed to the remote in the status payload, replacing the old on-watch tap toggle. Mirrored.
    private var _garminClockAnalog = Stored<Bool>(wrappedValue: false, "garminClockAnalog")
    public var garminClockAnalog: Bool {
        get { _garminClockAnalog.wrappedValue }
        set { _garminClockAnalog.wrappedValue = newValue }
    }
    /// Which Garmin store app the phone pairs with: "beta" (id a1b2c3d4…) or "official" (id ded131…).
    /// Developer setting; applied when the Garmin remote (re)registers — reopen the app after changing.
    // `init`'s official/beta validation computes the value then assigns it through this setter.
    private var _garminTargetApp = Stored<String>(wrappedValue: "beta", "garminTargetApp")
    public var garminTargetApp: String {
        get { _garminTargetApp.wrappedValue }
        set { _garminTargetApp.wrappedValue = newValue }
    }
    public static let complicationDisplayOptions = ["numericColor", "stringTrend"]
    public static func complicationDisplayLabel(_ id: String) -> String {
        id == "stringTrend" ? "Value + trend (no color)" : "Value + color + trend"
    }

    // MARK: Garmin complication slots

    /// Which pump-status fields (ordered, ≤3) fill the Garmin's three user-assignable complication slots,
    /// mirrored to the watch. Connect IQ caps an app at 4 complications, so glucose (fixed) + these ≤3.
    /// DEFAULT iob/reservoir/battery. `.display`/`backsUp: true` — display only, never a dose input.
    public var garminComplicationSlots: [String] {
        didSet { d.set(garminComplicationSlots, forKey: "garminComplicationSlots") }
    }
    public static let garminComplicationFields = ["iob", "reservoir", "battery", "basal"]
    public static let garminComplicationSlotsDefault = ["iob", "reservoir", "battery"]
    public static func garminComplicationFieldLabel(_ id: String) -> String {
        switch id {
        case "iob": return "Active insulin (IOB)"
        case "reservoir": return "Reservoir units"
        case "battery": return "Pump battery %"
        case "basal": return "Basal rate"
        default: return id
        }
    }
    /// Sanitize a stored/incoming slot list: allowed tokens only, de-duped, order preserved, capped at the
    /// three available slots; an empty/all-invalid list falls back to the default set.
    static func sanitizeComplicationSlots(_ stored: [String]?) -> [String] {
        guard let stored else { return garminComplicationSlotsDefault }
        var out: [String] = []
        for s in stored where garminComplicationFields.contains(s) && !out.contains(s) { out.append(s) }
        if out.isEmpty { return garminComplicationSlotsDefault }
        return Array(out.prefix(3))
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
        [
            "iob", "reservoir", "battery", "cgm", "basal", "controlIQ", "lastBolus", "carbRatio", "isf", "target",
            "maxBolus"
        ]
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
        guard let stored = stored else { return all }
        var order: [String] = []
        for s in stored where all.contains(s) && !order.contains(s) { order.append(s) }
        if order.isEmpty { return all }
        return order
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
    public static let garminScreens: [String] = [
        "glance", "glucose", "clock", "bolusonly", "alerts", "history", "details"
    ]
    public static func garminScreenLabel(_ id: String) -> String {
        switch id {
        case "glance": return "Glance (glucose + bolus)"
        case "glucose": return "Glucose only (no bolus button)"
        case "clock": return "Clock + glucose (analog/digital, no bolus)"
        case "bolusonly": return "Bolus button only"
        case "alerts": return "Alerts"
        case "history": return "History plot"
        case "details": return "Details"
        default: return id
        }
    }

    /// The persisted pump-mirror notification-rules overrides (Amendment A of the 2026-09-02
    /// notification redesign): a NEW blob key, entirely independent of the legacy
    /// `notificationBroker.settings.v1` / `CategorySettings` blob — this property has no code path
    /// that reads or translates it, so there is no migration. A decode failure (corrupt/partial
    /// data) falls back to `.init()` (no overrides), which resolves every pump-mirror group through
    /// its fatigue-averse default (`NotificationRules.defaultIntent(for:)`) — never a silent safety
    /// `Off`. Assigned in `init` (see `notificationRulesKey`); `didSet` persists the whole blob.
    public var notificationRules: NotificationRules.PersistedRules {
        didSet {
            if let data = try? JSONEncoder().encode(notificationRules) {
                d.set(data, forKey: Self.notificationRulesKey)
            }
        }
    }
    private static let notificationRulesKey = "notificationRules.v1"

    /// The backing store. `.standard` in the app (via `.shared`); a fresh throwaway suite in tests so
    /// first-launch defaults can be asserted without touching the real user defaults.
    private let d: UserDefaults

    // One-time clinician-tier acknowledgment. Persisted (durable), but NOT a catalog row — never
    // backed up, never iCloud-synced: a per-install first-use disclosure of clinical ownership.
    // It NEVER gates a write (not a `DenialReason`); it only records that the disclosure was shown
    // and accepted. nil ⇒ never acknowledged.
    public var clinicianTierAckAt: Date? {
        didSet { d.set(clinicianTierAckAt?.timeIntervalSince1970 ?? 0, forKey: "clinicianTierAckAt") }
    }
    public var hasAcknowledgedClinicianTier: Bool { clinicianTierAckAt != nil }
    /// Record the one-time acknowledgment (idempotent — keeps the first timestamp).
    public func acknowledgeClinicianTier() { if clinicianTierAckAt == nil { clinicianTierAckAt = Date() } }

    // One-time "you're turning on real insulin delivery from this remote" acknowledgment,
    // shown the FIRST time each surface's enable is switched on. Same idiom as `clinicianTierAckAt`:
    // durable per-install markers, NOT catalog rows — never backed up, never iCloud-synced (a synced ack
    // must not silently pre-suppress the warning on another device). nil ⇒ never acknowledged.
    public var garminBolusWarningAckAt: Date? {
        didSet { d.set(garminBolusWarningAckAt?.timeIntervalSince1970 ?? 0, forKey: "garminBolusWarningAckAt") }
    }
    public var hasAcknowledgedGarminBolusWarning: Bool { garminBolusWarningAckAt != nil }
    public func acknowledgeGarminBolusWarning() {
        if garminBolusWarningAckAt == nil { garminBolusWarningAckAt = Date() }
    }

    /// `.shared` uses `.standard`; tests inject a fresh empty suite. Not
    /// `private` so `@testable` tests can construct an instance over an injected store — the app
    /// still funnels everything through `.shared`.
    init(defaults: UserDefaults = .standard) {
        self.d = defaults
        // Fresh defaults, decode-tolerant, no migration (Amendment A): a missing key or a
        // corrupt/malformed blob both fall back to `.init()` (no overrides) rather than reading —
        // let alone translating — the legacy `notificationBroker.settings.v1` blob.
        if let data = d.data(forKey: Self.notificationRulesKey),
            let decoded = try? JSONDecoder().decode(NotificationRules.PersistedRules.self, from: data)
        {
            notificationRules = decoded
        } else {
            notificationRules = .init()
        }
        // Raw increment reads consumed by the relocated `@Stored` assignment block at the end of `init`
        // (`watchDefaultBolusMode`/`bolusIncrement`/`watchBolusIncrement`/`watchCarbIncrement`
        // assignments live there per Swift's two-phase-init rule). The `max(0.05, …)` clamps and
        // watch→phone-default fallbacks stay; only their source position moved.
        let bi = d.object(forKey: "bolusIncrement") as? Double
        let ci = d.object(forKey: "carbIncrement") as? Double
        // Force-set `.mgdl` — a restored/legacy "mmol" must not change the display unit. The dose
        // path is mg/dL-canonical regardless (`BolusMath`).
        glucoseDisplayUnit = .mgdl
        // An absent/out-of-set stored bound snaps to a safe in-set pair via the shared math — never assigned raw.
        let plotBounds = GlucosePlotScale.resolve(
            storedFloor: d.object(forKey: "glucosePlotFloor") as? Int,
            storedCeiling: d.object(forKey: "glucosePlotCeiling") as? Int)
        // The pair is one unit — only treat as "on" when both halves are on disk; a partial state
        // falls back to nil ("Same as phone"). A present pair still snaps through the shared math.
        if let sf = d.object(forKey: "glucosePlotFloorSmall") as? Int,
            let sc = d.object(forKey: "glucosePlotCeilingSmall") as? Int
        {
            let smallBounds = GlucosePlotScale.resolve(storedFloor: sf, storedCeiling: sc)
            glucosePlotFloorSmall = smallBounds.floor
            glucosePlotCeilingSmall = smallBounds.ceiling
        } else {
            glucosePlotFloorSmall = nil
            glucosePlotCeilingSmall = nil
        }
        let hsAck = d.double(forKey: "historyLastSyncedAt")  // 0 (absent) ⇒ never synced
        historyLastSyncedAt = hsAck > 0 ? Date(timeIntervalSince1970: hsAck) : nil
        if let data = d.data(forKey: "historyCoverage"),
            let coverage = try? JSONDecoder().decode(HistoryCoverageMap.self, from: data)
        {
            historyCoverage = coverage
        } else {
            historyCoverage = HistoryCoverageMap()
        }
        glucoseHideDelayMinutes = d.object(forKey: "glucoseHideDelayMinutes") as? Int  // nil = Never
        let ackTs = d.double(forKey: "clinicianTierAckAt")  // 0 (absent) ⇒ never acknowledged
        clinicianTierAckAt = ackTs > 0 ? Date(timeIntervalSince1970: ackTs) : nil
        let gAck = d.double(forKey: "garminBolusWarningAckAt")
        garminBolusWarningAckAt = gAck > 0 ? Date(timeIntervalSince1970: gAck) : nil
        // nil (absent, or a stored non-positive) ⇒ the ceiling is OFF; only a positive value arms it.
        let rbc = d.object(forKey: "remoteBolusCeiling") as? Double
        remoteBolusCeiling = (rbc.map { $0.isFinite && $0 > 0 } ?? false) ? rbc : nil
        childAllowed =
            d.data(forKey: "childAllowed").flatMap { try? JSONDecoder().decode(Set<ChildFeature>.self, from: $0) }
            ?? ChildFeature.defaultAllowed
        // Restore the Garmin screen selection + order (the enabled subset, in swipe order),
        // dropping unknown/duplicate ids. Hidden screens stay hidden. Fall back to all screens
        // only if nothing valid is stored, so the watch is never left with no screens.
        let stored = (d.array(forKey: "garminScreenOrder") as? [String]) ?? Self.garminScreens
        var order: [String] = []
        for s in stored where Self.garminScreens.contains(s) && !order.contains(s) { order.append(s) }
        if order.isEmpty { order = Self.garminScreens }
        garminScreenOrder = order
        let def = d.string(forKey: "garminDefaultScreen") ?? "glance"
        let cd = d.string(forKey: "garminComplicationDisplay") ?? "numericColor"
        let gt = d.string(forKey: "garminTargetApp") ?? "beta"  // default to beta (official listing is dormant)
        detailsOrder = Self.restoreOrder(d.array(forKey: "detailsOrder") as? [String], all: Self.detailFields)
        watchDetailsOrder = Self.restoreOrder(d.array(forKey: "watchDetailsOrder") as? [String], all: Self.detailFields)
        garminComplicationSlots = Self.sanitizeComplicationSlots(
            d.array(forKey: "garminComplicationSlots") as? [String])
        // Default to the original 6 pills (the full option set is larger); honor a saved selection.
        pillsOrder = Self.restoreOrder(
            d.array(forKey: "pillsOrder") as? [String] ?? Self.defaultPills, all: Self.pillItems)
        let storedRanges = (d.array(forKey: "watchChartRanges") as? [Int])?
            .filter { Self.chartRangeOptions.contains($0) }
        watchChartRanges = (storedRanges?.isEmpty ?? true) ? Self.chartRangeOptions : storedRanges!.sorted()

        // Repoint every `@Stored` private field at the SAME injected `defaults` this instance uses
        // (`.standard` in the app; a throwaway suite in tests), THEN assign each property's final
        // value. Both steps are deferred to here because Swift's two-phase class-init rule: mutating
        // a SUBSTRUCTURE (`_x.store = defaults`) or calling a computed setter (`x = value`) counts
        // as "using self" and is illegal until every other stored property already has a value.
        // Locals these assignments depend on (`ci`, `plotBounds`, `cd`) were computed earlier.
        _defaultBolusMode.store = defaults
        _carbIncrement.store = defaults
        _showGlucoseAxis.store = defaults
        _showIOBAxis.store = defaults
        _showBolusBars.store = defaults
        _glucosePlotCeiling.store = defaults
        _glucosePlotFloor.store = defaults
        _showStats.store = defaults
        _glucoseStaleMinutes.store = defaults
        _phoneReadOnly.store = defaults
        _readOnlyAllowAlertClear.store = defaults
        _remotesReadOnly.store = defaults
        _garminBolusEnabled.store = defaults
        _autoSyncPumpTime.store = defaults
        _showBolusReasoning.store = defaults
        _garminComplicationDisplay.store = defaults
        _garminClockAnalog.store = defaults
        _watchDefaultBolusMode.store = defaults
        _bolusIncrement.store = defaults
        _watchBolusIncrement.store = defaults
        _watchCarbIncrement.store = defaults
        _showGlucoseUnitLabels.store = defaults
        _historyRetentionDays.store = defaults
        _historySyncEnabled.store = defaults
        _criticalAlertsEnabled.store = defaults
        _autoExerciseMode.store = defaults
        _autoSleepMode.store = defaults
        _garminDefaultScreen.store = defaults
        _garminTargetApp.store = defaults
        defaultBolusMode = BolusMode(rawValue: d.string(forKey: "defaultBolusMode") ?? "carbs") ?? .carbs
        carbIncrement = ci ?? 5
        showGlucoseAxis = (d.object(forKey: "showGlucoseAxis") as? Bool) ?? true
        showIOBAxis = (d.object(forKey: "showIOBAxis") as? Bool) ?? true
        showBolusBars = (d.object(forKey: "showBolusBars") as? Bool) ?? true
        glucosePlotFloor = plotBounds.floor
        glucosePlotCeiling = plotBounds.ceiling
        showStats = (d.object(forKey: "showStats") as? Bool) ?? false
        glucoseStaleMinutes = (d.object(forKey: "glucoseStaleMinutes") as? Int) ?? 6
        phoneReadOnly = (d.object(forKey: "phoneReadOnly") as? Bool) ?? false
        readOnlyAllowAlertClear = (d.object(forKey: "readOnlyAllowAlertClear") as? Bool) ?? false
        remotesReadOnly = (d.object(forKey: "remotesReadOnly") as? Bool) ?? false
        // Defaults OFF so a fresh install (and any device with no stored value) cannot bolus from a
        // remote until the user explicitly opts in.
        garminBolusEnabled = (d.object(forKey: "garminBolusEnabled") as? Bool) ?? false
        showBolusReasoning = (d.object(forKey: "showBolusReasoning") as? Bool) ?? true
        garminComplicationDisplay = Self.complicationDisplayOptions.contains(cd) ? cd : "numericColor"
        garminClockAnalog = (d.object(forKey: "garminClockAnalog") as? Bool) ?? false

        // Remaining scalar assignments (deferred for the same two-phase-init reason). Locals they
        // consume (`bi`, `ci`, `order`, `def`, `gt`) were computed earlier.
        // Watch default: fall back to the phone default for existing users who never set it separately
        // (reads the RAW `defaultBolusMode` key directly, independent of `self.defaultBolusMode`).
        watchDefaultBolusMode =
            BolusMode(
                rawValue: d.string(forKey: "watchDefaultBolusMode")
                    ?? d.string(forKey: "defaultBolusMode") ?? "carbs") ?? .carbs
        // Clamp to the 0.05 minimum: a user who previously chose the (now-removed) 0.01 option would
        // otherwise land on a value absent from `bolusIncrements`, showing an empty Picker.
        bolusIncrement = max(0.05, bi ?? 0.05)
        watchBolusIncrement = max(0.05, (d.object(forKey: "watchBolusIncrement") as? Double) ?? (bi ?? 0.05))
        watchCarbIncrement = (d.object(forKey: "watchCarbIncrement") as? Double) ?? (ci ?? 5)
        // Default OFF (labels hidden on ambient surfaces). Cosmetic caption preference, not a
        // safety-adjacent force-set.
        showGlucoseUnitLabels = (d.object(forKey: "showGlucoseUnitLabels") as? Bool) ?? false
        // Force-set 1 (24h). Enforced at launch via `model.applyRetention(days:)`.
        historyRetentionDays = 1
        // Default ON — a fresh install (and any device with no stored value) auto-syncs.
        historySyncEnabled = (d.object(forKey: "historySyncEnabled") as? Bool) ?? true
        criticalAlertsEnabled = (d.object(forKey: "criticalAlertsEnabled") as? Bool) ?? false
        // One-time purge of the five UserDefaults keys the retired eating/Nudge surface left behind —
        // no code can read, display, or delete them once the surface is gone, so an upgrading tester's
        // learned coarse meal-place coordinates would otherwise survive as unreadable, undeletable
        // residue. Idempotent-once: checked, removed once, never re-fires (a later key of the same
        // name is never clobbered because the guard only ever runs while its own marker is absent).
        if d.object(forKey: "eatingResiduePurgeV1") == nil {
            for key in Self.retiredEatingResidueKeys { d.removeObject(forKey: key) }
            d.set(true, forKey: "eatingResiduePurgeV1")
        }
        autoExerciseMode = (d.object(forKey: "autoExerciseMode") as? Bool) ?? false
        autoSleepMode = (d.object(forKey: "autoSleepMode") as? Bool) ?? false
        garminDefaultScreen = order.contains(def) ? def : (order.first ?? "glance")
        garminTargetApp = (gt == "official") ? "official" : "beta"

        applyFreshness()  // side effects don't fire during init; push thresholds into faBolusCore now
        // Wire the `@Stored` `onChange` hooks LAST, after every property above has already received
        // its init-time value — every assignment before this line saw `onChange == nil`, so none of
        // these side effects fired during construction.
        _defaultBolusMode.onChange = { [weak self] _ in self?.syncWidgetConfig() }
        _carbIncrement.onChange = { [weak self] _ in self?.syncWidgetConfig() }
        _bolusIncrement.onChange = { [weak self] _ in self?.syncWidgetConfig() }
        _glucoseStaleMinutes.onChange = { [weak self] _ in self?.applyFreshness() }
    }
}
