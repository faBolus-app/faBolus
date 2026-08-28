import Foundation
import faBolusCore

/// P14 Slice 1 — the single source of truth for every persisted `AppSettings` key.
///
/// Today the 48 keys are enumerated across four hand-maintained lists (`AppSettings.init` defaults,
/// `backupSnapshot()`, `applyBackup()`, and `SettingsView.SettingsIndex.entries`) that drift
/// independently, and the mode system would have added a fifth (per-mode membership). This catalog folds
/// the metadata for all of them into one table: which keys exist, their editability `tier`, the `modes`
/// they appear in, whether they `backsUp`, and whether they `syncsToICloud`.
///
/// **Slice-1 scope is deliberately data + binding, not a mechanical rewrite of the four lists.** A faithful
/// read of `AppSettings.init` shows property observers do *not* fire during `init`, so `UserDefaults` and
/// the live property legitimately diverge for the logic-bearing keys (the `bolusIncrement` 0.05 legacy
/// clamp `AppSettings.swift:294`, the `watchDefaultBolusMode` fallback `:289`). A generic
/// `UserDefaults`-driven derivation of `backupSnapshot()` would therefore NOT be byte-equivalent and would
/// silently change backup behavior in those edge cases — unacceptable on a safety-adjacent path. So the
/// catalog is made *authoritative* and the existing typed lists are **pinned to it by drift-guard tests**
/// (`SettingsCatalogTests`), the same mirror-plus-guard idiom used for `PumpControlBounds` and
/// `WidgetGlucoseThresholds`. No runtime value changes in this slice; enforcement (mode gating) lands in S2.
///
/// The `tier` / `modes` fields are the exact data the P8 evaluator's `ModeGateContext` consumes in S2.
struct SettingDescriptor: Identifiable {
    /// The exact UserDefaults key literal. Frozen — renaming breaks on-disk backups and the iCloud blob's
    /// inner keys.
    let key: String
    /// Which Settings screen category owns the control (reuses `SettingsCategory`).
    let category: SettingsCategory
    /// Editability tier. All 48 current keys are `.user` app preferences; `.clinician`/`.fixed` are
    /// reserved for the pump-therapy descriptors S6–S8 add.
    let tier: SettingTier
    /// The modes in which this setting is shown. `.advanced` sees everything, so it is always a member.
    let modes: Set<AppMode>
    /// True iff the key participates in the portable settings backup (`backupSnapshot`/`applyBackup`).
    let backsUp: Bool
    /// True iff the key rides the iCloud KV settings sync (S5). Invariant: implies `backsUp` (iCloud only
    /// syncs `SettingsBackup.appSettingsSnapshot()`), and is forced **false** for the command-adjacent
    /// flags so settings sync can never carry a safety/command decision to another device (C5). (The
    /// ambient ("ephemeral surface") descriptors that once shared this reasoning for a different
    /// reason — an always-on-screen, per-device display surface should not silently light up on
    /// another device — were the 11 Live Activity descriptors, removed Phase 7 07-01 FEAT-01, and the
    /// glucose-badge descriptor, removed Phase 7 07-02 FEAT-03.)
    let syncsToICloud: Bool
    /// Optional search metadata. Populated `nil` in S1 — the `SettingsIndex` fold is deferred to a later
    /// slice because its rows are category-grouped, not 1:1 with keys, and need a curated overlay (C4).
    let searchTitle: String?
    let searchKeywords: String?

    var id: String { key }

    init(_ key: String, _ category: SettingsCategory, tier: SettingTier = .user,
         from minMode: AppMode, backsUp: Bool, syncsToICloud: Bool? = nil,
         searchTitle: String? = nil, searchKeywords: String? = nil) {
        self.key = key
        self.category = category
        self.tier = tier
        self.modes = Set(AppMode.allCases.filter { $0 >= minMode })
        self.backsUp = backsUp
        // Default: a backed-up key syncs. The five command-adjacent flags pass `false` explicitly.
        self.syncsToICloud = (syncsToICloud ?? backsUp) && backsUp
        self.searchTitle = searchTitle
        self.searchKeywords = searchKeywords
    }

    /// Whether this setting is shown in the given mode.
    func isVisible(in mode: AppMode) -> Bool { modes.contains(mode) }
}

