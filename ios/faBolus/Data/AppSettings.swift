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

    /// Phase 09.18b (D-05/D-06/D-17): gate the GraphDetailView scrubbable readout overlay on the
    /// glucose chart. **Default ON** (a display-context convenience, off-able from the Smart Assist
    /// submenu); when off the chart renders exactly as today with no scrubber. Same persisted-Bool idiom
    /// as `eatingNudgesEnabled`. Deliberately a DEVICE-LOCAL display toggle — NOT a `SettingsCatalog`
    /// row and NOT in `backupSnapshot` (it gates a transient read-only overlay, carries no dose logic,
    /// and never rides a backup/iCloud round-trip), so the catalog drift guards stay untouched.
    public var graphDetailEnabled: Bool { didSet { d.set(graphDetailEnabled, forKey: "graphDetailEnabled") } }
    /// Phase 09.18b (D-07/D-09/D-17): gate heart-rate as GraphDetailView chart context. **Default ON**
    /// with the readout (D-17), independently off-able. When OFF (D-09): the phone stops the on-demand
    /// HealthKit HR query, the phone signals the watch to stop appending HR (`hr_ctl` off), and the HR
    /// readout row is HIDDEN ENTIRELY (not "—"). HR is chart context ONLY — never a dose/meal input.
    /// Device-local display toggle (same idiom as `graphDetailEnabled`): deliberately NOT a
    /// `SettingsCatalog` row and NOT in `backupSnapshot`, so the catalog drift guards stay untouched.
    public var heartRateContextEnabled: Bool { didSet { d.set(heartRateContextEnabled, forKey: "heartRateContextEnabled") } }
    /// Phase 09.18c-03 (D-12/D-13): master opt-in for the FoodFinder BYO-key AI carb-estimate path
    /// (photo/text → a user-connected AI provider). **Default OFF** — this is the ONLY FoodFinder path
    /// where PHI leaves the device, so it stays inert until the user explicitly enables it AND
    /// acknowledges the one-time PHI disclosure (`hasAcknowledgedFoodFinderAINotice`). AI-estimated carbs
    /// still reach the dose ONLY through the shared "Add to carbs" → `carbsText` seam — this flag never
    /// changes that. Device-local display/behavior toggle (same idiom as `graphDetailEnabled`):
    /// deliberately NOT a `SettingsCatalog` row and NOT in `backupSnapshot` (the BYO KEY rides the
    /// encrypted secrets backup instead, D-13), so the catalog drift guards stay untouched.
    public var foodFinderAIEnabled: Bool { didSet { d.set(foodFinderAIEnabled, forKey: "foodFinderAIEnabled") } }
    /// Phase 09.18d-01 (D-15/D-17): gate the LoopInsights endo-visit PDF report surface. **Default ON**
    /// — a benign records-export feature (glucose/insulin/carb summary rendered to a shareable PDF),
    /// discoverable and off-able from the Smart Assist submenu. Advisory only: the report is a summary
    /// of what already happened and never suggests/changes/blocks a dose (§13). Same device-local
    /// persisted-Bool idiom as `graphDetailEnabled` — deliberately NOT a `SettingsCatalog` row and NOT
    /// in `backupSnapshot` (it gates a read-only display surface, carries no dose logic), so the catalog
    /// drift guards stay untouched.
    public var endoReportEnabled: Bool { didSet { d.set(endoReportEnabled, forKey: "endoReportEnabled") } }
    /// Phase 09.18d-02 (D-14/D-17): gate the benign caffeine tracker log surface. **Default ON** — a
    /// standalone informational log (amount + time, surfaced alongside glucose), discoverable and
    /// off-able from the Smart Assist submenu. Never suggests/changes/blocks a dose (§13). Same
    /// device-local persisted-Bool idiom as `endoReportEnabled` — deliberately NOT a `SettingsCatalog`
    /// row and NOT in `backupSnapshot` (it gates a display surface, carries no dose logic), so the
    /// catalog drift guards stay untouched. (The logged ENTRIES ride the `trackers` backup section; this
    /// visibility flag does not.)
    public var caffeineTrackerEnabled: Bool { didSet { d.set(caffeineTrackerEnabled, forKey: "caffeineTrackerEnabled") } }
    /// Phase 09.18d-02 (D-14/D-17): gate the benign alcohol tracker log surface. **Default ON** — same
    /// standalone informational log + device-local idiom as `caffeineTrackerEnabled`. Never suggests/
    /// changes/blocks a dose, and carries NO delayed-hypo risk inference (D-14).
    public var alcoholTrackerEnabled: Bool { didSet { d.set(alcoholTrackerEnabled, forKey: "alcoholTrackerEnabled") } }
    /// Phase 09.18d-03 (D-14/D-17): gate the caregiver-digest PHI-sharing surface. **Default OFF** — the
    /// digest externalizes glucose + activity PHI to whoever the user shares with (the highest-exposure
    /// benign LoopInsights surface), and is AI-adjacent (D-17), so it stays inert until the user
    /// explicitly enables it AND acknowledges the one-time "About Smart Features" explainer
    /// (`hasAcknowledgedCaregiverDigestNotice`). The digest is a summary of what already happened — never
    /// advice, a directive, or a dose (§13). Same device-local persisted-Bool idiom as `endoReportEnabled`
    /// — deliberately NOT a `SettingsCatalog` row and NOT in `backupSnapshot` (it gates a read-only share
    /// surface, carries no dose logic), so the catalog drift guards stay untouched.
    public var caregiverDigestEnabled: Bool { didSet { d.set(caregiverDigestEnabled, forKey: "caregiverDigestEnabled") } }
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
    /// SiteAtlas infusion-site / CGM-sensor body-map tracker (09.18a, D-10/D-16/D-17). Advisory/
    /// display-only — never originates or gates a dose. Default **ON** (discoverable, D-17); unlike the
    /// `ciq*` flags this one is backup-participating (`SettingsCatalog`), so a restore preserves it.
    public var siteAtlasEnabled: Bool { didSet { d.set(siteAtlasEnabled, forKey: "siteAtlasEnabled") } }
    // One-time acknowledgment markers — same idiom as `stackingGuardNoticeAckAt`: durable per-install
    // markers, NOT `SettingsCatalog` rows — never backed up, never iCloud-synced (a synced ack must not
    // silently pre-suppress the notice on another device). NEVER gate a write. nil ⇒ never shown.
    public var ciqAwarenessNoticeAckAt: Date? { didSet { d.set(ciqAwarenessNoticeAckAt?.timeIntervalSince1970 ?? 0, forKey: "ciqAwarenessNoticeAckAt") } }
    public var hasAcknowledgedCiqAwarenessNotice: Bool { ciqAwarenessNoticeAckAt != nil }
    public func acknowledgeCiqAwarenessNotice() { if ciqAwarenessNoticeAckAt == nil { ciqAwarenessNoticeAckAt = Date() } }
    public var maxBasalNoticeAckAt: Date? { didSet { d.set(maxBasalNoticeAckAt?.timeIntervalSince1970 ?? 0, forKey: "maxBasalNoticeAckAt") } }
    public var hasAcknowledgedMaxBasalNotice: Bool { maxBasalNoticeAckAt != nil }
    public func acknowledgeMaxBasalNotice() { if maxBasalNoticeAckAt == nil { maxBasalNoticeAckAt = Date() } }
    // Generic "About Smart Features" one-time explainer (09.18a, D-16) — same durable per-install-marker
    // idiom as `ciqAwarenessNoticeAckAt`: NOT a `SettingsCatalog` row, never backed up / iCloud-synced (a
    // synced ack must not pre-suppress the notice on another device). Fired on first ENABLE of a Smart
    // Features surface (e.g. SiteAtlas). nil ⇒ never shown. NEVER gates a write.
    public var smartFeaturesNoticeAckAt: Date? { didSet { d.set(smartFeaturesNoticeAckAt?.timeIntervalSince1970 ?? 0, forKey: "smartFeaturesNoticeAckAt") } }
    public var hasAcknowledgedSmartFeaturesNotice: Bool { smartFeaturesNoticeAckAt != nil }
    public func acknowledgeSmartFeaturesNotice() { if smartFeaturesNoticeAckAt == nil { smartFeaturesNoticeAckAt = Date() } }
    // FoodFinder AI PHI disclosure (09.18c-03, D-13) — the one-time explainer that MUST be acknowledged
    // before the first AI call sends any PHI off-device. Same durable per-install-marker idiom as
    // `smartFeaturesNoticeAckAt`: NOT a `SettingsCatalog` row, never backed up / iCloud-synced (a synced
    // ack must not silently pre-suppress the PHI disclosure on another device). nil ⇒ never shown.
    public var foodFinderAINoticeAckAt: Date? { didSet { d.set(foodFinderAINoticeAckAt?.timeIntervalSince1970 ?? 0, forKey: "foodFinderAINoticeAckAt") } }
    public var hasAcknowledgedFoodFinderAINotice: Bool { foodFinderAINoticeAckAt != nil }
    public func acknowledgeFoodFinderAINotice() { if foodFinderAINoticeAckAt == nil { foodFinderAINoticeAckAt = Date() } }
    // Caregiver-digest one-time explainer (09.18d-03, D-14/D-17) — the "About Smart Features" notice fired
    // on first ENABLE of the caregiver digest (PHI-sharing, AI-adjacent). Same durable per-install-marker
    // idiom as `smartFeaturesNoticeAckAt`/`foodFinderAINoticeAckAt`: NOT a `SettingsCatalog` row, never
    // backed up / iCloud-synced (a synced ack must not silently pre-suppress the notice on another
    // device). nil ⇒ never shown. NEVER gates a write / a share.
    public var caregiverDigestNoticeAckAt: Date? { didSet { d.set(caregiverDigestNoticeAckAt?.timeIntervalSince1970 ?? 0, forKey: "caregiverDigestNoticeAckAt") } }
    public var hasAcknowledgedCaregiverDigestNotice: Bool { caregiverDigestNoticeAckAt != nil }
    public func acknowledgeCaregiverDigestNotice() { if caregiverDigestNoticeAckAt == nil { caregiverDigestNoticeAckAt = Date() } }

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
    /// **Auto temp rate** (999.2, D-01) — permits `SetTempRateIntent` (a Shortcuts action, NOT a Siri
    /// phrase) to set a temporary basal rate via `TempRateAutomation`. **Default OFF.** Even when ON,
    /// the intent stays functionally inert until BOTH the pump-derived `supportsTempBasal` capability
    /// AND the Phase-11 saline-bench flag (`TempRateAutomation.benchVerifiedDefault`) clear (D-03).
    public var autoTempRate: Bool { didSet { d.set(autoTempRate, forKey: "autoTempRate") } }
    /// **Auto profile activation** (999.2, D-02) — permits `ActivateProfileIntent` (a Shortcuts action,
    /// NOT a Siri phrase) to switch the active Personal Profile via `ProfileAutomation`. **Default OFF.**
    /// Even when ON, `setActiveProfile` is gated `.unverifiedAck` (AccessPolicy.swift:229-232) — a
    /// headless Shortcuts run can NEVER supply the required live in-app acknowledgment, so this permit
    /// only ever matters for a Shortcut that opens the app first and lets the user confirm interactively
    /// (D-02; the `.unverifiedAck` gate is NOT weakened for this toggle). Also gated on the pump-derived
    /// `supportsProfiles` capability AND the Phase-11 saline-bench flag
    /// (`ProfileAutomation.profileBenchVerifiedDefault`), mirroring `autoTempRate` (D-03).
    public var autoProfileActivation: Bool { didSet { d.set(autoProfileActivation, forKey: "autoProfileActivation") } }

    /// §6/S8 B6: opt-out — suppress the APP's re-notification of pump ALARMS (`PumpAlert.kind == .alarm`),
    /// which the pump itself already annunciates audibly (esp. relevant on a t:slim, where the alarm sounds
    /// on the pump). **Default OFF**; enabling it is behind a warning + explicit confirm (safety-reducing).
    /// It NEVER touches the app-only never-suppressible safety trio (pump disconnect / CGM data loss /
    /// bolus reconciliation) — those post on separate paths. A LOCAL device pref: deliberately NOT backed
    /// up and NOT iCloud-synced (a synced value must not silently silence alarms on another device).
    public var suppressMirroredPumpAlarms: Bool { didSet { d.set(suppressMirroredPumpAlarms, forKey: "suppressMirroredPumpAlarms") } }
    /// §6/S8 B6: use iOS **Critical Alerts** (which alert even under Do Not Disturb / the ringer switch)
    /// for the never-suppressible safety notifications — WHEN the app holds the critical-alerts entitlement;
    /// it degrades gracefully to a normal notification when the entitlement isn't granted. Defaults **ON for
    /// a Mobi** (screenless — the phone is the primary annunciator) and OFF otherwise, until the user sets
    /// it explicitly. Local device pref: not backed up / iCloud-synced.
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
    /// approver (Mac remote, iPhone-peer remote) are removed from narrow `main`, so this can never take
    /// effect again (`hasPairedRemote` in the frozen `AppModel.swift:1914` is now permanently false).
    /// This accessor STAYS — the frozen `AppModel.swift:1871` still reads it — but its
    /// `SettingsCatalog` row + backup/restore participation + `ChildModeView` UI are removed (hidden,
    /// unregistered flag; same pattern as `watchBolusEnabled`'s eventual removal). See
    /// 03-OWNER-FLAGS.md F-1.
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

    /// Phase 09.23-02 (D-14): per-type Apple Health IMPORT toggles — each import type (carbs,
    /// insulin/bolus, heart rate, glucose gap-fill) is individually user-selectable. All **default
    /// OFF** — a fresh install imports nothing until the user explicitly turns on each type. Gates
    /// BOTH the per-type HealthKit read-authorization request AND the ingest path
    /// (`AppModel.importFromAppleHealth`, D-13-gated). Deliberately NOT wrapped in
    /// `#if FABOLUS_HEALTHKIT` (unlike the AppModel import hook) — the settings MODEL stays
    /// unconditional so it compiles/tests under the default OFF build; only the FEATURE REACH (the
    /// actual HealthKit calls) is gated. Same device-local persisted-Bool idiom as
    /// `heartRateContextEnabled`/`caffeineTrackerEnabled`: deliberately NOT a `SettingsCatalog` row
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

    /// Child (locked) mode: a PIN-protected mode a parent enables on a child's device. When on, only
    /// the features in `childAllowed` are permitted; everything that dispenses insulin is blocked by
    /// default. The PIN hash lives in the Keychain ([[ChildMode]]), not here.
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

    public var childModeEnabled: Bool { didSet { d.set(childModeEnabled, forKey: "childModeEnabled") } }
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
    /// Phase 5 (D-15) — master opt-in for the ambient glucose Live Activity / Dynamic Island. **Default
    /// OFF** (opt-in, not opt-out — matches every other device-capability switch in this file). The
    /// manager AND-gates activity start on `liveActivityEnabled && ActivityAuthorizationInfo()
    /// .areActivitiesEnabled` (`GlucoseLiveActivityManager.gateEnabled`); flipping this off ends any
    /// running Activity. `didSet` also force-pushes an immediate refresh (`refreshForSelectionChange`,
    /// added in 05-04 Task 2) so a toggle applies at once rather than waiting for the next pump
    /// reading (pump-surface research §2b). Backed up, but **not** iCloud-synced (`SettingsCatalog`
    /// `syncsToICloud: false`) — an always-on-screen Lock Screen surface is a per-device opt-in, so
    /// enabling it here must never silently switch it on for this owner on another device.
    public var liveActivityEnabled: Bool {
        didSet {
            d.set(liveActivityEnabled, forKey: "liveActivityEnabled")
            syncWidgetConfig()
            GlucoseLiveActivityManager.refreshForSelectionChange()
        }
    }
    /// Phase 5 (D-15/D-17a) — which Live Activity fields show, and in what order. Same reorder+hide
    /// pattern as `pillsOrder`: `restoreOrder` drops unknown/duplicate ids, preserves stored order, and
    /// falls back to the FULL LA vocabulary if the stored list is empty or absent — never leaves the
    /// setting itself empty (same guarantee `pillsOrder` gives). The adaptive composer
    /// (`LiveActivityComposer.compose`, 05-04 Task 2) still carries its own independent 0-field
    /// empty-selection fallback as a defensive belt-and-suspenders for the App-Group mirror path
    /// (`WidgetStore.liveActivityFields`), which is a separate nilable copy that can legitimately be
    /// absent before the first `syncWidgetConfig()` call. `didSet` also force-pushes an immediate
    /// refresh (`refreshForSelectionChange`) so a reorder/hide change applies at once. Backed up, but
    /// **not** iCloud-synced (same per-device ambient-surface reasoning as `liveActivityEnabled`).
    public var liveActivityFields: [String] {
        didSet {
            d.set(liveActivityFields, forKey: "liveActivityFields")
            syncWidgetConfig()
            GlucoseLiveActivityManager.refreshForSelectionChange()
        }
    }
    /// Phase 09.26 tracer (D-21) — the Live Activity STYLE: `"fullBleed"` (new default, the edge-to-
    /// edge zone-colored plot) or `"classic"` (today's chip HUD, unchanged). Additive, same per-device
    /// ambient-surface reasoning as `liveActivityEnabled`/`liveActivityFields` — `didSet` mirrors +
    /// force-refreshes exactly like those two, so a style change applies at once rather than waiting
    /// for the next pump reading. Backed up, but **not** iCloud-synced (`SettingsCatalog`
    /// `syncsToICloud: false`) — a Lock Screen presentation choice is a per-device decision.
    public var liveActivityStyle: String {
        didSet {
            d.set(liveActivityStyle, forKey: "liveActivityStyle")
            syncWidgetConfig()
            GlucoseLiveActivityManager.refreshForSelectionChange()
        }
    }
    /// Phase 09.26-02 (D-15) — the full-bleed style's user-selectable top-right slot content. "iobDelta"
    /// (IOB + 30-min trend delta) is the default. Additive, same per-device ambient-surface reasoning
    /// as `liveActivityStyle` — `didSet` mirrors + force-refreshes. Backed up, but **not** iCloud-synced
    /// (`SettingsCatalog` `syncsToICloud: false`).
    public var liveActivityTopRightField: String {
        didSet {
            d.set(liveActivityTopRightField, forKey: "liveActivityTopRightField")
            syncWidgetConfig()
            GlucoseLiveActivityManager.refreshForSelectionChange()
        }
    }
    /// The valid `liveActivityTopRightField` tokens (Settings Picker options + init/restore's
    /// unrecognized-token fallback) — pinned here so the two can never drift apart. Mirrors
    /// `LATopRightFieldVocabulary.all` (`Shared/LiveActivityShared.swift`, which must not link
    /// `AppSettings`) — kept in sync by inspection, same precedent as `laFieldItems`/`LAFieldVocabulary`.
    public static let liveActivityTopRightFieldOptions: [String] =
        ["iobDelta", "iob", "delta", "tir", "controlIQZone", "battery", "reservoir", "none"]

    /// Phase 09.26-02 (D-14) — the full-bleed Live Activity's OWN plot time-range (hours), INDEPENDENT
    /// of the watch/phone chart's own range settings. Default 2h (the current `recentPoints` window
    /// needs no new data); 6h is offered in the Picker but degrades gracefully to whatever history is
    /// actually available until a future plan adds the wider snapshot window (D-14 scope note in
    /// `09.26-02-PLAN.md`'s `<safety>`). Additive, same per-device ambient-surface reasoning as
    /// `liveActivityStyle`.
    public var liveActivityPlotRangeHours: Int {
        didSet {
            d.set(liveActivityPlotRangeHours, forKey: "liveActivityPlotRangeHours")
            syncWidgetConfig()
            GlucoseLiveActivityManager.refreshForSelectionChange()
        }
    }
    public static let liveActivityPlotRangeHoursOptions: [Int] = [2, 6]

    /// Phase 09.26-02 (D-18) — optional full-bleed plot chrome, each an INDEPENDENT toggle (X-axis
    /// line / Y-axis line / X-axis ticks / Y-axis ticks — four separate settings, never one packed
    /// flag). **Default OFF** for all four (the clean full-bleed look the owner approved) — see
    /// `09.26-UI-SPEC.md`'s "Zone-Colored Curve — Rendering Contract" #6. Additive, same per-device
    /// ambient-surface reasoning as `liveActivityStyle`.
    public var liveActivityShowXAxisLine: Bool {
        didSet {
            d.set(liveActivityShowXAxisLine, forKey: "liveActivityShowXAxisLine")
            syncWidgetConfig()
            GlucoseLiveActivityManager.refreshForSelectionChange()
        }
    }
    public var liveActivityShowYAxisLine: Bool {
        didSet {
            d.set(liveActivityShowYAxisLine, forKey: "liveActivityShowYAxisLine")
            syncWidgetConfig()
            GlucoseLiveActivityManager.refreshForSelectionChange()
        }
    }
    public var liveActivityShowXAxisTicks: Bool {
        didSet {
            d.set(liveActivityShowXAxisTicks, forKey: "liveActivityShowXAxisTicks")
            syncWidgetConfig()
            GlucoseLiveActivityManager.refreshForSelectionChange()
        }
    }
    public var liveActivityShowYAxisTicks: Bool {
        didSet {
            d.set(liveActivityShowYAxisTicks, forKey: "liveActivityShowYAxisTicks")
            syncWidgetConfig()
            GlucoseLiveActivityManager.refreshForSelectionChange()
        }
    }
    /// Phase 09.26-02 (D-19) — the high/low target-range dashed reference-line toggle, replacing the
    /// old hard in-range band. **Default OFF**. Same additive/per-device reasoning as the axis toggles
    /// above.
    public var liveActivityShowRangeLines: Bool {
        didSet {
            d.set(liveActivityShowRangeLines, forKey: "liveActivityShowRangeLines")
            syncWidgetConfig()
            GlucoseLiveActivityManager.refreshForSelectionChange()
        }
    }
    /// Phase 09.26-07 (D-22) — the optional nav-only "Bolus" shortcut pill on the full-bleed Live
    /// Activity's Lock Screen expanded + Dynamic Island expanded. **Default OFF**. Same additive/
    /// per-device ambient-surface reasoning as the axis/range-line toggles above — NOT iCloud-synced.
    /// The pill reuses the EXISTING nav-only `LAOpenBolusIntent` (zero `@Parameter`,
    /// `openAppWhenRun=true`) — it never carries a dose/carb.
    public var liveActivityShowBolusShortcut: Bool {
        didSet {
            d.set(liveActivityShowBolusShortcut, forKey: "liveActivityShowBolusShortcut")
            syncWidgetConfig()
            GlucoseLiveActivityManager.refreshForSelectionChange()
        }
    }
    /// Phase 5 (D-13/D-14, 05-03; UI reachability + unit-awareness closed in 05-06/WR-01/CR-01) —
    /// master opt-in for the app-icon glucose badge. **Default OFF** (opt-in, matching every other
    /// device-capability switch in this file). Reachable via the "Glucose badge" toggle in Display &
    /// chart Settings. The badge can show only a bare number (no units/age/trend; in mmol/L it rounds
    /// to the nearest whole number — `GlucoseBadge.value(for:now:)`'s CR-01 fix) and is set from
    /// `GlucoseBadge.apply(_:now:)`, which is itself a pure function of freshness — never a frozen last
    /// value (D-13). `didSet` clears the app-icon badge the instant this is toggled OFF, so a disabled
    /// badge never lingers showing a stale number. Backed up, but **not** iCloud-synced (same per-device
    /// ambient-surface reasoning as `liveActivityEnabled` — a home-screen badge opt-in should not silently
    /// light up on another device).
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
        ["iob", "reservoir", "battery", "cgm", "basal", "controlIQ", "ciqZone", "lastBolus", "carbRatio", "isf", "target", "maxBolus", "cob"]
    public static func pillLabel(_ id: String) -> String {
        switch id {
        case "iob": return "Active insulin"
        case "reservoir": return "Reservoir"
        case "battery": return "Pump battery"
        case "cgm": return "CGM"
        case "basal": return "Basal / Suspended"
        case "controlIQ": return "Control-IQ"
        case "ciqZone": return "Control-IQ state"
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

    /// Phase 5 (D-15/D-17a) — the full Live Activity field vocabulary, in the default clinical-salience
    /// priority order (05-UI-SPEC.md Surface Inventory: glucose → IOB → connection-when-down →
    /// basal/Control-IQ → reservoir → battery). Users may reorder via Settings; the adaptive composer
    /// always walks the CURRENT (persisted) order, never this default order, once the user has customized.
    /// "connection" is itself a selectable field — the composer shows it only when the pump link is
    /// down/stale (never as a redundant "all fine" confirmation), so it is last by default rather than
    /// third as the raw clinical-priority text reads.
    // Phase 09.26-03 (D-13, UI-SPEC "New Field Vocabulary"): "delta"/"tir" appended — opt-in (off by
    // default, same "kept in sync by inspection" precedent as `LAFieldVocabulary.all`), usable in the
    // full-bleed style's bottom customizable row.
    public static let laFieldItems: [String] =
        ["glucose", "iob", "reservoir", "battery", "basal", "controlIQ", "controlIQZone", "connection", "delta", "tir"]
    public static func laFieldLabel(_ id: String) -> String {
        switch id {
        case "glucose": return "Glucose"
        case "iob": return "Active insulin"
        case "reservoir": return "Reservoir"
        case "battery": return "Pump battery"
        case "basal": return "Basal / Suspended"
        case "controlIQ": return "Control-IQ"
        case "controlIQZone": return "Control-IQ state"
        case "connection": return "Connection / last sync"
        case "delta": return "Trend delta"
        case "tir": return "Time in range"
        default: return id
        }
    }
    /// LA fields shown on a fresh install: glucose-led (D-15 — glucose is "the LA's reason to exist,"
    /// pump-surface research §2c), plus IOB and basal as the strongest faBolus-differentiator pump
    /// fields. Deliberately a SUBSET, not the full vocabulary — mirrors `defaultPills`'s "curated
    /// starter set" precedent rather than `pillItems`'s "show everything" one.
    public static let defaultLiveActivityFields: [String] = ["glucose", "iob", "basal"]
    /// The watch history-chart tap-through ranges available to enable.
    public static let chartRangeOptions: [Int] = [3, 6, 12, 24]

    /// Restore a reorder/hide list: keep stored ids that are known + unique, in stored order; fall
    /// back to the full list if nothing valid is stored (never leave the surface empty) — UNLESS
    /// `emptyMeansEmpty` is true AND a value was actually persisted (`stored != nil`), in which case a
    /// persisted `[]` is honored as an explicit empty selection rather than collapsed back to `all`.
    /// (Phase 09.14, D-01/WR-04 — `liveActivityFields` opts in; `detailsOrder`/`watchDetailsOrder`/
    /// `pillsOrder` keep the default `false` and are unaffected, pinned by
    /// `LiveActivityFieldsRestoreOrderTests`'s 3 named non-regression tests.) A genuinely-absent key
    /// (`stored == nil`) ALWAYS falls back to `all`, regardless of `emptyMeansEmpty`.
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
        // Phase 5 (D-15/D-17a): mirror the current field selection to the App Group so
        // `GlucoseLiveActivityManager.makeContent` can bake it into `ContentState` — the extension's
        // SwiftUI views never observe App-Group changes directly (pump-surface research §2b).
        WidgetStore.liveActivityFields = liveActivityFields
        // Phase 09.26 tracer (D-11/D-21/D-02/D-03): mirror the style + plot bounds so
        // `GlucoseLiveActivityManager.makeContent` can bake them into `ContentState` — same
        // App-Group-mirror rationale as `liveActivityFields` above.
        WidgetStore.liveActivityStyle = liveActivityStyle
        WidgetStore.liveActivityPlotFloor = glucosePlotFloor
        WidgetStore.liveActivityPlotCeiling = glucosePlotCeiling
        // Phase 09.26-02 (D-15/D-18/D-19): mirror the full-bleed display settings — same App-Group-
        // mirror rationale as the style/bounds mirrors above.
        WidgetStore.liveActivityTopRightField = liveActivityTopRightField
        WidgetStore.liveActivityPlotRangeHours = liveActivityPlotRangeHours
        WidgetStore.liveActivityShowXAxisLine = liveActivityShowXAxisLine
        WidgetStore.liveActivityShowYAxisLine = liveActivityShowYAxisLine
        WidgetStore.liveActivityShowXAxisTicks = liveActivityShowXAxisTicks
        WidgetStore.liveActivityShowYAxisTicks = liveActivityShowYAxisTicks
        WidgetStore.liveActivityShowRangeLines = liveActivityShowRangeLines
        // Phase 09.26-07 (D-22): mirror the optional Bolus-shortcut toggle — same App-Group-mirror
        // rationale as the axis/range-line mirrors above.
        WidgetStore.liveActivityShowBolusShortcut = liveActivityShowBolusShortcut
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
        // D-03: default mg/dL (behavior-preserving); an unrecognized/absent stored token also falls
        // back to mg/dL (fail-closed to the pre-existing display, never to an unexpected unit).
        glucoseDisplayUnit = GlucoseUnit(rawValue: d.string(forKey: "glucoseDisplayUnit") ?? "mgdl") ?? .mgdl
        // Owner request: default OFF (labels hidden on ambient surfaces) for a fresh install / absent key.
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
        historyRetentionDays = (d.object(forKey: "historyRetentionDays") as? Int) ?? 0
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
        // Phase 09.18b (D-17): default ON — a fresh install (and any device with no stored value)
        // gets the scrubbable readout, discoverable and off-able from Smart Assist.
        graphDetailEnabled = (d.object(forKey: "graphDetailEnabled") as? Bool) ?? true
        // Phase 09.18b (D-09/D-17): HR chart context defaults ON with GraphDetailView, off-able.
        heartRateContextEnabled = (d.object(forKey: "heartRateContextEnabled") as? Bool) ?? true
        // Phase 09.18c-03 (D-13): the FoodFinder AI path is OFF by default (PHI leaves the device only
        // here) — a fresh install / absent key never enables it silently.
        foodFinderAIEnabled = (d.object(forKey: "foodFinderAIEnabled") as? Bool) ?? false
        // Phase 09.18d-01 (D-15/D-17): the endo-report PDF is discoverable / ON by default.
        endoReportEnabled = (d.object(forKey: "endoReportEnabled") as? Bool) ?? true
        // Phase 09.18d-02 (D-14/D-17): the benign caffeine + alcohol trackers are discoverable / ON by default.
        caffeineTrackerEnabled = (d.object(forKey: "caffeineTrackerEnabled") as? Bool) ?? true
        alcoholTrackerEnabled = (d.object(forKey: "alcoholTrackerEnabled") as? Bool) ?? true
        // Phase 09.18d-03 (D-14/D-17): the caregiver digest is OFF by default (PHI leaves the device on
        // share; AI-adjacent) — a fresh install / absent key never enables it silently.
        caregiverDigestEnabled = (d.object(forKey: "caregiverDigestEnabled") as? Bool) ?? false
        eatingLearnFromFeedback = (d.object(forKey: "eatingLearnFromFeedback") as? Bool) ?? true
        // Phase 09.15 (D-07) — locked defaults: state readouts + lockout countdown ON, the rest OFF.
        ciqStateReadoutsEnabled = (d.object(forKey: "ciqStateReadoutsEnabled") as? Bool) ?? true
        ciqLockoutCountdownEnabled = (d.object(forKey: "ciqLockoutCountdownEnabled") as? Bool) ?? true
        ciqMaxBasalReadoutEnabled = (d.object(forKey: "ciqMaxBasalReadoutEnabled") as? Bool) ?? false
        ciqSleepExerciseAwarenessEnabled = (d.object(forKey: "ciqSleepExerciseAwarenessEnabled") as? Bool) ?? false
        ciqPlusTempRateEnabled = (d.object(forKey: "ciqPlusTempRateEnabled") as? Bool) ?? false
        ciqCeilingFlagsEnabled = (d.object(forKey: "ciqCeilingFlagsEnabled") as? Bool) ?? false
        // 09.18a (D-17): SiteAtlas is discoverable / ON by default.
        siteAtlasEnabled = (d.object(forKey: "siteAtlasEnabled") as? Bool) ?? true
        let ciqAck = d.double(forKey: "ciqAwarenessNoticeAckAt")   // 0 (absent) ⇒ never acknowledged
        ciqAwarenessNoticeAckAt = ciqAck > 0 ? Date(timeIntervalSince1970: ciqAck) : nil
        let mbAck = d.double(forKey: "maxBasalNoticeAckAt")        // 0 (absent) ⇒ never acknowledged
        maxBasalNoticeAckAt = mbAck > 0 ? Date(timeIntervalSince1970: mbAck) : nil
        let sfAck = d.double(forKey: "smartFeaturesNoticeAckAt")   // 0 (absent) ⇒ never acknowledged
        smartFeaturesNoticeAckAt = sfAck > 0 ? Date(timeIntervalSince1970: sfAck) : nil
        let ffAck = d.double(forKey: "foodFinderAINoticeAckAt")    // 0 (absent) ⇒ never acknowledged
        foodFinderAINoticeAckAt = ffAck > 0 ? Date(timeIntervalSince1970: ffAck) : nil
        let cdAck = d.double(forKey: "caregiverDigestNoticeAckAt") // 0 (absent) ⇒ never acknowledged
        caregiverDigestNoticeAckAt = cdAck > 0 ? Date(timeIntervalSince1970: cdAck) : nil
        if let data = d.data(forKey: "eatingTriggerConfig"),
           let cfg = try? JSONDecoder().decode(EatingTriggerConfig.self, from: data) {
            eatingTriggerConfig = cfg
        } else {
            eatingTriggerConfig = EatingTriggerConfig()
        }
        glucoseStaleMinutes = (d.object(forKey: "glucoseStaleMinutes") as? Int) ?? 6
        glucoseHideDelayMinutes = d.object(forKey: "glucoseHideDelayMinutes") as? Int    // nil = Never
        advancedControlEnabled = (d.object(forKey: "advancedControlEnabled") as? Bool) ?? false
        // P14 S2: default Advanced (behavior-preserving no-op); S3 flips the default to Simple + Objectives.
        appMode = AppMode(rawValue: d.string(forKey: "appMode") ?? "") ?? .advanced
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
        // P15 E2 exit criterion: default OFF so a first connect never silently writes the pump clock
        // without an explicit opt-in. NOT re-coupled to advancedControlEnabled.
        autoSyncPumpTime = (d.object(forKey: "autoSyncPumpTime") as? Bool) ?? false
        autoExerciseMode = (d.object(forKey: "autoExerciseMode") as? Bool) ?? false
        autoSleepMode = (d.object(forKey: "autoSleepMode") as? Bool) ?? false
        modeReminders = (d.object(forKey: "modeReminders") as? Bool) ?? false
        autoTempRate = (d.object(forKey: "autoTempRate") as? Bool) ?? false
        autoProfileActivation = (d.object(forKey: "autoProfileActivation") as? Bool) ?? false
        suppressMirroredPumpAlarms = (d.object(forKey: "suppressMirroredPumpAlarms") as? Bool) ?? false
        // B6: default ON for a Mobi (screenless ⇒ phone is the primary annunciator), else OFF — until set.
        criticalAlertsEnabled = (d.object(forKey: "criticalAlertsEnabled") as? Bool) ?? (PumpModelStore.isMobi() == true)
        requireRemoteBolusApproval = (d.object(forKey: "requireRemoteBolusApproval") as? Bool) ?? false
        alertRules = d.data(forKey: "alertRules").flatMap { try? JSONDecoder().decode([AlertRule].self, from: $0) } ?? []
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
        extendedBolusEnabled = (d.object(forKey: "extendedBolusEnabled") as? Bool) ?? false
        showBolusReasoning = (d.object(forKey: "showBolusReasoning") as? Bool) ?? true
        stackingGuardFrictionEnabled = (d.object(forKey: "stackingGuardFrictionEnabled") as? Bool) ?? true
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
        garminClockAnalog = (d.object(forKey: "garminClockAnalog") as? Bool) ?? false
        let gt = d.string(forKey: "garminTargetApp") ?? "beta"   // default to beta (official listing is dormant)
        garminTargetApp = (gt == "official") ? "official" : "beta"
        detailsOrder = Self.restoreOrder(d.array(forKey: "detailsOrder") as? [String], all: Self.detailFields)
        watchDetailsOrder = Self.restoreOrder(d.array(forKey: "watchDetailsOrder") as? [String], all: Self.detailFields)
        // Default to the original 6 pills (the full option set is larger); honor a saved selection.
        pillsOrder = Self.restoreOrder(d.array(forKey: "pillsOrder") as? [String] ?? Self.defaultPills, all: Self.pillItems)
        // SC-4 (fresh-install exit criterion): OFF by default; a not-yet-set install falls back to the
        // curated glucose-led subset, sanitized the same way pillsOrder is.
        liveActivityEnabled = (d.object(forKey: "liveActivityEnabled") as? Bool) ?? false
        liveActivityFields = Self.restoreOrder(
            d.array(forKey: "liveActivityFields") as? [String] ?? Self.defaultLiveActivityFields,
            all: Self.laFieldItems, emptyMeansEmpty: true)
        // Phase 09.26 tracer (D-21): default "fullBleed" for a fresh install/not-yet-set key; an
        // unrecognized persisted token (a downgrade scenario, or corrupt defaults) also falls back to
        // "fullBleed" rather than carrying an invalid string forward.
        let storedStyle = d.string(forKey: "liveActivityStyle")
        liveActivityStyle = (storedStyle == "classic") ? "classic" : "fullBleed"
        // Phase 09.26-02 (D-15): default "iobDelta" for a fresh install/not-yet-set key; an
        // unrecognized persisted token (a downgrade, or a value from a build with a since-removed
        // option) also falls back to "iobDelta" rather than carrying an invalid string forward.
        let storedTopRightField = d.string(forKey: "liveActivityTopRightField")
        liveActivityTopRightField = Self.liveActivityTopRightFieldOptions.contains(storedTopRightField ?? "")
            ? storedTopRightField! : "iobDelta"
        // Phase 09.26-02 (D-14): default 2h; an unrecognized persisted value (not in the option set)
        // also falls back to 2h.
        let storedPlotRangeHours = d.object(forKey: "liveActivityPlotRangeHours") as? Int
        liveActivityPlotRangeHours = Self.liveActivityPlotRangeHoursOptions.contains(storedPlotRangeHours ?? 0)
            ? storedPlotRangeHours! : 2
        // Phase 09.26-02 (D-18/D-19): all default OFF (the clean full-bleed look).
        liveActivityShowXAxisLine = (d.object(forKey: "liveActivityShowXAxisLine") as? Bool) ?? false
        liveActivityShowYAxisLine = (d.object(forKey: "liveActivityShowYAxisLine") as? Bool) ?? false
        liveActivityShowXAxisTicks = (d.object(forKey: "liveActivityShowXAxisTicks") as? Bool) ?? false
        liveActivityShowYAxisTicks = (d.object(forKey: "liveActivityShowYAxisTicks") as? Bool) ?? false
        liveActivityShowRangeLines = (d.object(forKey: "liveActivityShowRangeLines") as? Bool) ?? false
        // Phase 09.26-07 (D-22): default OFF — the Bolus shortcut pill is opt-in.
        liveActivityShowBolusShortcut = (d.object(forKey: "liveActivityShowBolusShortcut") as? Bool) ?? false
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
            "extendedBolusEnabled": .bool(extendedBolusEnabled),
            "showBolusReasoning": .bool(showBolusReasoning),
            "stackingGuardFrictionEnabled": .bool(stackingGuardFrictionEnabled),
            "watchDefaultBolusMode": .string(watchDefaultBolusMode.rawValue),
            "watchBolusIncrement": .double(watchBolusIncrement),
            "watchCarbIncrement": .double(watchCarbIncrement),
            "showGlucoseAxis": .bool(showGlucoseAxis),
            "glucoseDisplayUnit": .string(glucoseDisplayUnit.rawValue),
            "showGlucoseUnitLabels": .bool(showGlucoseUnitLabels),
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
            "advancedControlEnabled": .bool(advancedControlEnabled),
            "autoSyncPumpTime": .bool(autoSyncPumpTime),
            "autoExerciseMode": .bool(autoExerciseMode),
            "autoSleepMode": .bool(autoSleepMode),
            "modeReminders": .bool(modeReminders),
            "autoTempRate": .bool(autoTempRate),
            "autoProfileActivation": .bool(autoProfileActivation),
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
            "nightscoutUploadEnabled": .bool(nightscoutUploadEnabled),
            "childModeEnabled": .bool(childModeEnabled),
            "liveActivityEnabled": .bool(liveActivityEnabled),
            "liveActivityFields": .stringArray(liveActivityFields),
            "liveActivityStyle": .string(liveActivityStyle),
            "liveActivityTopRightField": .string(liveActivityTopRightField),
            "liveActivityPlotRangeHours": .int(liveActivityPlotRangeHours),
            "liveActivityShowXAxisLine": .bool(liveActivityShowXAxisLine),
            "liveActivityShowYAxisLine": .bool(liveActivityShowYAxisLine),
            "liveActivityShowXAxisTicks": .bool(liveActivityShowXAxisTicks),
            "liveActivityShowYAxisTicks": .bool(liveActivityShowYAxisTicks),
            "liveActivityShowRangeLines": .bool(liveActivityShowRangeLines),
            "liveActivityShowBolusShortcut": .bool(liveActivityShowBolusShortcut),
            "glucoseBadgeEnabled": .bool(glucoseBadgeEnabled),
            // 09.18a (D-10/D-17): SiteAtlas feature toggle — backup-participating (unlike the ciq* flags).
            "siteAtlasEnabled": .bool(siteAtlasEnabled),
        ]
        if let hide = glucoseHideDelayMinutes { m["glucoseHideDelayMinutes"] = .int(hide) }
        // §2.3: emitted only when the optional ceiling is armed (nil ⇒ off ⇒ omitted), like the hide delay.
        if let ceiling = remoteBolusCeiling { m["remoteBolusCeiling"] = .double(ceiling) }
        // D-05: the small-screen override pair — emitted only when set (nil ⇒ Same as phone ⇒ omitted).
        if let f = glucosePlotFloorSmall { m["glucosePlotFloorSmall"] = .int(f) }
        if let c = glucosePlotCeilingSmall { m["glucosePlotCeilingSmall"] = .int(c) }
        if let d1 = d.data(forKey: "alertRules") { m["alertRules"] = .data(d1) }
        // Emit a canonical (sorted) encoding of the in-memory set rather than the raw persisted bytes, so the
        // snapshot for a given set of features is byte-identical regardless of process hash-seed or persist
        // history (see `canonicalChildAllowedData`). Still conditional on the key having ever been persisted.
        if d.data(forKey: "childAllowed") != nil { m["childAllowed"] = .data(Self.canonicalChildAllowedData(childAllowed)) }
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
        if let v = b("stackingGuardFrictionEnabled") { stackingGuardFrictionEnabled = v }
        if let v = s("watchDefaultBolusMode"), let mode = BolusMode(rawValue: v) { watchDefaultBolusMode = mode }
        if let v = dbl("watchBolusIncrement") { watchBolusIncrement = v }
        if let v = dbl("watchCarbIncrement") { watchCarbIncrement = v }
        if let v = b("showGlucoseAxis") { showGlucoseAxis = v }
        if let v = s("glucoseDisplayUnit"), let unit = GlucoseUnit(rawValue: v) { glucoseDisplayUnit = unit }
        if let v = b("showGlucoseUnitLabels") { showGlucoseUnitLabels = v }
        if let v = b("showIOBAxis") { showIOBAxis = v }
        if let v = b("showBolusBars") { showBolusBars = v }
        if let v = i("glucosePlotFloor") { glucosePlotFloor = v }
        if let v = i("glucosePlotCeiling") { glucosePlotCeiling = v }
        // D-05: only apply the override when BOTH halves are present in the backup (same one-unit
        // treatment as init); a backup missing one half leaves the current override unchanged, per
        // applyBackup's documented "absent keys are left unchanged" contract.
        if let f = i("glucosePlotFloorSmall"), let c = i("glucosePlotCeilingSmall") {
            glucosePlotFloorSmall = f
            glucosePlotCeilingSmall = c
        }
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
        if let v = b("autoTempRate") { autoTempRate = v }
        if let v = b("autoProfileActivation") { autoProfileActivation = v }
        if let v = b("autoSyncPumpTime") { autoSyncPumpTime = v }
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
        if let v = sa("garminScreenOrder") { garminScreenOrder = v }
        if let v = s("garminDefaultScreen") { garminDefaultScreen = v }
        if let v = s("garminComplicationDisplay") { garminComplicationDisplay = v }
        if let v = b("garminClockAnalog") { garminClockAnalog = v }
        if let v = s("garminTargetApp") { garminTargetApp = v }
        if let v = b("nightscoutUploadEnabled") { nightscoutUploadEnabled = v }
        if let v = b("childModeEnabled") { childModeEnabled = v }
        if let v = b("liveActivityEnabled") { liveActivityEnabled = v }
        if let v = sa("liveActivityFields") { liveActivityFields = v }
        if let v = s("liveActivityStyle"), v == "fullBleed" || v == "classic" { liveActivityStyle = v }
        if let v = s("liveActivityTopRightField"), Self.liveActivityTopRightFieldOptions.contains(v) {
            liveActivityTopRightField = v
        }
        if let v = i("liveActivityPlotRangeHours"), Self.liveActivityPlotRangeHoursOptions.contains(v) {
            liveActivityPlotRangeHours = v
        }
        if let v = b("liveActivityShowXAxisLine") { liveActivityShowXAxisLine = v }
        if let v = b("liveActivityShowYAxisLine") { liveActivityShowYAxisLine = v }
        if let v = b("liveActivityShowXAxisTicks") { liveActivityShowXAxisTicks = v }
        if let v = b("liveActivityShowYAxisTicks") { liveActivityShowYAxisTicks = v }
        if let v = b("liveActivityShowRangeLines") { liveActivityShowRangeLines = v }
        if let v = b("liveActivityShowBolusShortcut") { liveActivityShowBolusShortcut = v }
        if let v = b("glucoseBadgeEnabled") { glucoseBadgeEnabled = v }
        if let v = b("siteAtlasEnabled") { siteAtlasEnabled = v }
        if let data = dat("alertRules"), let rules = try? JSONDecoder().decode([AlertRule].self, from: data) { alertRules = rules }
        if let data = dat("childAllowed"), let set = try? JSONDecoder().decode(Set<ChildFeature>.self, from: data) { childAllowed = set }
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
        autoTempRate = false
        autoProfileActivation = false
        modeReminders = false
        remoteBolusCeiling = nil
        alertRules = []
    }
}
