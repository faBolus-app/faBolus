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
    /// Phase 04-01 (mmol/L display-unit support, D-03) — the glucose display-unit preference. mg/dL
    /// `Int` stays canonical everywhere internally; this ONLY selects which unit surfaces render/parse
    /// through (`GlucoseUnit.format`/`.parse`, faBolusCore). Default **mg/dL** (behavior-preserving for
    /// existing users, D-03). `.display` category, `backsUp: true`, iCloud sync ON — see `SettingsCatalog`.
    public var glucoseDisplayUnit: GlucoseUnit {
        didSet {
            d.set(glucoseDisplayUnit.rawValue, forKey: "glucoseDisplayUnit")
            // Phase 04-03: re-publish the App-Group WidgetSnapshot's displayUnit immediately so the
            // Home/Lock-Screen widgets (and, transitively, the watch complication) reflect a unit
            // toggle without waiting for the next pump reading. Not syncWidgetConfig() (Pattern 3 —
            // that channel is for bolus increments, unrelated to glucose display).
            WidgetPublisher.republishDisplayUnit()
        }
    }
    /// Whether the persistent/ambient mg/dL·mmol/L unit CAPTION is shown on display-only readouts
    /// (status ring, HUD ISF/target, stats card, chart axis, history, widgets, complication, and the
    /// Live Activity). **Default OFF** (owner request) — the number alone is shown on those ambient
    /// surfaces, keeping them visually quieter for a user who already knows their unit. This NEVER
    /// hides units from dose-confirmation dialogs (`BolusEntryView`), VoiceOver/accessibility strings,
    /// config/setup screens (`AlertRulesView`/`PumpWizardViews`/`CgmCredentialsView`), or the Settings
    /// unit picker itself — those are safety/clarity/setup contexts, not ambient display, and always
    /// keep the unit regardless of this flag. A display-format preference like `glucoseDisplayUnit`
    /// (NOT a per-device feature toggle), so it iCloud-syncs the same way — see `SettingsCatalog`.
    public var showGlucoseUnitLabels: Bool {
        didSet {
            d.set(showGlucoseUnitLabels, forKey: "showGlucoseUnitLabels")
            // Re-publish immediately (like `glucoseDisplayUnit`'s didSet) so the widgets/complication/
            // Live Activity reflect the toggle without waiting for the next pump reading.
            WidgetPublisher.republishShowUnitLabel()
        }
    }
    public var showIOBAxis: Bool { didSet { d.set(showIOBAxis, forKey: "showIOBAxis") } }
    public var showBolusBars: Bool { didSet { d.set(showBolusBars, forKey: "showBolusBars") } }

    /// Glucose plot Y-axis **ceiling**, canonical mg/dL (Phase 09.13, D-01/D-04). Discrete preset,
    /// `.display`/`backsUp: true` (same class as `glucoseDisplayUnit`) — see `SettingsCatalog`. The
    /// resolved-at-init pair always satisfies `floor < ceiling` via `GlucosePlotScale.resolve`
    /// (never assigned directly with an unresolved raw value from a Picker binding elsewhere).
    public var glucosePlotCeiling: Int { didSet { d.set(glucosePlotCeiling, forKey: "glucosePlotCeiling") } }
    /// Glucose plot Y-axis **floor**, canonical mg/dL (Phase 09.13, D-01/D-04). Discrete preset,
    /// `.display`/`backsUp: true`. Capped at 50 by `GlucosePlotScale.floorOptions` so the §13
    /// `veryLow` (54) reference line always stays on-chart (D-02/D-10).
    public var glucosePlotFloor: Int { didSet { d.set(glucosePlotFloor, forKey: "glucosePlotFloor") } }
    /// Re-exposed option sets for the Settings UI — pinned to `GlucosePlotScale` so no second
    /// literal preset list ever exists (D-02).
    public static let glucosePlotFloorOptions: [Int] = GlucosePlotScale.floorOptions
    public static let glucosePlotCeilingOptions: [Int] = GlucosePlotScale.ceilingOptions

    /// Optional Watch/Garmin plot Y-axis **override** (Phase 09.13-02, D-05). Treated as ONE unit — the
    /// UI clears/sets both together; `nil` means "Same as phone" for BOTH bounds, not per-bound. When
    /// set, always snapped in-set via `GlucosePlotScale.resolve` (never assigned raw). `.remotes`,
    /// `backsUp: true` (same category as `watchChartRanges`), canonical mg/dL. Never iCloud-relevant
    /// beyond the normal `.remotes` default (this is a display preference, not command-adjacent).
    public var glucosePlotCeilingSmall: Int? {
        didSet {
            if let v = glucosePlotCeilingSmall { d.set(v, forKey: "glucosePlotCeilingSmall") }
            else { d.removeObject(forKey: "glucosePlotCeilingSmall") }
        }
    }
    /// See `glucosePlotCeilingSmall` — the paired floor half of the same override unit.
    public var glucosePlotFloorSmall: Int? {
        didSet {
            if let v = glucosePlotFloorSmall { d.set(v, forKey: "glucosePlotFloorSmall") }
            else { d.removeObject(forKey: "glucosePlotFloorSmall") }
        }
    }

    /// Show the opt-in **Statistics** card on the dashboard (Time-in-Range, GMI, mean, CV over the
    /// in-memory ~24 h history). **Default OFF** so regular use stays clean. See [[GlucoseStatistics]].
    public var showStats: Bool { didSet { d.set(showStats, forKey: "showStats") } }

    /// Persistent-history retention in days; **0 = keep everything** (default). Storage is ~1 MB/month,
    /// so the default is unlimited; this only exists for users who prefer data-minimization.
    public var historyRetentionDays: Int { didSet { d.set(historyRetentionDays, forKey: "historyRetentionDays") } }

    /// Auto-sync pump history on connect (D-01, Phase 09.7-02). **Default ON** — the gap-aware sync
    /// (`TandemBackend`, Plan 01) runs automatically on every connect unless disabled here. Turning this
    /// OFF only suppresses the AUTOMATIC on-connect check; the "Sync now" manual trigger in
    /// `DataHistoryView` always runs the same gap-sync entry point regardless of this setting (UI-SPEC
    /// resolved assumption 2). Reachable in Data & History; a `SettingsCatalog` row, `backsUp: false`
    /// like `historyRetentionDays` (a device-local sync preference, not backup/iCloud-relevant).
    public var historySyncEnabled: Bool { didSet { d.set(historySyncEnabled, forKey: "historySyncEnabled") } }

    /// Last time a pump-history gap-sync completed (D-05, Phase 09.7-02) — feeds the "Last synced" row
    /// in `DataHistoryView`. Durable per-install marker, NOT a `SettingsCatalog` row (pure sync
    /// bookkeeping, mirrors `historyCoverage`'s own precedent) and never included in a settings backup.
    /// `nil` ⇒ never synced ("Never" / "Not synced yet").
    public var historyLastSyncedAt: Date? {
        didSet { d.set(historyLastSyncedAt?.timeIntervalSince1970 ?? 0, forKey: "historyLastSyncedAt") }
    }

    /// Persisted pump history-log sequence coverage (D-04, Phase 09.7) — replaces the one-shot
    /// `didBackfill` gate. `TandemBackend` reads this on every connect to compute exactly which
    /// sequence windows are still missing (D-02), and writes back into it as gap-sync windows complete.
    /// Derived/rebuildable local sync bookkeeping, not a user preference — persisted with
    /// `eatingTriggerConfig`'s JSON-in-UserDefaults shape, but deliberately NOT a `SettingsCatalog` row
    /// (no UI surface at all; see the NOTE in `SettingsCatalog.swift`) and never included in a settings
    /// backup.
    public var historyCoverage: HistoryCoverageMap {
        didSet { if let data = try? JSONEncoder().encode(historyCoverage) { d.set(data, forKey: "historyCoverage") } }
    }

    /// Eating-detection bolus nudge (multi-signal). **OFF by default** — advisory, never doses.
    public var eatingNudgesEnabled: Bool { didSet { d.set(eatingNudgesEnabled, forKey: "eatingNudgesEnabled") } }

    /// Phase 09.18b (D-07/D-09/D-17): background heart-rate-as-chart-context gate. **Default ON**,
    /// independently off-able. When OFF (D-09): the phone stops the on-demand HealthKit HR query, the
    /// phone signals the watch to stop appending HR (`hr_ctl` off), and the HR readout row is HIDDEN
    /// ENTIRELY (not "—"). HR is chart context ONLY — never a dose/meal input. Device-local display
    /// toggle (same device-local persisted-Bool idiom as `eatingNudgesEnabled`): deliberately NOT a
    /// `SettingsCatalog` row and NOT in `backupSnapshot`, so the catalog drift guards stay untouched.
    public var heartRateContextEnabled: Bool { didSet { d.set(heartRateContextEnabled, forKey: "heartRateContextEnabled") } }
    /// User-tunable trigger config (signals/mode/thresholds/delay). Persisted as JSON.
    public var eatingTriggerConfig: EatingTriggerConfig {
        didSet { if let data = try? JSONEncoder().encode(eatingTriggerConfig) { d.set(data, forKey: "eatingTriggerConfig") } }
    }
    /// On-device personalization for the nudge: adapt the wrist threshold (and, when the model is
    /// updatable, fine-tune it) from your feedback. On by default; everything stays on-device.
    public var eatingLearnFromFeedback: Bool { didSet { d.set(eatingLearnFromFeedback, forKey: "eatingLearnFromFeedback") } }

    // Phase 09.15 (D-07) — Control-IQ-awareness Smart-Assist toggle scaffold. Every later 09.15 plan
    // reads these flags rather than inventing its own; defaults are the owner-locked D-07 table
    // (`09.15-PATTERNS.md` "Smart Assist settings (D-07)", `09.15-BRAINSTORM.md` "Smart Assist grouping").
    // Same idiom as `eatingNudgesEnabled`: plain persisted Bool, mirrored to remotes on `statusRead` so a
    // remote suppresses an off feature belt-and-suspenders. T1-6 (extended disable-CIQ warning) has NO
    // flag here — it always fires, per D-07.
    /// T1-1/2/3/4 — CIQ state/status readouts (pure facts, no action). Default **ON**.
    public var ciqStateReadoutsEnabled: Bool { didSet { d.set(ciqStateReadoutsEnabled, forKey: "ciqStateReadoutsEnabled") } }
    /// T1-5 — 60-min auto-correction lockout countdown (safety-increasing disclosure). Default **ON**.
    public var ciqLockoutCountdownEnabled: Bool { didSet { d.set(ciqLockoutCountdownEnabled, forKey: "ciqLockoutCountdownEnabled") } }
    /// T1-8 — "% of configured max basal" readout (introduces a "limit" concept). Default **OFF**.
    public var ciqMaxBasalReadoutEnabled: Bool { didSet { d.set(ciqMaxBasalReadoutEnabled, forKey: "ciqMaxBasalReadoutEnabled") } }
    /// T1-9 — Sleep/Exercise awareness (least directly pump-sourced). Default **OFF**.
    public var ciqSleepExerciseAwarenessEnabled: Bool { didSet { d.set(ciqSleepExerciseAwarenessEnabled, forKey: "ciqSleepExerciseAwarenessEnabled") } }
    /// T2-3 — CIQ+-only temp-rate placeholder (bench-gated, `benchVerifiedDefault = false`). Default **OFF**.
    public var ciqPlusTempRateEnabled: Bool { didSet { d.set(ciqPlusTempRateEnabled, forKey: "ciqPlusTempRateEnabled") } }
    /// T2-1 — direct CIQ-ceiling flags (bench-gated, render-absent pre-bench). Default **OFF**.
    public var ciqCeilingFlagsEnabled: Bool { didSet { d.set(ciqCeilingFlagsEnabled, forKey: "ciqCeilingFlagsEnabled") } }
    // Generic "About Smart Features" one-time explainer (09.18a, D-16) — a durable per-install marker,
    // same idiom as `stackingGuardNoticeAckAt`: NOT a `SettingsCatalog` row, never backed up / iCloud-
    // synced (a synced ack must not pre-suppress the notice on another device). Fired on first ENABLE of
    // a Smart Features surface (e.g. SiteAtlas). nil ⇒ never shown. NEVER gates a write.
    public var smartFeaturesNoticeAckAt: Date? { didSet { d.set(smartFeaturesNoticeAckAt?.timeIntervalSince1970 ?? 0, forKey: "smartFeaturesNoticeAckAt") } }
    public var hasAcknowledgedSmartFeaturesNotice: Bool { smartFeaturesNoticeAckAt != nil }
    public func acknowledgeSmartFeaturesNotice() { if smartFeaturesNoticeAckAt == nil { smartFeaturesNoticeAckAt = Date() } }

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
    /// action is additionally gated on the pump advertising the capability (pump-derived, Mobi-only in
    /// practice) via `advancedControlAllowed(capabilities:)`. Insulin-affecting actions still go through
    /// the confirm/hold + max-bolus-clamp + WritePolicy interlocks.
    ///
    /// Phase 9 (09-02, MOBI-02): its ONLY UI writer (the Settings "Advanced control" Toggle) is
    /// deleted — the persisted value can never be flipped back to `true` from this build again
    /// (LOCK-01 "pin at the sole writer" pattern). No force-reset migration is added: `AppModel.swift`
    /// (DOSE_PATHS, unedited) still reads this via `advancedControlOptIn`/`advancedControlAllowed`, and
    /// `advancedControlAllowed` is ALREADY always-false via its other operand
    /// (`capabilities.supportsAnyAdvancedControl`, always false on the t:slim-only model) — same
    /// ordinary-hidden-flag posture as `showGlucoseUnitLabels`, not `autoSyncPumpTime`'s force-set pin.
    public var advancedControlEnabled: Bool { didSet { d.set(advancedControlEnabled, forKey: "advancedControlEnabled") } }

    /// P14 — the active experience **mode** (Simple / Standard / Advanced), the axis the access evaluator
    /// gates on (`AccessPolicy.ModeGateContext`). This is the mode *selector*, not a mode-gated setting, so
    /// it is deliberately NOT a `SettingsCatalog` row and is **never** backed up or iCloud-synced (a synced
    /// mode could silently unlock features on another device — the S3 coherence hazard). Default `.advanced`
    /// in Slice 2 is behavior-preserving (Advanced sees everything, so the mode gate is a no-op); S3
    /// introduces the guided Objectives unlock and flips the effective default to Simple with the unlock
    /// path in the same change, so no build ever ships Simple-with-no-way-out. Phone↔watch mode coherence
    /// (S4) rides the App Group + status payload, independent of iCloud.
    public var appMode: AppMode { didSet { d.set(appMode.rawValue, forKey: "appMode") } }

    /// **Read-only mode (this phone).** Turns the app into a safe viewer: bolusing and all pump control
    /// are disabled and their UI (Bolus tab, Pump Control) is hidden. **Default OFF.** Clearing pump
    /// alerts is also disabled by default while read-only, unless `readOnlyAllowAlertClear` is on.
    public var phoneReadOnly: Bool { didSet { d.set(phoneReadOnly, forKey: "phoneReadOnly") } }
    /// Sub-option of read-only mode: still allow clearing/snoozing pump alerts. **Default OFF.**
    public var readOnlyAllowAlertClear: Bool { didSet { d.set(readOnlyAllowAlertClear, forKey: "readOnlyAllowAlertClear") } }
    /// **Read-only mode for the Apple Watch + Garmin remotes.** They hide their bolus screen/button and
    /// can't deliver (the host refuses too); viewing stays. Independent of the phone flag. **Default OFF.**
    public var remotesReadOnly: Bool { didSet { d.set(remotesReadOnly, forKey: "remotesReadOnly") } }

    /// **Garmin bolusing allowed (§2.3).** An explicit per-surface enable for delivering a bolus *from the
    /// Garmin watch*, **default OFF** so bolusing is off until the user opts in with the one-time warning.
    /// Independent of — and ANDed with — `remotesReadOnly` (read-only still wins). This replaces the old
    /// posture where the only control was the inverted `remotesReadOnly` and Garmin bolusing shipped ON.
    /// Command-adjacent: backed up (a restore is an explicit user action) but **never** iCloud-synced (C5) —
    /// an auto-synced value must not silently arm bolusing on another device.
    public var garminBolusEnabled: Bool { didSet { d.set(garminBolusEnabled, forKey: "garminBolusEnabled") } }
    /// **Apple Watch bolusing allowed (§2.3).** As `garminBolusEnabled`, for the Apple Watch. **Default OFF.**
    ///
    /// Phase 3 (03-03, REMOTE-03): the Apple Watch app this enabled is delete-on-main, so this can
    /// never take effect again. Same hidden-flag posture as `requireRemoteBolusApproval` (03-02, F-1):
    /// this accessor STAYS — the frozen `AppModel.swift:360,533` + `AccessPolicy.swift:199` still read
    /// it — but its `SettingsCatalog` row, `backupSnapshot`/`applyBackup` participation, and
    /// `RemotesSettingsView` UI (toggle + one-time-warning dialog) are all removed. A legacy backup
    /// carrying this key is now silently ignored (same tolerance as the existing
    /// `basalScheduleByHour`/`basalScheduleSource` precedent).
    public var watchBolusEnabled: Bool { didSet { d.set(watchBolusEnabled, forKey: "watchBolusEnabled") } }

    /// **Optional remote-only per-bolus ceiling (§2.3).** When set (a positive units value), a bolus started
    /// from a REMOTE surface (Apple Watch / Garmin) is capped at this many units *in addition to* the pump's
    /// own max bolus. `nil` = **off (default)** — the pump's max alone governs. The iPhone's own bolus never
    /// consults this (it is applied only at the remote `BolusGate` `maximum` seam — see
    /// `AppModel.remoteBolusMaximum`). Command-adjacent: backed up (a restore is an explicit user action) but
    /// **never** iCloud-synced (C5) — an auto-synced value must not silently relax the cap on another device.
    public var remoteBolusCeiling: Double? {
        didSet {
            if let v = remoteBolusCeiling, v > 0 { d.set(v, forKey: "remoteBolusCeiling") }
            else { d.removeObject(forKey: "remoteBolusCeiling") }
        }
    }
    /// The selectable remote-ceiling caps (units), and the value first applied when the user turns the limit
    /// on. Every option is well under the pump/backend hard max (25 U), so the ceiling can only ever lower it.
    public static let remoteBolusCeilingOptions: [Double] = [1, 2, 3, 5, 8, 10, 15, 20]
    public static let defaultRemoteBolusCeiling: Double = 5

    /// Keep the pump's clock aligned with this phone: sync at most once a day while connected, and
    /// immediately when the phone's clock or time zone changes (travel / DST). **Default OFF (P15 E2 exit
    /// criterion)** so a first connect never silently writes the pump clock without an explicit opt-in.
    /// Only active on pumps that honor the time write (**Mobi** — t:slim X2 doesn't accept it), gated on
    /// `capabilities.supportsTimeSync`; not insulin-affecting and **independent of** `advancedControlEnabled`
    /// (the opt-in is a plain preference, never re-coupled to the advanced-control gate).
    public var autoSyncPumpTime: Bool { didSet { d.set(autoSyncPumpTime, forKey: "autoSyncPumpTime") } }

    /// **Auto Exercise mode** — switches the pump into Control-IQ Exercise mode when a workout starts,
    /// and back to normal when it ends. **Default OFF.** Auto-switching applies only to a **Mobi**
    /// (t:slim X2 can't; it gets a reminder if `modeReminders` is on). See [[jwoglom-parity-roadmap]].
    /// Phase 7 (07-03, FEAT-05, D-08): FROZEN — hidden (no Settings UI) and unregistered (no
    /// `SettingsCatalog` descriptor, no backup/restore participation, `historyCoverage` idiom); the kept
    /// `ModeAutomation.swift` still reads it (`AppModel.swift:1821,2115`, `DOSE_PATHS`).
    public var autoExerciseMode: Bool { didSet { d.set(autoExerciseMode, forKey: "autoExerciseMode") } }
    /// **Auto Sleep mode** — switches the pump into Sleep mode when the iPhone enters Sleep Focus, and
    /// back when it ends. **Default OFF.** Mobi-only auto-switch. Phase 7 (07-03, FEAT-05, D-08):
    /// FROZEN — same hidden/unregistered posture as `autoExerciseMode` above.
    public var autoSleepMode: Bool { didSet { d.set(autoSleepMode, forKey: "autoSleepMode") } }
    /// **Mode reminders** — when an auto mode-switch can't be applied automatically (a t:slim, or the
    /// pump isn't connected), post a notification reminding the user to switch modes on the pump
    /// themselves. **Default OFF.** Phase 7 (07-03, FEAT-05, D-08): FROZEN — same hidden/unregistered
    /// posture as `autoExerciseMode` above.
    public var modeReminders: Bool { didSet { d.set(modeReminders, forKey: "modeReminders") } }
    // Phase 7 (07-03, FEAT-05, D-08): autoTempRate/autoProfileActivation are DELETED — their only
    // readers were the removed TempRateAutomation/ProfileAutomation engines (Task 2), so no reader
    // remains anywhere in the app; a genuine delete, not a freeze. Preserved on dev/siri-shortcuts.

    /// §6/S8 B6: opt-out — suppress the APP's re-notification of pump ALARMS (`PumpAlert.kind == .alarm`),
    /// which the pump itself already annunciates audibly (esp. relevant on a t:slim, where the alarm sounds
    /// on the pump). **Default OFF**; enabling it is behind a warning + explicit confirm (safety-reducing).
    /// It NEVER touches the app-only never-suppressible safety trio (pump disconnect / CGM data loss /
    /// bolus reconciliation) — those post on separate paths. A LOCAL device pref: deliberately NOT backed
    /// up and NOT iCloud-synced (a synced value must not silently silence alarms on another device).
    public var suppressMirroredPumpAlarms: Bool { didSet { d.set(suppressMirroredPumpAlarms, forKey: "suppressMirroredPumpAlarms") } }
    /// §6/S8 B6: use iOS **Critical Alerts** (which alert even under Do Not Disturb / the ringer switch)
    /// for the never-suppressible safety notifications — WHEN the app holds the critical-alerts entitlement;
    /// it degrades gracefully to a normal notification when the entitlement isn't granted. Phase 9 (09-04,
    /// MOBI-04, D-06): **Default explicit OFF for t:slim**, DECOUPLED from `PumpModelStore.isMobi()` (the
    /// old default was "ON for a Mobi" — Simulated Mobi and all Mobi backends are removed this phase, so
    /// that coupling is now to a permanently-stale flag). The user can still turn it on explicitly — the
    /// capability path (`NotificationCoordinator.swift:384` read, `NotificationSettingsView.swift` toggle)
    /// is KEPT, unchanged. A pre-Phase-9 persisted `true` is force-reset to `false` exactly once on upgrade
    /// (see the `criticalAlertsForceResetV050` guard below `init`) — owner chose uniform state over leaving
    /// stale persisted values. Local device pref: not backed up / iCloud-synced.
    public var criticalAlertsEnabled: Bool { didSet { d.set(criticalAlertsEnabled, forKey: "criticalAlertsEnabled") } }
    /// D-03/D-04: an OS-DERIVED CACHE, not a user pref — whether `UNUserNotificationCenter`'s async
    /// `notificationSettings().criticalAlertSetting` last reported `.enabled` (the entitlement is granted
    /// AND the user authorized it). `NotificationCoordinator.refreshGrantState()` is the sole writer.
    /// Defaults `false` so the app never over-claims critical delivery before the first OS query resolves.
    /// Deliberately NOT persisted to `UserDefaults` and NOT part of any backup/applyBackup key list —
    /// `@Observable` tracks it automatically for `AlertRulesView`'s honest-status read. UI-only: NEVER
    /// consulted by `NotificationCoordinator.post`'s `allowCritical` gate or `NotificationBroker.decide`
    /// (D-05 — the cache can never suppress the never-suppressible trio).
    public var criticalAlertGrantActive: Bool = false

    /// Phase 3 (03-02, REMOTE-02, Pitfall B): the Bluetooth remote peripheral (Mac + remote iPhone)
    /// gate is fully removed — no accessor, no UI, no backup key — since it was never read by
    /// `AppModel.swift` (verified). Preserved on `dev/phone-remote`.

    /// Reverse approval (opt-in): a bolus started on **this** phone must be approved by a paired remote
    /// (e.g. a parent) before it delivers. **Default OFF.** Only takes effect when a remote is paired;
    /// if no paired remote responds within the timeout the bolus is aborted (safe default).
    ///
    /// Phase 3 (03-02, F-1, owner-ratified 2026-08-21): the ONLY devices that could ever pair as an
    /// approver (Mac remote, iPhone-peer remote) are removed from narrow `main`, so this already could
    /// never take effect again (`hasPairedRemote` in the frozen `AppModel.swift` is now permanently
    /// false). Its `SettingsCatalog` row + backup/restore participation + `ChildModeView` UI were
    /// already removed then (hidden, unregistered flag; same pattern as `watchBolusEnabled`'s eventual
    /// removal). See 03-OWNER-FLAGS.md F-1.
    ///
    /// Phase 7 (07-04, FEAT-04, D-05, SAFETY): FROZEN to `false` — belt-and-suspenders, layer 2. Phase 3
    /// already closed the local-backup round trip (no `backupSnapshot`/`applyBackup` participation
    /// remained even before this change); this getter-level freeze closes the one remaining route (a
    /// direct setter call) so this can never become `true` again by ANY means, not just via restore.
    /// The frozen `AppModel.swift`'s one read of this value (alongside `childModeEnabled` and
    /// `hasPairedRemote`) stays BYTE-IDENTICAL — only this settable INPUT is forced (D-03). See
    /// `ChildModeFreezeGuardTests`.
    public var requireRemoteBolusApproval: Bool { get { false } set { } }

    /// User-defined auto-rules for pump alerts (time-of-day / kind / glucose → auto-snooze or
    /// auto-dismiss). **Alarms are never auto-acted** regardless of rules — the engine hard-excludes
    /// them. See [[AlertRuleEngine]].
    ///
    /// Phase 7 (07-05, FEAT-08, D-06/D-07, SAFETY): the custom alert-rules ENGINE
    /// (`AlertRule`/`AlertRuleEngine`/`AlertAction` in the byte-identity-protected `faBolusCore`)
    /// cannot be literally deleted — `TandemBackend.swift`'s `applyAutoRules` reads this property and
    /// is itself DOSE_PATHS-protected. FROZEN to always-`[]` instead — belt-and-suspenders, same
    /// posture as `childModeEnabled`/`requireRemoteBolusApproval` (FEAT-04, 07-04): a getter-level
    /// freeze (`get { [] } set { } }`) AND removal of the `UserDefaults` init-restore /
    /// `backupSnapshot` / `applyBackup` lines below, so neither a direct setter call nor a restored
    /// settings backup carrying a non-empty rule-set can ever re-arm the engine. This makes
    /// `TandemBackend.swift`'s `guard !rules.isEmpty else { return }` fire unconditionally — a
    /// behavior-neutral early-return; `TandemBackend.swift` and `AlertRuleEngine.swift` themselves
    /// stay BYTE-IDENTICAL (never edited). `Views/AlertRulesView.swift` (the only UI that could ever
    /// set this to non-empty) is deleted in the next task. See `AlertRulesFreezeGuardTests`.
    public var alertRules: [AlertRule] { get { [] } set { } }

    /// Upload glucose + boluses + pump status to a Nightscout site. Nightscout was removed from
    /// narrow `main` in Phase 5 (HEALTH-02) — this accessor STAYS (a hidden, unregistered
    /// device-local flag, no migration) but its `SettingsCatalog` row, `backupSnapshot`/
    /// `applyBackup` participation, and `SettingsView` UI are removed (same hidden-flag pattern as
    /// `watchBolusEnabled`/`requireRemoteBolusApproval`). See dev/nightscout's REINTEGRATION.md.
    public var nightscoutUploadEnabled: Bool { didSet { d.set(nightscoutUploadEnabled, forKey: "nightscoutUploadEnabled") } }

    /// Phase 09.23-02 (D-14): per-type Apple Health IMPORT toggles — each import type (carbs,
    /// insulin/bolus, heart rate, glucose gap-fill) is individually user-selectable. All **default
    /// OFF** — a fresh install imports nothing until the user explicitly turns on each type. Gates
    /// BOTH the per-type HealthKit read-authorization request AND the ingest path
    /// (`AppModel.importFromAppleHealth`, D-13-gated). Deliberately NOT wrapped in
    /// `#if FABOLUS_HEALTHKIT` (unlike the AppModel import hook) — the settings MODEL stays
    /// unconditional so it compiles/tests under the default OFF build; only the FEATURE REACH (the
    /// actual HealthKit calls) is gated. Same device-local persisted-Bool idiom as
    /// `heartRateContextEnabled`/`eatingNudgesEnabled`: deliberately NOT a `SettingsCatalog` row
    /// and NOT in `backupSnapshot` THIS WAVE — the UI surface these toggles gate (per-type rows in
    /// `CgmCredentialsView`, D-14) ships in a later wave, and `SettingsReachabilityGuardTests`' SC2
    /// requires every catalog row to have a literal UI reference; adding the catalog row before the
    /// UI exists would make that guard fail for the right reason. Revisit (add the catalog row +
    /// backup participation) once the UI lands.
    public var healthKitImportCarbsEnabled: Bool { didSet { d.set(healthKitImportCarbsEnabled, forKey: "healthKitImportCarbsEnabled") } }
    public var healthKitImportInsulinEnabled: Bool { didSet { d.set(healthKitImportInsulinEnabled, forKey: "healthKitImportInsulinEnabled") } }
    public var healthKitImportHeartRateEnabled: Bool { didSet { d.set(healthKitImportHeartRateEnabled, forKey: "healthKitImportHeartRateEnabled") } }
    public var healthKitImportGlucoseEnabled: Bool { didSet { d.set(healthKitImportGlucoseEnabled, forKey: "healthKitImportGlucoseEnabled") } }
    /// D-11b: automatic background Apple Health import (anchored observer, like the live-glucose
    /// reader). **Default OFF** — the manual on-demand "Import from Apple Health" action is always
    /// available regardless of this toggle (D-11: manual = baseline, auto = opt-in).
    public var healthKitAutoImportEnabled: Bool { didSet { d.set(healthKitAutoImportEnabled, forKey: "healthKitAutoImportEnabled") } }

    /// Phase 09.23-03 (D-12/D-14): per-type Apple Health EXPORT toggles — each export type (carbs,
    /// insulin/bolus, glucose) is individually user-selectable. All **default OFF**. Deliberately NO
    /// heart-rate export toggle exists (D-08 — HR is read-only, originates from the user's own
    /// sensors, and is never written back to Health). Same shape/deferral rationale as the import
    /// toggles immediately above: unconditional (not `#if FABOLUS_HEALTHKIT`) so the settings MODEL
    /// compiles/tests under the default OFF build, and — even though this plan's Task 3 gives them a
    /// `CgmCredentialsView` UI reference — deliberately NOT yet added to `SettingsCatalog`/
    /// `backupSnapshot`/`applyBackup`: `SettingsCatalogTests.backedUpSetMatchesBackupSnapshot`
    /// requires a backed-up key to be a catalog row AND vice-versa is not required, so a UI reference
    /// alone doesn't force catalog participation, and adding it is a separate, deliberate decision
    /// (iCloud-sync/backup semantics) left to a future wave rather than bundled into this one.
    public var healthKitExportCarbsEnabled: Bool { didSet { d.set(healthKitExportCarbsEnabled, forKey: "healthKitExportCarbsEnabled") } }
    public var healthKitExportInsulinEnabled: Bool { didSet { d.set(healthKitExportInsulinEnabled, forKey: "healthKitExportInsulinEnabled") } }
    public var healthKitExportGlucoseEnabled: Bool { didSet { d.set(healthKitExportGlucoseEnabled, forKey: "healthKitExportGlucoseEnabled") } }
    /// D-12: automatic go-forward Apple Health export (each newly-logged carb/insulin/bolus/glucose
    /// written out as logged). **Default OFF** — the manual "Export to Apple Health" backfill action
    /// is always available regardless of this toggle (mirrors D-11's manual=baseline, auto=opt-in
    /// split already established for import).
    public var healthKitAutoExportEnabled: Bool { didSet { d.set(healthKitAutoExportEnabled, forKey: "healthKitAutoExportEnabled") } }

    /// Opt-in (default OFF, N21) for local notification telemetry — per-category delivered/dismissed/
    /// acted-upon counts the broker uses to tune defaults. Stored in the **App Group** (not `d`) so the
    /// broker, incl. the out-of-process mode-reminder intent, reads the same choice. Local-only, never
    /// uploaded. No settings toggle is wired yet; this is the opt-in the broker gates accrual on.
    public var notificationTelemetryEnabled: Bool {
        get { UserDefaults(suiteName: WidgetStore.appGroup)?.bool(forKey: NotificationRuntime.telemetryEnabledKey) ?? false }
        set { UserDefaults(suiteName: WidgetStore.appGroup)?.set(newValue, forKey: NotificationRuntime.telemetryEnabledKey) }
    }

    /// Show the extended (combo) bolus controls on the bolus screen. **Default OFF** to keep the
    /// screen simple. When on, the user can split a dose into now + over-a-duration.
    public var extendedBolusEnabled: Bool { didSet { d.set(extendedBolusEnabled, forKey: "extendedBolusEnabled") } }
    /// Show the collapsible "reasoning" breakdown (IOB, carb+correction, max-safe hint) under the
    /// recommendation. Default ON but collapsed; turn off to remove it entirely.
    public var showBolusReasoning: Bool { didSet { d.set(showBolusReasoning, forKey: "showBolusReasoning") } }

    /// **Insulin Stacking Guard SG3a escalating friction (task #93), .user tier, Simple minimum mode.**
    /// Default ON. Gates only whether SG3a's ESCALATED friction tiers (`.confirmExtra`/`.reenter`) are
    /// applied on the bolus screen — SG1/SG2's plain disclosures and SG3a's own `.disclose` line still
    /// render when this is OFF; turning it off never disables the underlying `StackingGuard.escalation`
    /// computation, only the UI wiring that reads this flag (landing in plan 04).
    public var stackingGuardFrictionEnabled: Bool { didSet { d.set(stackingGuardFrictionEnabled, forKey: "stackingGuardFrictionEnabled") } }

    /// Child (locked) mode: a PIN-protected mode a parent enables on a child's device. When on, only
    /// the features in `childAllowed` are permitted; everything that dispenses insulin is blocked by
    /// default. The PIN hash lived in the Keychain (`ChildModeStore`, now removed along with
    /// `ChildModeView.swift`, its only caller).
    ///
    /// Phase 7 (07-04, FEAT-04, D-05, SAFETY): FROZEN to `false` — belt-and-suspenders runtime gate.
    /// No setter effect can ever make this `true` again, including a restored-from-backup `true` (the
    /// `applyBackup` restore line that used to accept this key is removed below, so both halves of the
    /// round trip are closed). Forcing this INPUT false = full adult access = the safe/intended state
    /// for a single-adult device. The dose-adjacent evaluator (`AccessPolicy`/`ChildFeature`/
    /// `BolusGate`/`GatedPumpWrite` in faBolusCore) and `AppModel.swift`'s one read of this value stay
    /// BYTE-IDENTICAL — only this settable INPUT is forced (D-03). `childModeEnabled` already had
    /// `syncsToICloud: false`, so the iCloud-KV half of the restore concern was already closed before
    /// this change; this closes the remaining local-backup half. `ChildModeView.swift` (the only UI
    /// that could ever set this to `true`) is deleted in the next task. See `ChildModeFreezeGuardTests`.
    public var childModeEnabled: Bool { get { false } set { } }
    public var childAllowed: Set<ChildFeature> {
        didSet { d.set(Self.canonicalChildAllowedData(childAllowed), forKey: "childAllowed") }
    }
    /// Encode `childAllowed` deterministically. `Set` serializes to a JSON array in hash-iteration order,
    /// which Swift randomizes per process — so the *same* set of features encodes to different bytes across
    /// launches and devices, producing spurious backup/iCloud diffs (and a flaky `backupSnapshot` round-trip
    /// equality check). Sorting by `rawValue` first makes the encoding canonical and seed-independent;
    /// decoding `Set<ChildFeature>` from the array is unaffected, so old blobs still load and no migration is
    /// needed. This is the only `Set`-backed persisted value; `alertRules` is an ordered array already.
    nonisolated static func canonicalChildAllowedData(_ set: Set<ChildFeature>) -> Data {
        (try? JSONEncoder().encode(set.sorted { $0.rawValue < $1.rawValue })) ?? Data()
    }
    /// Whether `feature` is currently permitted (always true when child mode is off).
    public func childAllows(_ feature: ChildFeature) -> Bool {
        !childModeEnabled || childAllowed.contains(feature)
    }

    /// Whether the advanced-control surface should be shown/enabled: opt-in ON **and** the pump
    /// advertises at least one advanced-control capability. P13: capabilities are pump-derived
    /// (`PumpCapabilities.derive` reads the pump's own feature bitmask), replacing the old raw `isMobi`
    /// model check. This is the single gate the control UI uses.
    public func advancedControlAllowed(capabilities: PumpCapabilities) -> Bool {
        advancedControlEnabled && capabilities.supportsAnyAdvancedControl
    }

    /// Garmin remote layout: the swipe order of its screens and which one opens first. Pushed to
    /// the watch in the status payload; the Garmin app persists it locally so it survives restarts.
    public var garminScreenOrder: [String] { didSet { d.set(garminScreenOrder, forKey: "garminScreenOrder") } }
    public var garminDefaultScreen: String { didSet { d.set(garminDefaultScreen, forKey: "garminDefaultScreen") } }
    /// How the Garmin BG complication presents: "numericColor" (numeric value with range-coloring +
    /// a Latin trend in the unit slot) or "stringTrend" (a plain "124 ^" string, no color). Mirrored.
    public var garminComplicationDisplay: String { didSet { d.set(garminComplicationDisplay, forKey: "garminComplicationDisplay") } }
    /// Whether the Garmin clock screen draws an analog face (true) or the digital readout (false, default).
    /// Pushed to the remote in the status payload, replacing the old on-watch tap toggle. Mirrored.
    public var garminClockAnalog: Bool { didSet { d.set(garminClockAnalog, forKey: "garminClockAnalog") } }
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
    /// Phase 7 (07-02, FEAT-03, D-04 literal no-op stub — owner decision 2026-08-21): ORPHANED-BUT-
    /// COMPILED. Its Settings UI + `SettingsCatalog` descriptor + `backupSnapshot`/`applyBackup`
    /// participation are all removed — nothing in the app can set this to `true` anymore, and even if a
    /// value somehow persisted from before this removal, `GlucoseBadge` is now a main-only inert stub
    /// whose `apply(_:now:)` does nothing regardless of this value. The `didSet` below stays, calling
    /// the stub's no-op `clear()` — kept for interface symmetry, not because it does anything now. The
    /// real opt-in (a pure freshness function + a `UNUserNotificationCenter.setBadgeCount` I/O sink) is
    /// preserved on `dev/glucose-badge`.
    public var glucoseBadgeEnabled: Bool {
        didSet {
            d.set(glucoseBadgeEnabled, forKey: "glucoseBadgeEnabled")
            if !glucoseBadgeEnabled { GlucoseBadge.clear() }
        }
    }
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
    /// back to the full list if nothing valid is stored (never leave the surface empty) — UNLESS
    /// `emptyMeansEmpty` is true AND a value was actually persisted (`stored != nil`), in which case a
    /// persisted `[]` is honored as an explicit empty selection rather than collapsed back to `all`.
    /// (Phase 09.14, D-01/WR-04 — originally added for the now-removed `liveActivityFields` opt-in;
    /// `detailsOrder`/`watchDetailsOrder`/`pillsOrder` keep the default `false` and are unaffected,
    /// pinned by `RestoreOrderEmptyFallbackTests`'s 3 named non-regression tests.) A genuinely-absent
    /// key (`stored == nil`) ALWAYS falls back to `all`, regardless of `emptyMeansEmpty`.
    private static func restoreOrder(_ stored: [String]?, all: [String], emptyMeansEmpty: Bool = false) -> [String] {
        guard let stored = stored else { return all }
        var order: [String] = []
        for s in stored where all.contains(s) && !order.contains(s) { order.append(s) }
        if order.isEmpty { return emptyMeansEmpty ? [] : all }
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
    public static let garminScreens: [String] = ["glance", "glucose", "clock", "bolusonly", "alerts", "history", "details"]
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

    /// The backing store. `.standard` in the app (via `.shared`); a fresh throwaway suite in tests so the
    /// first-launch defaults can be asserted without touching the real user defaults (P15 E2 exit test).
    private let d: UserDefaults

    // P14 S8 (§2.1(2)): the one-time clinician-tier acknowledgment. Persisted (durable), but NOT a
    // catalog row — never backed up, never iCloud-synced: a per-install first-use disclosure of clinical
    // ownership. It NEVER gates a write (not a `DenialReason`); it only records that the clinician-tier
    // disclosure was shown and accepted. nil ⇒ never acknowledged.
    public var clinicianTierAckAt: Date? { didSet { d.set(clinicianTierAckAt?.timeIntervalSince1970 ?? 0, forKey: "clinicianTierAckAt") } }
    public var hasAcknowledgedClinicianTier: Bool { clinicianTierAckAt != nil }
    /// Record the one-time acknowledgment (idempotent — keeps the first timestamp).
    public func acknowledgeClinicianTier() { if clinicianTierAckAt == nil { clinicianTierAckAt = Date() } }

    // §2.1(4) B1(e): the one-time "editing these values affects AUTOMATED delivery, not just manual
    // boluses" acknowledgment, shown at the first therapy-segment edit. Same idiom as `clinicianTierAckAt`:
    // durable per-install marker, NOT a catalog row — never backed up, never iCloud-synced (a synced ack
    // must not silently pre-suppress the disclosure on another device). NEVER gates a write. nil ⇒ never shown.
    public var therapyEditAckAt: Date? { didSet { d.set(therapyEditAckAt?.timeIntervalSince1970 ?? 0, forKey: "therapyEditAckAt") } }
    public var hasAcknowledgedTherapyEdit: Bool { therapyEditAckAt != nil }
    /// Record the one-time therapy-edit acknowledgment (idempotent — keeps the first timestamp).
    public func acknowledgeTherapyEdit() { if therapyEditAckAt == nil { therapyEditAckAt = Date() } }

    // §2.3 (G5): the one-time "you're turning on real insulin delivery from this remote" acknowledgment,
    // shown the FIRST time each surface's enable is switched on. Same idiom as `clinicianTierAckAt`:
    // durable per-install markers, NOT catalog rows — never backed up, never iCloud-synced (a synced ack
    // must not silently pre-suppress the warning on another device). nil ⇒ never acknowledged.
    // Phase 3 (03-03, REMOTE-03): the RemotesSettingsView call sites that read/write these three
    // (the watch bolus-enable toggle + its one-time-warning confirmationDialog) are removed along
    // with the Watch app they warned about — these accessors are now unreachable, harmless dead
    // storage (never written again, so `hasAcknowledgedWatchBolusWarning` stays permanently false).
    // Left in place rather than deleted: no correctness/security implication either way, and this
    // file is outside the plan's declared scope for anything beyond the accessor demotion above.
    public var watchBolusWarningAckAt: Date? { didSet { d.set(watchBolusWarningAckAt?.timeIntervalSince1970 ?? 0, forKey: "watchBolusWarningAckAt") } }
    public var hasAcknowledgedWatchBolusWarning: Bool { watchBolusWarningAckAt != nil }
    public func acknowledgeWatchBolusWarning() { if watchBolusWarningAckAt == nil { watchBolusWarningAckAt = Date() } }
    public var garminBolusWarningAckAt: Date? { didSet { d.set(garminBolusWarningAckAt?.timeIntervalSince1970 ?? 0, forKey: "garminBolusWarningAckAt") } }
    public var hasAcknowledgedGarminBolusWarning: Bool { garminBolusWarningAckAt != nil }
    public func acknowledgeGarminBolusWarning() { if garminBolusWarningAckAt == nil { garminBolusWarningAckAt = Date() } }

    // FLAG-4 (§1.5, REQ-D16-flags): the one-time DosingSafetyKit→SG advisory-behavior-change notice, shown
    // the first time the bolus screen appears. Same idiom as `therapyEditAckAt`: durable per-install
    // marker, NOT a `SettingsCatalog` row — never backed up, never iCloud-synced (a synced ack must not
    // silently pre-suppress the notice on another device). NEVER gates a write. nil ⇒ never shown.
    public var stackingGuardNoticeAckAt: Date? { didSet { d.set(stackingGuardNoticeAckAt?.timeIntervalSince1970 ?? 0, forKey: "stackingGuardNoticeAckAt") } }
    public var hasAcknowledgedStackingGuardNotice: Bool { stackingGuardNoticeAckAt != nil }
    /// Record the one-time acknowledgment (idempotent — keeps the first timestamp).
    public func acknowledgeStackingGuardNotice() { if stackingGuardNoticeAckAt == nil { stackingGuardNoticeAckAt = Date() } }

    /// `.shared` uses `.standard`; the P15 E2 first-launch defaults test injects a fresh empty suite. Not
    /// `private` (was) so `@testable` tests can construct an instance over an injected store — the app
    /// still funnels everything through `.shared`.
    init(defaults: UserDefaults = .standard) {
        self.d = defaults
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
        // Phase 8 (08-01, LOCK-02): force-set `.mgdl` unconditionally — the unit Picker is removed this
        // phase, so no UI can select mmol/L; a restored/legacy UserDefaults value carrying "mmol" must
        // not silently change the display unit (Pitfall 1). The dose path is mg/dL-canonical regardless
        // (`BolusMath`) — this pin only removes the display-conversion surface, never touches it.
        glucoseDisplayUnit = .mgdl
        // Owner request: default OFF (labels hidden on ambient surfaces) for a fresh install / absent
        // key. Not a LOCK-02 force-set pin — the "Show unit labels" toggle is removed with the unit
        // Picker (both lived in the same now-deleted Section), but this is a cosmetic caption
        // preference, not a safety-adjacent lock, so the accessor stays a normal read/writable flag
        // (hidden-flag pattern, same posture as other UI-only removals this milestone).
        showGlucoseUnitLabels = (d.object(forKey: "showGlucoseUnitLabels") as? Bool) ?? false
        showIOBAxis = (d.object(forKey: "showIOBAxis") as? Bool) ?? true
        showBolusBars = (d.object(forKey: "showBolusBars") as? Bool) ?? true
        // D-01/D-02/D-10: an absent/out-of-set stored bound (or a legacy/corrupt value) snaps to a
        // safe in-set pair via the single shared faBolusCore math — never assigned raw.
        let plotBounds = GlucosePlotScale.resolve(
            storedFloor: d.object(forKey: "glucosePlotFloor") as? Int,
            storedCeiling: d.object(forKey: "glucosePlotCeiling") as? Int)
        glucosePlotFloor = plotBounds.floor
        glucosePlotCeiling = plotBounds.ceiling
        // D-05: the pair is ONE unit — only treat it as "on" when BOTH halves are present on disk; a
        // partial/corrupt state (only one half persisted) falls back to nil ("Same as phone") rather
        // than a half-applied override. A present pair still snaps through the same shared math so a
        // legacy/out-of-set override value can never surface as an invalid Picker selection.
        if let sf = d.object(forKey: "glucosePlotFloorSmall") as? Int,
           let sc = d.object(forKey: "glucosePlotCeilingSmall") as? Int {
            let smallBounds = GlucosePlotScale.resolve(storedFloor: sf, storedCeiling: sc)
            glucosePlotFloorSmall = smallBounds.floor
            glucosePlotCeilingSmall = smallBounds.ceiling
        } else {
            glucosePlotFloorSmall = nil
            glucosePlotCeilingSmall = nil
        }
        showStats = (d.object(forKey: "showStats") as? Bool) ?? false
        // Phase 8 (08-01, LOCK-03): force-set 1 (24h — this field's unit is days, 0 = keep everything)
        // unconditionally — the retention Picker + the whole Data/History view are removed this phase;
        // a restored/legacy UserDefaults value carrying `0`/a longer window must not silently keep more
        // than 24h of glucose (Pitfall 1). Actually ENFORCED at launch via the new `App.swift`
        // `model.applyRetention(days:)` call site (Pitfall 2) — this pin alone is not self-applying.
        historyRetentionDays = 1
        // D-01: default ON — a fresh install (and any device with no stored value) auto-syncs.
        historySyncEnabled = (d.object(forKey: "historySyncEnabled") as? Bool) ?? true
        let hsAck = d.double(forKey: "historyLastSyncedAt")   // 0 (absent) ⇒ never synced
        historyLastSyncedAt = hsAck > 0 ? Date(timeIntervalSince1970: hsAck) : nil
        if let data = d.data(forKey: "historyCoverage"),
           let coverage = try? JSONDecoder().decode(HistoryCoverageMap.self, from: data) {
            historyCoverage = coverage
        } else {
            historyCoverage = HistoryCoverageMap()
        }
        eatingNudgesEnabled = (d.object(forKey: "eatingNudgesEnabled") as? Bool) ?? false
        // Phase 09.18b (D-09/D-17): HR chart context defaults ON, off-able.
        heartRateContextEnabled = (d.object(forKey: "heartRateContextEnabled") as? Bool) ?? true
        eatingLearnFromFeedback = (d.object(forKey: "eatingLearnFromFeedback") as? Bool) ?? true
        // Phase 09.15 (D-07) — locked defaults: state readouts + lockout countdown ON, the rest OFF.
        ciqStateReadoutsEnabled = (d.object(forKey: "ciqStateReadoutsEnabled") as? Bool) ?? true
        ciqLockoutCountdownEnabled = (d.object(forKey: "ciqLockoutCountdownEnabled") as? Bool) ?? true
        ciqMaxBasalReadoutEnabled = (d.object(forKey: "ciqMaxBasalReadoutEnabled") as? Bool) ?? false
        ciqSleepExerciseAwarenessEnabled = (d.object(forKey: "ciqSleepExerciseAwarenessEnabled") as? Bool) ?? false
        ciqPlusTempRateEnabled = (d.object(forKey: "ciqPlusTempRateEnabled") as? Bool) ?? false
        ciqCeilingFlagsEnabled = (d.object(forKey: "ciqCeilingFlagsEnabled") as? Bool) ?? false
        let sfAck = d.double(forKey: "smartFeaturesNoticeAckAt")   // 0 (absent) ⇒ never acknowledged
        smartFeaturesNoticeAckAt = sfAck > 0 ? Date(timeIntervalSince1970: sfAck) : nil
        if let data = d.data(forKey: "eatingTriggerConfig"),
           let cfg = try? JSONDecoder().decode(EatingTriggerConfig.self, from: data) {
            eatingTriggerConfig = cfg
        } else {
            eatingTriggerConfig = EatingTriggerConfig()
        }
        glucoseStaleMinutes = (d.object(forKey: "glucoseStaleMinutes") as? Int) ?? 6
        glucoseHideDelayMinutes = d.object(forKey: "glucoseHideDelayMinutes") as? Int    // nil = Never
        advancedControlEnabled = (d.object(forKey: "advancedControlEnabled") as? Bool) ?? false
        // Phase 8 (08-01, LOCK-01): force-set `.advanced` unconditionally — defense-in-depth belt-and-
        // suspenders alongside `ModeStore.init` (the primary/sole sanctioned writer). A restored/legacy
        // UserDefaults value carrying `.simple`/`.standard` must not silently downgrade the mode before
        // `ModeStore` runs (Pitfall 1).
        appMode = .advanced
        let ackTs = d.double(forKey: "clinicianTierAckAt")   // P14 S8: 0 (absent) ⇒ never acknowledged
        clinicianTierAckAt = ackTs > 0 ? Date(timeIntervalSince1970: ackTs) : nil
        let teAck = d.double(forKey: "therapyEditAckAt")     // B1(e): 0 (absent) ⇒ never acknowledged
        therapyEditAckAt = teAck > 0 ? Date(timeIntervalSince1970: teAck) : nil
        let wAck = d.double(forKey: "watchBolusWarningAckAt")   // §2.3: 0 (absent) ⇒ never acknowledged
        watchBolusWarningAckAt = wAck > 0 ? Date(timeIntervalSince1970: wAck) : nil
        let gAck = d.double(forKey: "garminBolusWarningAckAt")
        garminBolusWarningAckAt = gAck > 0 ? Date(timeIntervalSince1970: gAck) : nil
        let sgAck = d.double(forKey: "stackingGuardNoticeAckAt")   // FLAG-4: 0 (absent) ⇒ never acknowledged
        stackingGuardNoticeAckAt = sgAck > 0 ? Date(timeIntervalSince1970: sgAck) : nil
        phoneReadOnly = (d.object(forKey: "phoneReadOnly") as? Bool) ?? false
        readOnlyAllowAlertClear = (d.object(forKey: "readOnlyAllowAlertClear") as? Bool) ?? false
        remotesReadOnly = (d.object(forKey: "remotesReadOnly") as? Bool) ?? false
        // §2.3: both default OFF so a fresh install (and any device with no stored value) cannot bolus from a
        // remote until the user explicitly opts in.
        garminBolusEnabled = (d.object(forKey: "garminBolusEnabled") as? Bool) ?? false
        watchBolusEnabled = (d.object(forKey: "watchBolusEnabled") as? Bool) ?? false
        // §2.3: nil (absent, or a stored non-positive) ⇒ the ceiling is OFF; only a positive value arms it.
        let rbc = d.object(forKey: "remoteBolusCeiling") as? Double
        remoteBolusCeiling = (rbc.map { $0.isFinite && $0 > 0 } ?? false) ? rbc : nil
        // Phase 8 (08-01, LOCK-05): force-set OFF unconditionally — the pump-clock Settings/
        // PumpControlView UI is removed this phase, so no path exists to turn this back on; a
        // restored/legacy UserDefaults value carrying `true` must not silently re-arm it (Pitfall 1).
        autoSyncPumpTime = false
        autoExerciseMode = (d.object(forKey: "autoExerciseMode") as? Bool) ?? false
        autoSleepMode = (d.object(forKey: "autoSleepMode") as? Bool) ?? false
        modeReminders = (d.object(forKey: "modeReminders") as? Bool) ?? false
        suppressMirroredPumpAlarms = (d.object(forKey: "suppressMirroredPumpAlarms") as? Bool) ?? false
        // Phase 9 (09-04, MOBI-04, D-06): default explicit OFF for t:slim, DECOUPLED from
        // `PumpModelStore.isMobi()` (the old "ON for a Mobi" default now couples to a permanently-stale
        // flag — Mobi backends are removed this phase). The user can still opt in explicitly.
        criticalAlertsEnabled = (d.object(forKey: "criticalAlertsEnabled") as? Bool) ?? false
        // MOBI-04/D-06: one-time force-reset — a persisted `criticalAlertsEnabled == true` from a
        // pre-Phase-9 install (the old Mobi-derived default) is force-reset to the new uniform OFF
        // default EXACTLY ONCE, via this NEW dedicated idempotent-once guard key
        // (`criticalAlertsForceResetV050`), DISTINCT from the ordinary default-computation line above.
        // Guarded so a user's LATER re-enable (any launch after this migration has already fired once)
        // is never re-clobbered — the guard key, once set, is checked and never cleared. Does NOT
        // re-derive from `PumpModelStore.isMobi()` (stale) and is NOT reused for `advancedControlEnabled`
        // (that default needs no migration — RESEARCH Anti-Patterns). Both the property (for in-memory
        // consumers reading `criticalAlertsEnabled` immediately after `init`) and the raw UserDefaults key
        // (explicit write-through, independent of `didSet`'s init-timing subtlety) are set together.
        if d.object(forKey: "criticalAlertsForceResetV050") == nil {
            criticalAlertsEnabled = false
            d.set(false, forKey: "criticalAlertsEnabled")
            d.set(true, forKey: "criticalAlertsForceResetV050")
        }
        // Phase 7 (07-04, FEAT-04, D-05, SAFETY): requireRemoteBolusApproval is now a frozen-false
        // computed constant (get { false } set { } ) — no init-restore line needed; the old
        // UserDefaults value, if any, is simply never read again.
        // Phase 7 (07-05, FEAT-08, D-07, SAFETY): alertRules is now a frozen-empty computed constant
        // (get { [] } set { } ) — no init-restore line needed either; the old UserDefaults value, if
        // any, is simply never read again.
        nightscoutUploadEnabled = (d.object(forKey: "nightscoutUploadEnabled") as? Bool) ?? false
        // 09.23-02 (D-14/D-11b): every Apple Health import toggle — per-type + automatic — defaults
        // OFF, so a fresh install (and any device with no stored value) never silently imports.
        healthKitImportCarbsEnabled = (d.object(forKey: "healthKitImportCarbsEnabled") as? Bool) ?? false
        healthKitImportInsulinEnabled = (d.object(forKey: "healthKitImportInsulinEnabled") as? Bool) ?? false
        healthKitImportHeartRateEnabled = (d.object(forKey: "healthKitImportHeartRateEnabled") as? Bool) ?? false
        healthKitImportGlucoseEnabled = (d.object(forKey: "healthKitImportGlucoseEnabled") as? Bool) ?? false
        healthKitAutoImportEnabled = (d.object(forKey: "healthKitAutoImportEnabled") as? Bool) ?? false
        // 09.23-03 (D-08/D-12/D-14): every Apple Health EXPORT toggle — per-type + automatic —
        // defaults OFF, so a fresh install (and any device with no stored value) never silently
        // exports. No heart-rate export toggle exists (D-08).
        healthKitExportCarbsEnabled = (d.object(forKey: "healthKitExportCarbsEnabled") as? Bool) ?? false
        healthKitExportInsulinEnabled = (d.object(forKey: "healthKitExportInsulinEnabled") as? Bool) ?? false
        healthKitExportGlucoseEnabled = (d.object(forKey: "healthKitExportGlucoseEnabled") as? Bool) ?? false
        healthKitAutoExportEnabled = (d.object(forKey: "healthKitAutoExportEnabled") as? Bool) ?? false
        // Phase 8 (08-01, LOCK-04): force-set OFF unconditionally — the "Extended (combo) bolus" toggle
        // is removed this phase; a restored/legacy UserDefaults value carrying `true` must not silently
        // re-arm the (now-unreachable) `extendedBolusSection` UI (Pitfall 1).
        extendedBolusEnabled = false
        showBolusReasoning = (d.object(forKey: "showBolusReasoning") as? Bool) ?? true
        // Phase 8 (08-01, LOCK-06 friction half): force-set OFF unconditionally — the "Extra
        // confirmation on unusually large overrides" toggle is removed this phase; a restored/legacy
        // UserDefaults value carrying `true` must not silently re-arm it (Pitfall 1). This never
        // disables `StackingGuard.escalation`'s own disclosure computation (byte-identical,
        // `Packages/faBolusCore`) — only the UI wiring for the EXTRA confirmation/re-type step.
        stackingGuardFrictionEnabled = false
        // Phase 7 (07-04, FEAT-04, D-05, SAFETY): childModeEnabled is now a frozen-false computed
        // constant (get { false } set { } ) — no init-restore line needed; the old UserDefaults value,
        // if any, is simply never read again. `childAllowed` itself stays a real, settable property
        // (still read by AppModel's AccessContext builder + BolusEntryView's UI hint) — only the gate
        // that made its value matter is frozen.
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
        garminClockAnalog = (d.object(forKey: "garminClockAnalog") as? Bool) ?? false
        let gt = d.string(forKey: "garminTargetApp") ?? "beta"   // default to beta (official listing is dormant)
        garminTargetApp = (gt == "official") ? "official" : "beta"
        detailsOrder = Self.restoreOrder(d.array(forKey: "detailsOrder") as? [String], all: Self.detailFields)
        watchDetailsOrder = Self.restoreOrder(d.array(forKey: "watchDetailsOrder") as? [String], all: Self.detailFields)
        // Default to the original 6 pills (the full option set is larger); honor a saved selection.
        pillsOrder = Self.restoreOrder(d.array(forKey: "pillsOrder") as? [String] ?? Self.defaultPills, all: Self.pillItems)
        // SC-4 (fresh-install exit criterion, D-14): OFF by default — the app-icon badge is opt-in.
        glucoseBadgeEnabled = (d.object(forKey: "glucoseBadgeEnabled") as? Bool) ?? false
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
            // Phase 8 (08-01, LOCK-04/LOCK-06): `extendedBolusEnabled`/`stackingGuardFrictionEnabled` no
            // longer emitted into the backup snapshot either — their `SettingsCatalog` descriptors are
            // gone (the toggles' UI deleted, both are now force-set-false init pins), so
            // `SettingsCatalogTests.backedUpSetMatchesBackupSnapshot` requires this key drop too — same
            // hidden-flag posture as `autoSyncPumpTime` above.
            "showBolusReasoning": .bool(showBolusReasoning),
            "watchDefaultBolusMode": .string(watchDefaultBolusMode.rawValue),
            "watchBolusIncrement": .double(watchBolusIncrement),
            "watchCarbIncrement": .double(watchCarbIncrement),
            "showGlucoseAxis": .bool(showGlucoseAxis),
            // Phase 8 (08-01, LOCK-02): `glucoseDisplayUnit`/`showGlucoseUnitLabels` no longer emitted
            // into the backup snapshot either — their `SettingsCatalog` descriptors are gone (the unit
            // Picker + "Show unit labels" toggle UI deleted); `glucoseDisplayUnit` is now a force-set
            // `.mgdl` init pin, `showGlucoseUnitLabels` survives as an ordinary hidden/unregistered flag
            // (same hidden-flag posture as `autoSyncPumpTime`/`extendedBolusEnabled` above).
            "showIOBAxis": .bool(showIOBAxis),
            "showBolusBars": .bool(showBolusBars),
            "glucosePlotFloor": .int(glucosePlotFloor),
            "glucosePlotCeiling": .int(glucosePlotCeiling),
            "showStats": .bool(showStats),
            "detailsOrder": .stringArray(detailsOrder),
            "watchDetailsOrder": .stringArray(watchDetailsOrder),
            "pillsOrder": .stringArray(pillsOrder),
            "watchChartRanges": .intArray(watchChartRanges),
            "glucoseStaleMinutes": .int(glucoseStaleMinutes),
            // Phase 9 (09-02, MOBI-02): `advancedControlEnabled` no longer emitted into the backup
            // snapshot either — its `SettingsCatalog` descriptor is gone (the "Advanced control"
            // Settings toggle it fed is deleted); the accessor survives as an ordinary hidden/
            // unregistered flag (same posture as `showGlucoseUnitLabels` above, not a force-set pin).
            // Phase 8 (08-01, LOCK-05): `autoSyncPumpTime` no longer emitted into the backup snapshot
            // either — its `SettingsCatalog` descriptor is gone (pump-clock UI deleted, the property is
            // now a force-set-false init pin), so `SettingsCatalogTests.backedUpSetMatchesBackupSnapshot`
            // requires this key drop too — same hidden-flag posture as `watchBolusEnabled` above.
            // Phase 7 (07-03, FEAT-05, D-08): autoExerciseMode/autoSleepMode/modeReminders no longer
            // emitted here (frozen, hidden/unregistered); autoTempRate/autoProfileActivation deleted
            // outright (see applyBackup below for the matching restore-side removal).
            "phoneReadOnly": .bool(phoneReadOnly),
            "readOnlyAllowAlertClear": .bool(readOnlyAllowAlertClear),
            "remotesReadOnly": .bool(remotesReadOnly),
            "garminBolusEnabled": .bool(garminBolusEnabled),
            // Phase 3 (03-03, REMOTE-03): watchBolusEnabled is no longer emitted into the backup
            // snapshot (catalog row + backup participation removed, hidden-flag pattern) — same
            // posture as requireRemoteBolusApproval (see applyBackup below).
            "garminScreenOrder": .stringArray(garminScreenOrder),
            "garminDefaultScreen": .string(garminDefaultScreen),
            "garminComplicationDisplay": .string(garminComplicationDisplay),
            "garminClockAnalog": .bool(garminClockAnalog),
            "garminTargetApp": .string(garminTargetApp),
            // Phase 5 (05-02, HEALTH-02): nightscoutUploadEnabled is no longer emitted into the
            // backup snapshot (catalog row + backup participation removed, hidden-flag pattern) —
            // same posture as watchBolusEnabled/requireRemoteBolusApproval (see applyBackup below).
            // Phase 7 (07-04, FEAT-04, D-05, SAFETY): `childModeEnabled` is no longer emitted here
            // either — its `SettingsCatalog` descriptor was removed (Child Mode UI deleted, the
            // property itself is now a getter-level frozen constant), so
            // `SettingsCatalogTests.backedUpSetMatchesBackupSnapshot` requires this key drop too.
            // Phase 7 (07-02, FEAT-03): `glucoseBadgeEnabled` no longer emitted here — its
            // `SettingsCatalog` descriptor was removed (the badge is a main-only no-op stub now), so
            // `SettingsCatalogTests.backedUpSetMatchesBackupSnapshot` requires this key drop too.
            // Phase 4 (04-02, D-05/NUDGE-01): `siteAtlasEnabled` no longer emitted here — its
            // `SettingsCatalog` descriptor was removed (SC2, see the NOTE in SettingsCatalog.swift), so
            // `SettingsCatalogTests.backedUpSetMatchesBackupSnapshot` requires this key drop too. The
            // property itself still exists and still persists via `didSet`; it just no longer rides a
            // portable backup/restore.
        ]
        if let hide = glucoseHideDelayMinutes { m["glucoseHideDelayMinutes"] = .int(hide) }
        // §2.3: emitted only when the optional ceiling is armed (nil ⇒ off ⇒ omitted), like the hide delay.
        if let ceiling = remoteBolusCeiling { m["remoteBolusCeiling"] = .double(ceiling) }
        // D-05: the small-screen override pair — emitted only when set (nil ⇒ Same as phone ⇒ omitted).
        if let f = glucosePlotFloorSmall { m["glucosePlotFloorSmall"] = .int(f) }
        if let c = glucosePlotCeilingSmall { m["glucosePlotCeilingSmall"] = .int(c) }
        // Phase 7 (07-05, FEAT-08, D-07, SAFETY): `alertRules` is no longer emitted into the backup
        // snapshot either — its `SettingsCatalog` descriptor was removed (the editor UI is deleted;
        // the property itself is now a getter-level frozen constant), so
        // `SettingsCatalogTests.backedUpSetMatchesBackupSnapshot` requires this key drop too.
        // Phase 7 (07-04, FEAT-04, D-05, SAFETY): `childAllowed` is no longer emitted here either —
        // its `SettingsCatalog` descriptor was removed (Child Mode UI deleted; the value is already
        // access-irrelevant now that `childModeEnabled` is force-false), so
        // `SettingsCatalogTests.backedUpSetMatchesBackupSnapshot` requires this key drop too. The
        // property itself stays (still read by the frozen `AppModel.swift` AccessContext builder +
        // `BolusEntryView`'s UI hint, still persisted via `UserDefaults` `didSet`) — only its portable
        // backup participation is removed, same hidden-flag posture as `childModeEnabled` above.
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
        // VA-03: mirror init's `max(0.05, …)` clamp (init ~:669) so a restored/cross-version sub-pump-
        // minimum increment (e.g. a legacy 0.01) can't install a value absent from `bolusIncrements`
        // (empty Picker + sub-0.05 step) until the next relaunch.
        if let v = dbl("bolusIncrement") { bolusIncrement = max(0.05, v) }
        if let v = dbl("carbIncrement") { carbIncrement = v }
        // Phase 8 (08-01, LOCK-04/LOCK-06): `extendedBolusEnabled`/`stackingGuardFrictionEnabled` no
        // longer restore from a backup either — same hidden-flag pattern. A legacy backup carrying
        // `true` for either is silently ignored (same tolerance as `autoSyncPumpTime` above); the
        // force-set-false init pins would reject them on next launch regardless.
        if let v = b("showBolusReasoning") { showBolusReasoning = v }
        if let v = s("watchDefaultBolusMode"), let mode = BolusMode(rawValue: v) { watchDefaultBolusMode = mode }
        // VA-03: same `max(0.05, …)` clamp init applies (~:672).
        if let v = dbl("watchBolusIncrement") { watchBolusIncrement = max(0.05, v) }
        if let v = dbl("watchCarbIncrement") { watchCarbIncrement = v }
        if let v = b("showGlucoseAxis") { showGlucoseAxis = v }
        // Phase 8 (08-01, LOCK-02): `glucoseDisplayUnit`/`showGlucoseUnitLabels` no longer restore from
        // a backup either — same hidden-flag pattern. A legacy backup carrying "mmol"/`true` for either
        // is silently ignored; the force-set `.mgdl` init pin would reject the unit regardless.
        if let v = b("showIOBAxis") { showIOBAxis = v }
        if let v = b("showBolusBars") { showBolusBars = v }
        // VA-03: route restored plot bounds through the SAME `GlucosePlotScale.resolve` init uses
        // (~:690) so an inverted/out-of-set backup pair can't install invalid bounds (guarantees
        // floor < ceiling + in-set). When only one half is present, resolve against the current value
        // for the other so the "absent keys left unchanged" contract still holds for a fully-absent pair.
        if i("glucosePlotFloor") != nil || i("glucosePlotCeiling") != nil {
            let bounds = GlucosePlotScale.resolve(
                storedFloor: i("glucosePlotFloor") ?? glucosePlotFloor,
                storedCeiling: i("glucosePlotCeiling") ?? glucosePlotCeiling)
            glucosePlotFloor = bounds.floor
            glucosePlotCeiling = bounds.ceiling
        }
        // D-05: only apply the override when BOTH halves are present in the backup (same one-unit
        // treatment as init); a backup missing one half leaves the current override unchanged, per
        // applyBackup's documented "absent keys are left unchanged" contract. VA-03: snap the present
        // pair through `GlucosePlotScale.resolve` exactly as init does (~:701) — never assigned raw.
        if let f = i("glucosePlotFloorSmall"), let c = i("glucosePlotCeilingSmall") {
            let bounds = GlucosePlotScale.resolve(storedFloor: f, storedCeiling: c)
            glucosePlotFloorSmall = bounds.floor
            glucosePlotCeilingSmall = bounds.ceiling
        }
        if let v = b("showStats") { showStats = v }
        // VA-03: reuse the SAME `restoreOrder` / chart-range filter+sort init uses (~:852-860) so a
        // restored/cross-version list can't install unknown/duplicate/out-of-set entries until relaunch.
        if let v = sa("detailsOrder") { detailsOrder = Self.restoreOrder(v, all: Self.detailFields) }
        if let v = sa("watchDetailsOrder") { watchDetailsOrder = Self.restoreOrder(v, all: Self.detailFields) }
        if let v = sa("pillsOrder") { pillsOrder = Self.restoreOrder(v, all: Self.pillItems) }
        if let v = ia("watchChartRanges") {
            let filtered = v.filter { Self.chartRangeOptions.contains($0) }
            watchChartRanges = filtered.isEmpty ? Self.chartRangeOptions : filtered.sorted()
        }
        // VA-03 (dose-adjacent): clamp a restored `glucoseStaleMinutes` into the valid option range so a
        // corrupt/cross-version backup can't widen the "fresh glucose" correction window (the VA-01 stale
        // vector via the restore door) until the next relaunch.
        if let v = i("glucoseStaleMinutes") {
            glucoseStaleMinutes = min(max(v, Self.glucoseStaleOptions.min()!), Self.glucoseStaleOptions.max()!)
        }
        if let v = i("glucoseHideDelayMinutes") { glucoseHideDelayMinutes = v }
        // Phase 9 (09-02, MOBI-02): `advancedControlEnabled` no longer restores from a backup either —
        // same hidden-flag pattern. A legacy backup carrying `true` is silently ignored (the property's
        // only UI writer, the Settings toggle, is deleted, and `advancedControlAllowed` is already
        // always-false via its other operand regardless).
        // Phase 7 (07-03, FEAT-05, D-08): autoExerciseMode/autoSleepMode/modeReminders no longer
        // restore from a backup either (frozen, hidden/unregistered); autoTempRate/autoProfileActivation
        // deleted outright — same posture as watchBolusEnabled/requireRemoteBolusApproval above.
        // Phase 8 (08-01, LOCK-05): `autoSyncPumpTime` no longer restores from a backup either — same
        // hidden-flag pattern. A legacy backup carrying `true` is silently ignored (same tolerance as
        // the precedents above); the force-set-false init pin would reject it on next launch regardless,
        // but the restore line itself is removed too, closing both halves of the round trip.
        if let v = b("phoneReadOnly") { phoneReadOnly = v }
        if let v = b("readOnlyAllowAlertClear") { readOnlyAllowAlertClear = v }
        if let v = b("remotesReadOnly") { remotesReadOnly = v }
        if let v = b("garminBolusEnabled") { garminBolusEnabled = v }
        if let v = dbl("remoteBolusCeiling"), v > 0 { remoteBolusCeiling = v }   // §2.3: only a positive cap arms it
        // Phase 3 (03-02, F-1/Pitfall B): remoteBluetoothEnabled removed entirely (never read by
        // AppModel); requireRemoteBolusApproval no longer restores from a backup (its catalog row +
        // backup participation are removed, hidden-flag pattern) — a legacy backup carrying either key
        // is silently ignored here, same tolerance as the basalScheduleByHour/basalScheduleSource
        // precedent (restoreToleratesLegacyBasalScheduleKeys).
        // Phase 3 (03-03, REMOTE-03): watchBolusEnabled no longer restores from a backup either — same
        // hidden-flag pattern, same legacy-key tolerance.
        // Phase 5 (05-02, HEALTH-02): nightscoutUploadEnabled no longer restores from a backup
        // either — same hidden-flag pattern, same legacy-key tolerance.
        if let v = sa("garminScreenOrder") { garminScreenOrder = v }
        if let v = s("garminDefaultScreen") { garminDefaultScreen = v }
        if let v = s("garminComplicationDisplay") { garminComplicationDisplay = v }
        if let v = b("garminClockAnalog") { garminClockAnalog = v }
        if let v = s("garminTargetApp") { garminTargetApp = v }
        // Phase 7 (07-04, FEAT-04, D-05, SAFETY): `childModeEnabled` no longer restores from a backup
        // either — belt-and-suspenders option (a). A legacy backup carrying this key (or `true`) is
        // now silently ignored, same tolerance as the `remoteBluetoothEnabled`/`watchBolusEnabled`
        // precedents below; the getter-level freeze (option b, above) would reject the value anyway
        // even if this line still called the setter.
        // Phase 7 (07-02, FEAT-03): `glucoseBadgeEnabled` no longer restores from a backup either —
        // same hidden-flag pattern, same legacy-key tolerance (a restored `true` would have no effect
        // regardless, since `GlucoseBadge` is now a main-only no-op stub).
        // Phase 4 (04-02, D-05/NUDGE-01): `siteAtlasEnabled` no longer restores from a backup — same
        // removal as `backupSnapshot()` above. A legacy backup carrying this key is silently ignored
        // (same tolerance as the `remoteBluetoothEnabled`/`watchBolusEnabled` precedents above).
        // Phase 7 (07-05, FEAT-08, D-07, SAFETY): `alertRules` no longer restores from a backup
        // either — same hidden-flag pattern, same posture as `childModeEnabled` above. A legacy
        // backup carrying a non-empty rule-set is silently ignored (the getter-level freeze would
        // reject it regardless, but the restore line itself is removed too, closing both halves of
        // the round trip per D-07's belt-and-suspenders shape).
        // Phase 7 (07-04, FEAT-04, D-05, SAFETY): `childAllowed` no longer restores from a backup
        // either — same hidden-flag pattern, same posture as `childModeEnabled` above. A legacy backup
        // carrying this key is silently ignored (same tolerance as the `remoteBluetoothEnabled`/
        // `watchBolusEnabled` precedents above); the value is already access-irrelevant regardless
        // since `childModeEnabled` is force-false.
        applyFreshness(); syncWidgetConfig()
    }

    /// B4 (owner 2026-08-09) — reset the PUMP-SPECIFIC prefs to their off/default state on a pump switch,
    /// so one pump's automation/limits don't silently carry onto a different pump. Turns off the Control-IQ
    /// mode automation + reminders (Mobi-only closed-loop behavior), the first-connect pump-time-sync, and
    /// the advanced-control opt-in; drops the optional remote dose ceiling and any pump-alert auto-rules.
    /// Deliberately KEEPS display preferences, app mode, child/read-only, and CGM setup (pump-independent).
    /// Each assignment goes through the property's `didSet` so it persists + updates the live singleton.
    public func resetPumpRelevantSettings() {
        advancedControlEnabled = false
        autoSyncPumpTime = false
        autoSleepMode = false
        autoExerciseMode = false
        modeReminders = false
        remoteBolusCeiling = nil
        alertRules = []
    }
}