enum SettingsCatalog {
    /// The five command-adjacent flags that must never ride iCloud settings sync — a synced value could
    /// otherwise flip a safety/command decision on another device (C5 / iPhone-only-writes). Named here so
    /// the invariant is greppable and test-anchored, not implicit in the table below.
    static let commandAdjacentFlags: Set<String> = [
        // Phase 9 (09-02, MOBI-02): advancedControlEnabled removed from this set — its
        // SettingsCatalog row is gone (below; the Settings toggle it fed is deleted), so it can no
        // longer sync via iCloud by construction; the AppSettings accessor itself stays (frozen
        // `advancedControlAllowed` reads it, always false via the OTHER operand regardless — see
        // SettingsView.swift's removal comment). Same hidden-flag posture as the removals below.
        "phoneReadOnly",
        "remotesReadOnly",
        // Phase 3 (03-02, F-1): requireRemoteBolusApproval removed from this set — its SettingsCatalog
        // row is gone (hidden-flag pattern), so it can no longer sync via iCloud by construction; the
        // AppSettings accessor itself stays (frozen AppModel.swift:1871 still reads it).
        //
        // Phase 7 (07-04, FEAT-04, D-05, SAFETY): `childModeEnabled` removed from this set too — its
        // SettingsCatalog row is gone (below), and the accessor itself is now a getter-level frozen
        // constant (`get { false } set { } }`), so it can never sync via iCloud OR any other route by
        // construction — a stronger guarantee than "just not synced".
        // §2.3 per-surface bolus-auth enables — a synced "bolusing on" must never arm a remote on another
        // device.
        "garminBolusEnabled",
        // Phase 17.5 (D1-01): the watch bolus-enable accessor this set once excluded is retired
        // entirely — same reasoning as requireRemoteBolusApproval's removal above (03-02, F-1).
        // §2.3 remote-only dose ceiling — a synced value must never silently RELAX the cap on another device
        // (the same C5 hazard as the enables; not a boolean, but the same never-iCloud-sync rule applies).
        "remoteBolusCeiling",
    ]

    /// Persisted `AppSettings` keys — recomputed live at each phase's exit gate rather than hardcoded
    /// here (D-09); see `SettingsCatalogTests` for the current count. History up to Phase 6: 46 → 48,
    /// Phase 5 05-04: `liveActivityEnabled` + `liveActivityFields` added; 48 → 49, Phase 5 05-03: the
    /// glucose-badge opt-in added; 49 → 50, owner-requested "Show unit labels" toggle:
    /// `showGlucoseUnitLabels` added; 50 → 51, Phase 6 06-01 (999.2/D-01): the auto-temp-rate row
    /// added; 51 → 52, Phase 6 06-02 (999.2/D-02): the auto-profile-activation row added; 52 → 55,
    /// Phase 09.13-01 (D-01/D-02/D-04): `glucosePlotFloor` + `glucosePlotCeiling` added (54→55 corrects
    /// a prior off-by-one in this comment); 55 → 57, Phase 09.13-02 (D-05): `glucosePlotFloorSmall` +
    /// `glucosePlotCeilingSmall` added; 57 → 58, Phase 09.18a-04: `siteAtlasEnabled` added; 58 → 59,
    /// Phase 09.26-01 (D-11/D-21): `liveActivityStyle` added; 59 → 66, Phase 09.26-02 (D-15/D-18/D-19):
    /// `liveActivityTopRightField`, `liveActivityPlotRangeHours`, `liveActivityShowXAxisLine`,
    /// `liveActivityShowYAxisLine`, `liveActivityShowXAxisTicks`, `liveActivityShowYAxisTicks`,
    /// `liveActivityShowRangeLines` added; 66 → 67, Phase 09.26-07 (D-22): `liveActivityShowBolusShortcut`
    /// added; Phase 7 (07-01, FEAT-01): all 11 `liveActivity*` keys above removed (delete-on-main);
    /// 67 → 48. Phase 7 (07-02, FEAT-03): the glucose-badge opt-in descriptor removed (no-op stub,
    /// D-04); 48 → 47. Phase 7 (07-03, FEAT-05, D-08): the 5 mode-automation rows (the 3 Standard-tier
    /// ones + the 2 Advanced-only ones added by 06-01/06-02 above) removed; 47 → 42. Phase 7
    /// (07-04, FEAT-04, D-05, SAFETY): `childModeEnabled` + `childAllowed` removed (Child Mode UI
    /// deleted, runtime-gated); 42 → 40. Phase 7 (07-05, FEAT-08, D-06/D-07, SAFETY): the custom
    /// alert-rules engine's descriptor removed (editor UI deleted, property frozen); 40 → 39.
    /// Phase 8 (08-01, LOCK-05): `autoSyncPumpTime` removed (pump-clock UI deleted, force-set-false
    /// init pin); 39 → 38. Phase 8 (08-01, LOCK-02/LOCK-04/LOCK-06): `extendedBolusEnabled`,
    /// `stackingGuardFrictionEnabled`, `glucoseDisplayUnit`, `showGlucoseUnitLabels` removed (Bolus
    /// screen + unit selector UI deleted); 38 → 34. Phase 8 (08-01, LOCK-03): `historyRetentionDays` +
    /// `historySyncEnabled` removed (Data/History view deleted); 34 → 32. Phase 9 (09-02, MOBI-02):
    /// `advancedControlEnabled` removed (its Settings toggle + `PumpControlView.swift` destination
    /// are both deleted); 32 → 31.
    /// Order mirrors `AppSettings.swift` for reviewability.
    /// `notificationTelemetryEnabled` is intentionally absent — it is App-Group-backed (not in `d`) and
    /// not part of this settings surface (`AppSettings.swift:148`).
    static let descriptors: [SettingDescriptor] = [
        // MARK: Bolus & entry
        .init("defaultBolusMode", .bolus, from: .simple, backsUp: true),
        .init("bolusIncrement", .bolus, from: .simple, backsUp: true),
        .init("carbIncrement", .bolus, from: .simple, backsUp: true),
        // Phase 8 (08-01, LOCK-04): `extendedBolusEnabled`'s row is removed here — the "Extended
        // (combo) bolus" toggle it fed is deleted; the accessor stays as a force-set-false init pin.
        .init("showBolusReasoning", .bolus, from: .standard, backsUp: true),
        // Phase 8 (08-01, LOCK-06 friction half): `stackingGuardFrictionEnabled`'s row is removed here
        // too — the "Extra confirmation on unusually large overrides" toggle it fed (Insulin Stacking
        // Guard SG3a escalating-friction disable, task #93) is deleted; the accessor stays as a
        // force-set-false init pin. `StackingGuard.escalation` itself (Packages/faBolusCore) is
        // byte-identical and unaffected — only the UI wiring for the EXTRA confirmation step is gone.
        // MARK: Watch / Garmin entry (remotes)
        .init("watchDefaultBolusMode", .remotes, from: .standard, backsUp: true),
        .init("watchBolusIncrement", .remotes, from: .standard, backsUp: true),
        .init("watchCarbIncrement", .remotes, from: .standard, backsUp: true),
        // MARK: Display & chart
        .init("showGlucoseAxis", .display, from: .standard, backsUp: true),
        // Phase 8 (08-01, LOCK-02): `glucoseDisplayUnit`'s row (Phase 04-01, mmol/L display-unit
        // support, D-03) and `showGlucoseUnitLabels`'s row (owner request) are both removed here — the
        // mg/dL·mmol/L Picker + "Show unit labels" toggle Section they fed is deleted.
        // `glucoseDisplayUnit`'s accessor is now a force-set `.mgdl` init pin; `showGlucoseUnitLabels`'s
        // accessor survives as an ordinary hidden/unregistered flag (not safety-adjacent, no pin needed).
        .init("showIOBAxis", .display, from: .standard, backsUp: true),
        .init("showBolusBars", .display, from: .standard, backsUp: true),
        // Phase 09.13 (D-01/D-04): glucose plot Y-axis floor/ceiling presets — a display-format
        // preference like `glucoseDisplayUnit`, NOT command-adjacent — omitting syncsToICloud gives
        // iCloud sync ON (SettingDescriptor.init default rule).
        .init("glucosePlotFloor", .display, from: .standard, backsUp: true),
        .init("glucosePlotCeiling", .display, from: .standard, backsUp: true),
        .init("showStats", .display, from: .standard, backsUp: true),
        .init("detailsOrder", .display, from: .standard, backsUp: true),
        .init("pillsOrder", .display, from: .standard, backsUp: true),
        // MARK: Watch/Garmin display (remotes)
        .init("watchDetailsOrder", .remotes, from: .standard, backsUp: true),
        .init("watchChartRanges", .remotes, from: .standard, backsUp: true),
        // Phase 09.13-02 (D-05): the optional Watch/Garmin plot Y-axis override pair — `.remotes`
        // (same category as watchChartRanges), NOT command-adjacent (a display preference), default
        // iCloud sync ON (SettingDescriptor.init default rule, mirrors glucosePlotFloor/Ceiling above).
        .init("glucosePlotFloorSmall", .remotes, from: .standard, backsUp: true),
        .init("glucosePlotCeilingSmall", .remotes, from: .standard, backsUp: true),
        // MARK: CGM & freshness
        .init("glucoseStaleMinutes", .cgm, from: .standard, backsUp: true),
        .init("glucoseHideDelayMinutes", .cgm, from: .standard, backsUp: true),
        // MARK: Pump & control
        // Phase 9 (09-02, MOBI-02): `advancedControlEnabled`'s row is removed here — the "Advanced
        // control" Settings toggle it fed (SettingsView.swift's `PumpSettingsView`) is deleted; the
        // accessor stays as an ordinary hidden/unregistered flag (not force-set — `advancedControlAllowed`
        // is already always-false via its OTHER operand, `capabilities.supportsAnyAdvancedControl`, so no
        // pin is needed; same posture as `showGlucoseUnitLabels` above, not `autoSyncPumpTime`'s pin).
        // Phase 8 (08-01, LOCK-05): `autoSyncPumpTime`'s row is removed here — the pump-clock
        // Settings/PumpControlView UI it fed is deleted; the accessor stays as a force-set-false init
        // pin (hidden-flag pattern, same posture as other retired flags above).
        // Phase 7 (07-03, FEAT-05, D-08): the 5 mode-automation descriptors that used to live here
        // (the 3 Standard-tier ones + the 2 Advanced-only ones) are removed — their Settings UI rows
        // are gone. The 3 corresponding `AppSettings` accessors stay (frozen, hidden-flag pattern, the
        // kept `ModeAutomation.swift` still reads them); the other 2 accessors are deleted outright
        // (their only readers, the automation engines, are gone).
        .init("phoneReadOnly", .pump, from: .standard, backsUp: true, syncsToICloud: false),
        .init("readOnlyAllowAlertClear", .pump, from: .advanced, backsUp: true),
        // MARK: Remotes & devices
        .init("remotesReadOnly", .remotes, from: .standard, backsUp: true, syncsToICloud: false),
        .init("garminBolusEnabled", .remotes, from: .standard, backsUp: true, syncsToICloud: false),
        // Phase 17.5 (D1-01): the Apple-Watch bolus-enable row this table once excluded is retired
        // entirely, along with the gate that read it — Garmin's independent enable above is unaffected.
        // §2.3 optional remote-only per-bolus ceiling. Command-adjacent (never iCloud-synced); backs up.
        .init("remoteBolusCeiling", .remotes, from: .standard, backsUp: true, syncsToICloud: false),
        // Phase 3 (03-02, REMOTE-02, Pitfall B/F-1): the Mac/peer "Remote access" rows are removed here.
        // `remoteBluetoothEnabled` is fully gone (accessor + row; never read by AppModel.swift).
        // `requireRemoteBolusApproval`'s row is removed (hidden-flag pattern) — the accessor stays,
        // read by frozen AppModel.swift:1871 — see 03-OWNER-FLAGS.md F-1.
        //
        // Phase 7 (07-04, FEAT-04, D-05, SAFETY): `childModeEnabled`'s and `childAllowed`'s rows are
        // ALSO removed here now — `ChildModeView.swift` (their only UI reader/editor) is deleted, and
        // `childModeEnabled` is a getter-level frozen constant (belt-and-suspenders, see
        // `AppSettings.swift`). Both accessors stay (still read by the frozen `AppModel.swift`
        // `AccessContext` builder + `BolusEntryView`'s `childAllows(.bolus)` UI hint) — only their
        // catalog/backup participation is removed, same hidden-flag posture as
        // `requireRemoteBolusApproval` above.
        .init("garminScreenOrder", .remotes, from: .standard, backsUp: true),
        .init("garminDefaultScreen", .remotes, from: .standard, backsUp: true),
        .init("garminComplicationDisplay", .remotes, from: .standard, backsUp: true),
        .init("garminClockAnalog", .remotes, from: .standard, backsUp: true),
        .init("garminTargetApp", .remotes, from: .advanced, backsUp: true),
        // Phase 20 (D-01 alert intensity + D-02 complication slots) — phone-owned Garmin settings.
        .init("garminAlertIntensityMode", .remotes, from: .standard, backsUp: true),
        .init("garminAlertAudibleMinSeverity", .remotes, from: .standard, backsUp: true),
        .init("garminAlertCriticalOverridesDnd", .remotes, from: .standard, backsUp: true),
        .init("garminComplicationSlots", .remotes, from: .standard, backsUp: true),
        // Custom alert-rules engine (the "Alerts" descriptor + its editor UI) removed from narrow
        // `main` in Phase 7 (07-05, FEAT-08, SAFETY) — the property is now a getter-level frozen
        // constant (belt-and-suspenders, see AppSettings.swift); no catalog descriptor remains since
        // the editor UI it fed is deleted (see dev/alert-rules's REINTEGRATION.md).
        // Nightscout upload (nightscoutUploadEnabled) removed from narrow `main` in Phase 5
        // (HEALTH-02) — the UserDefaults key is left in place as a hidden device-local flag, no
        // migration (see dev/nightscout's REINTEGRATION.md).

        // MARK: — Not backed up (caches + advisory/experimental toggles). syncsToICloud false by rule.
        // Phase 8 (08-01, LOCK-03): `historyRetentionDays`'s and `historySyncEnabled`'s rows are both
        // removed here — `DataHistoryView.swift` (their only UI host) is deleted.
        // `historyRetentionDays` is now a force-set-1 (24h) init pin, actually applied at launch via
        // `App.swift`'s new `model.applyRetention(days:)` call site; `historySyncEnabled` survives as
        // an ordinary hidden/unregistered flag (not safety-adjacent — it only gated the AUTOMATIC
        // on-connect history sync, never dose/glucose retention).
        // NOTE (Phase 09.7-01): `AppSettings.historyCoverage` (D-04, the gap-sync coverage-map bookkeeping)
        // is deliberately NOT registered here — it has no UI surface at all (pure sync bookkeeping, never
        // shown/edited), matching the existing precedent for other internal-only persisted properties
        // (`criticalAlertGrantActive`, `stackingGuardNoticeAckAt`, `clinicianTierAckAt`, `therapyEditAckAt`
        // — none of which are catalog rows either). Adding it here would fail
        // `SettingsReachabilityGuardTests.everyNonExemptCatalogKeyIsReachableInViews` (SC2), which requires
        // every non-debug-exempt catalog key to have a literal UI reference — correctly, since the catalog
        // is for user-facing/backup-relevant settings, not arbitrary internal state.
        // NOTE (Phase 4, 04-02, D-05/D-07/NUDGE-01): `AppSettings.eatingNudgesEnabled` / `eatingTriggerConfig`
        // / `eatingLearnFromFeedback` are deliberately NOT registered here anymore. Their sole UI surfaces
        // (`SmartAssistSettingsView.swift` / `EatingNudgeSettingsView.swift`) were git rm'd from narrow
        // `main` (delete-on-main, preserved on `dev/nudge`) — leaving these three descriptors registered
        // would fail `SettingsReachabilityGuardTests.everyNonExemptCatalogKeyIsReachableInViews` (SC2), which
        // requires every non-debug-exempt catalog key to have a literal UI reference under `ios/faBolus/
        // Views/`. The properties themselves survive as hidden/unregistered flags at their existing
        // defaults — `eatingNudgesEnabled`'s one surviving ungated reader is `AppModel.swift:495`;
        // `eatingTriggerConfig` is read wherever `eatingNudgesEnabled` gates it (`AppModel.swift:57,1628`);
        // `eatingLearnFromFeedback` is read at `AppModel.swift:141,145,155,1631,1663,1684`. None are backed
        // up (`backsUp: false`, unchanged), so this removal needs no `backupSnapshot()`/`applyBackup()`
        // edit — same historyCoverage-style unregistered-flag idiom as above. `siteAtlasEnabled`'s
        // `.smartAssist` descriptor (formerly registered just above the historyRetentionDays MARK) is
        // removed for the same SC2 reason — its property also survives, unregistered, per D-06b
        // (04-OWNER-FLAGS.md, Plan 03).
    ]

    /// Lookup by key.
    static let byKey: [String: SettingDescriptor] =
        Dictionary(uniqueKeysWithValues: descriptors.map { ($0.key, $0) })

    /// Keys that ride iCloud settings sync (the S5 filter's input).
    static var iCloudSyncedKeys: Set<String> {
        Set(descriptors.filter { $0.syncsToICloud }.map { $0.key })
    }

    /// Keys included in the portable settings backup.
    static var backedUpKeys: Set<String> {
        Set(descriptors.filter { $0.backsUp }.map { $0.key })
    }
}
