import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P14 Slice 1 drift guards. The catalog (`SettingsCatalog.descriptors`) is the single source of truth
/// for the 45 persisted `AppSettings` keys; these tests pin the four hand-maintained lists to it so they
/// can never drift silently — the mirror-plus-guard idiom used by `PumpControlBoundsMirrorTests` and
/// `WidgetGlucoseThresholdsMirrorTests`, applied to the settings surface instead of a wire/firmware bound.
/// Phase 00-04 (INV-02 §6c). Reusable no-dangling-refs / cohesive-UX completeness helper.
///
/// The narrow-main topology removes surfaces one at a time; when a surface is compiled OUT, every
/// user-facing reference to it must go with it (settings rows, search entries, nav, deep-links) or the
/// UX is left incoherent — a search hit that routes nowhere. This helper is the reusable §6c backstop
/// each later removal phase parametrizes: it asks, for a set of search tokens owned by a gated-OFF
/// feature, which `SettingsIndex` rows still advertise it. Phase 0 removes nothing, so on the current
/// build the gated-off token set is empty and the answer is `[]` (vacuous-green, by design). Each later
/// phase adds its surface's token(s) to `gatedOffSearchTokens` under the matching `#if`, plus one
/// assertion for the surface it removes. It lives in the test target (not product code) so the
/// dose/signed + settings product sources stay byte-identical across branches (INV-01).
enum CompileGateAudit {
    /// Search tokens owned by every feature removed from narrow `main` so far. Each removal phase adds
    /// its surface's token(s) UNCONDITIONALLY (no `#if` guard) — this milestone's removals are
    /// delete-on-main (`git rm`, D-01), not runtime/compile flags, so a token is permanently orphaned
    /// once added, e.g.: `tokens.formUnion(["Remote access", "Pair a remote"])` (Phase 3, Mac + peer).
    static var gatedOffSearchTokens: Set<String> {
        var tokens: Set<String> = []
        // Phase 1, Plan 01 (CGM-05): xDrip App Group removed from narrow `main` (unconditional —
        // permanent removal, no `#if` guard per D-01).
        // Phase 1, Plan 02 (CGM-03/CGM-04): Dexcom G6 direct-BLE + LibreLinkUp removed from narrow
        // `main` (unconditional — permanent removal, no `#if` guard per D-01).
        tokens.formUnion(["xdrip", "libre"])
        // Phase 3, 03-01/03-02 (REMOTE-01/REMOTE-02): the Mac menu-bar remote + iPhone-to-iPhone peer
        // remote share ONE Settings UI ("Remote access" toggle + "Pair a remote (Mac or iPhone)"
        // NavigationLink, SettingsView.swift, both git rm'd in 03-02) — both surfaces' tokens land
        // together since neither can be removed independently of the other's UI.
        tokens.formUnion(["Remote access", "Pair a remote"])
        // Phase 3, 03-03 (REMOTE-03): the whole Watch target is delete-on-main, but its Settings row
        // is the `#if !WATCH_EMBEDDED` fallback notice (SettingsView.swift, "Apple Watch app not
        // included") — permanently active now that WATCH_EMBEDDED no longer exists in any build
        // config, so it is NOT itself an orphan. This token instead pins the LITERAL title tied to the
        // removed watch-remote surface, keeping the orphan-detector's own self-test
        // (`orphanDetectorIsNonVacuous` below) meaningful for a token this milestone actually removed.
        tokens.formUnion(["Apple Watch app"])
        // Phase 5 (05-01/05-02, HEALTH-01/HEALTH-02): Apple HealthKit (CGM source + HR reader +
        // import/export) and Nightscout (source + upload + backfill) both removed from narrow
        // `main` (unconditional — permanent removal, no `#if` guard per D-01).
        tokens.formUnion(["nightscout", "healthkit", "heart rate"])
        // Phase 6 (06-02/06-03, BACKUP-01): the "Backup & restore" row (keywords: "backup restore
        // icloud files settings export import") was `git rm`'d from `SettingsView.swift` in 06-02 —
        // its `.backupRestore` case, tag, NavigationLink, and `SettingsExtraIndex`/`allExtras` entry
        // are all gone (confirmed by a live grep of this tree before adding these tokens, per this
        // plan's own instruction not to guess the strings). Only "icloud", "restore", "files", and
        // "import" are added here: "backup" and "export" are DELIBERATELY EXCLUDED even though the
        // removed row also used them, because both terms are still legitimately owned by DIFFERENT,
        // STILL-LIVE rows today — "Read-only mode" keywords contain "...caregiver backup phone..."
        // (a spare/backup DEVICE, unrelated to the removed backup ENGINE) and "Data & history"
        // keywords contain "...export logs..." (CSV history export, a different still-present
        // feature) — adding either would make `orphanedSettingsIndexEntries` wrongly flag a live row
        // (the exact §6c false-positive this phase's D-08 carve-out must not trigger). "settings" is
        // also excluded as too generic to be backup-specific. SiteAtlas never had its own
        // `SettingsIndex`/`SettingsExtraIndex` row (it was reached from elsewhere in the app, not
        // Settings search), so it contributes no additional token here.
        tokens.formUnion(["icloud", "restore", "files", "import"])
        // Phase 7, 07-01 (FEAT-07): FoodFinder / food-scanner (barcode + OpenFoodFacts lookup, the
        // opt-in BYO-key AI carb-estimate path, and the BolusEntryView "Find food" carb-seam entry
        // point) removed from narrow `main` (unconditional — permanent removal, no dose-set stub per
        // D-01/D-03). No live `SettingsIndex` row ever advertised FoodFinder (it was a Bolus-screen
        // entry point, not a Settings row), so these tokens are a genuinely vacuous, correct check —
        // they exist to satisfy this phase's own §6c convention, not to catch a live orphan today.
        tokens.formUnion(["foodfinder", "find food", "barcode"])
        // Phase 7, 07-01 (FEAT-01): the glucose Live Activity (master opt-in, field selection, style,
        // and full-bleed display options — 11 descriptors) removed from narrow `main` (unconditional
        // — permanent removal, no dose-set stub per D-01/D-02). No live `SettingsIndex` row ever
        // advertised Live Activity (it had its own dedicated Settings section, not an indexed search
        // row), so this token is also a genuinely vacuous, correct check.
        tokens.formUnion(["liveactivity"])
        // Phase 7, 07-02 (FEAT-02): the GraphDetailView scrubbable readout overlay removed from narrow
        // `main` (the view + the GlucoseChartView scrubber section; the chart itself is unaffected).
        // No live `SettingsIndex` row ever advertised it (it was a chart-overlay gesture, not a
        // Settings row), so this token is a genuinely vacuous, correct check.
        tokens.formUnion(["graphdetail"])
        // Phase 7, 07-02 (FEAT-06): the Retrospective insights section (DataHistoryView.swift) + the 9
        // Views/LoopInsights + Vendor/LoopPowerPack/LoopInsights files (EndoReport PDF, caffeine/
        // alcohol trackers, caregiver digest) removed from narrow `main`. No live `SettingsIndex` row
        // ever advertised "insights"/"retrospective" ("Data & history"'s keywords are "history data
        // export logs time in range" — no collision), so this token is also a genuinely vacuous,
        // correct check.
        tokens.formUnion(["retrospective", "insights"])
        // Phase 7, 07-02 (FEAT-03): the CGM app-icon glucose badge removed from narrow `main` — real
        // `GlucoseBadge.swift` `git rm`'d and replaced by a main-only no-op stub (D-04 literal no-op
        // stub, owner 2026-08-21); its Settings UI + `SettingsCatalog` descriptor are gone too. No live
        // `SettingsIndex` row ever advertised "badge" (it had its own dedicated Settings section, not
        // an indexed search row, same shape as Live Activity above), so this token is also a genuinely
        // vacuous, correct check.
        tokens.formUnion(["badge"])
        // Phase 7, 07-03 (FEAT-05): Siri + read-only Shortcuts (the 5 `ios/faBolus/Intents/*` files,
        // incl. `FaBolusShortcuts`) + the Temp/Profile automation engines removed from narrow `main`
        // (unconditional — permanent removal, no `#if` guard per D-01); the mode-automation Settings
        // Section (5 toggles + the help-view link) is also removed, and its `SettingsIndex` row
        // ("Activity & sleep automation") + the separate, now-meaningless "Siri phrases" row (a §6c
        // finding not in RESEARCH's file list — the live "Siri (read-only)" Settings section it
        // pointed to described voice phrases that no longer register anywhere once `FaBolusShortcuts`
        // is gone) were both removed in the SAME commit as this token addition, so this check is a
        // genuinely vacuous, correct check by construction (no live row left to flag).
        tokens.formUnion(["siri", "shortcuts automation", "auto exercise", "auto sleep", "auto profile activation", "auto temp rate"])
        // Phase 7, 07-04 (FEAT-04): Child Mode (`ChildModeView.swift`, its 3 SettingsView.swift nav
        // sites, and the `SettingsCatalog` `childModeEnabled`/`childAllowed` descriptors) removed from
        // narrow `main` via a runtime gate (childModeEnabled frozen false; the evaluator itself stays
        // byte-identical). "Child mode" was NEVER a `SettingsIndex` row (only `SettingsExtraIndex`,
        // the sidebar-only index this helper does not scan), so this token is a genuinely vacuous,
        // correct check, same posture as Live Activity/badge/GraphDetail/Retrospective above.
        // Deliberately "childmode" (concatenated, no space) rather than "lock"/"pin" — either bare
        // word would false-positive against the still-LIVE "Garmin analog clock face" row (contains
        // "clock", which contains "lock" as a substring) via this helper's plain `.contains` match.
        tokens.formUnion(["childmode"])
        // Phase 7, 07-05 (FEAT-08, SAFETY): the custom alert-rules engine's editor UI
        // (the "Alert auto-rules" `SettingsIndex` row + the `.alerts` category/screen it belonged
        // to) removed from narrow `main` — the property itself is frozen to a getter-level constant
        // `[]`, not deleted (the byte-identity-protected engine can't be). The row was removed in the
        // SAME commit as this token addition, so this check is a genuinely vacuous, correct check by
        // construction (no live row left to flag). Deliberately "alertrules" (concatenated) rather
        // than a bare word like "quiet hours"/"auto snooze" — either would false-positive against the
        // still-LIVE "Notification controls" row, which legitimately shares that vocabulary.
        tokens.formUnion(["alertrules"])
        // Phase 8, 08-01 (LOCK-05): the pump-clock Section ("Keep pump clock synced to phone" toggle +
        // "Sync pump time now" button, `SettingsView.swift`'s `PumpSettingsView`) removed — `autoSyncPumpTime`
        // is now a force-set-false init pin. This token was NEVER a `SettingsIndex` row (the pump-clock
        // Section had no header/footer search-keyword entry of its own — it lived under "Pump connection"'s
        // row, which stays live for the connect/pair/forget controls that remain), so this is a genuinely
        // vacuous, correct check, same posture as several Phase 7 tokens above.
        tokens.formUnion(["pump clock"])
        // Phase 8, 08-01 (LOCK-01): the "Mode: Simple / Standard / Advanced" `SettingsExtraIndex` entry
        // (sidebar-only; never a `SettingsIndex` row) removed — `ModeSettingsView`/`ModeOnboardingView`
        // are deleted; `appMode` is force-set `.advanced` in both `ModeStore.init` and
        // `AppSettings.init`. Deliberately "modeselector" (concatenated) rather than a bare "mode" —
        // that would false-positive against the still-LIVE "Default bolus mode" row, or "advanced"
        // against the still-LIVE "Advanced control" row, via this helper's plain `.contains` match.
        tokens.formUnion(["modeselector"])
        return tokens
    }

    /// The `SettingsIndex` rows that still advertise a gated-off feature — a §6c dangling ref. A
    /// non-empty result means a removed feature left a live, findable settings row behind.
    /// `Entry.matches` is the exact predicate `SettingsView` uses for search, so "advertised" here means
    /// precisely "the user could still find it". Non-tautological: given no tokens it returns `[]`; given
    /// a token owned by a present row it returns that row (see `orphanDetectorIsNonVacuous`).
    static func orphanedSettingsIndexEntries(forGatedOffTokens tokens: Set<String>) -> [SettingsIndex.Entry] {
        guard !tokens.isEmpty else { return [] }
        return SettingsIndex.entries.filter { entry in tokens.contains { entry.matches($0) } }
    }
}

struct SettingsCatalogTests {

    /// The four backup keys `backupSnapshot()` emits only when their value is present (two optionals — an
    /// int and the §2.3 remote-bolus ceiling double — and two JSON blobs). Everything else is unconditional.
    /// Declared here so the drift guard can tolerate their absence on a fresh `AppSettings` without weakening it.
    private let conditionalBackupKeys: Set<String> = [
        "glucoseHideDelayMinutes", "remoteBolusCeiling",
        // Phase 09.13-02 (D-05): the small-screen plot override pair — emitted only when non-nil.
        "glucosePlotFloorSmall", "glucosePlotCeilingSmall",
        // Phase 7 (07-04, FEAT-04, D-05, SAFETY): `childAllowed` removed from this set — its
        // `SettingsCatalog` descriptor is gone (Child Mode UI deleted), so it no longer appears in
        // `SettingsCatalog.backedUpKeys` at all (conditional or otherwise). The property itself stays
        // (still read by the frozen `AppModel.swift` AccessContext builder + `BolusEntryView`'s UI
        // hint) — only its catalog/backup participation is removed.
        // Phase 7 (07-05, FEAT-08, D-06/D-07, SAFETY): the custom alert-rules engine's persisted-key
        // literal removed from this set too — its `SettingsCatalog` descriptor is gone (editor UI
        // deleted, property frozen), so it no longer appears in `SettingsCatalog.backedUpKeys` either.
    ]

    // MARK: Coverage

    @Test func descriptorsCoverExactly48UniqueKeys() {
        // P16 §3.2: 48 → 46 (smartAssistEnabled R6 + hypoAlertsEnabled R5 removed). P16 F2: 46 → 44
        // (basalScheduleByHour + basalScheduleSource removed with the dead display-only basal cache).
        // Phase 01-03 (task #93, SG3a): 44 → 45 (stackingGuardFrictionEnabled added).
        // Phase 04-01 (mmol/L display-unit support, D-03): 45 → 46 (glucoseDisplayUnit added).
        // Phase 5 (05-04, D-15/D-17a): 46 → 48 (liveActivityEnabled + liveActivityFields added).
        // Phase 5 (05-03, D-13/D-14): 48 → 49 (glucoseBadgeEnabled added).
        // Owner-requested "Show unit labels" toggle: 49 → 50 (showGlucoseUnitLabels added).
        // Phase 6 (06-01, 999.2/D-01): 50 → 51 (the auto-temp-rate row added).
        // Phase 6 (06-02, 999.2/D-02): 51 → 52 (the auto-profile-activation row added).
        // Phase 09.7-01: historyCoverage (D-04) is intentionally NOT added here — see the NOTE in
        // SettingsCatalog.swift (no UI surface; matches the ack/grant-flag precedent).
        // Phase 09.7-02 (D-01): 52 → 53 (historySyncEnabled added).
        // Phase 09.13-01 (D-01/D-02/D-04): 53 → 55 (glucosePlotFloor + glucosePlotCeiling added).
        // Phase 09.13-02 (D-05): 55 → 57 (glucosePlotFloorSmall + glucosePlotCeilingSmall added).
        // Phase 09.18a-04 (D-10/D-16/D-17): 57 → 58 (siteAtlasEnabled added — backup-participating).
        // Phase 09.26-01 tracer (D-11/D-21): 58 → 59 (liveActivityStyle added).
        // Phase 09.26-02 (D-15/D-18/D-19): 59 → 66 (liveActivityTopRightField, liveActivityPlotRangeHours,
        // liveActivityShowXAxisLine, liveActivityShowYAxisLine, liveActivityShowXAxisTicks,
        // liveActivityShowYAxisTicks, liveActivityShowRangeLines added).
        // Phase 09.26-07 (D-22): 66 → 67 (liveActivityShowBolusShortcut added).
        // Phase 3 (03-02, REMOTE-02, Pitfall B/F-1): 67 → 65 (remoteBluetoothEnabled removed entirely;
        // requireRemoteBolusApproval's row removed — hidden-flag pattern, accessor stays).
        // Phase 3 (03-03, REMOTE-03): 65 → 64 (watchBolusEnabled's row removed — hidden-flag pattern,
        // accessor stays; the five Garmin-shared watch*/glucosePlotFloorSmall/CeilingSmall
        // descriptors stay registered, Pitfall E).
        // Phase 4 (04-02, D-05/D-07/NUDGE-01): 64 → 60 (siteAtlasEnabled + eatingNudgesEnabled +
        // eatingTriggerConfig + eatingLearnFromFeedback removed — the whole `.smartAssist` submenu
        // deleted; all 4 properties survive as hidden/unregistered flags, see the NOTE in
        // SettingsCatalog.swift).
        // Phase 5 (05-02, HEALTH-02): 60 → 59 (nightscoutUploadEnabled removed — the property
        // survives as a hidden/unregistered UserDefaults flag, no migration; HealthKit's
        // healthKit*Enabled properties were never a catalog row per D-13, so HEALTH-01 required no
        // count change here).
        // Phase 6 (06-02/06-03, BACKUP-01): 59 → 59, NO CHANGE — re-derived LIVE (Pitfall 4, Open
        // Question 1) against the post-Phase-4 tree rather than trusting the RESEARCH snapshot.
        // `siteAtlasEnabled` was deleted from `AppSettings.swift` in 06-02 (A3), but it was already
        // REMOVED from `SettingsCatalog.descriptors` by Phase 4 (04-02) as an unregistered hidden
        // flag (see the NOTE at `SettingsCatalog.swift:258`) — so this phase's deletion has zero
        // effect on the descriptor count. No other backup-engine surface (the removed
        // `SettingsBackup`/`ICloudSync`/`PrivacyDataExport`/`SiteAtlasStore` types) was ever itself a
        // persisted `AppSettings` key/descriptor — they operated ON the catalog, they were never
        // rows IN it — so BACKUP-01 needed no descriptor removal here at all.
        // Phase 7 (07-01, FEAT-01): 59 → 48 (all 11 liveActivity* descriptors removed — the master
        // opt-in, field selection, style, and 7 full-bleed display options — delete-on-main).
        // Phase 7 (07-02, FEAT-03): 48 → 47 (glucoseBadgeEnabled descriptor removed — the badge is a
        // main-only no-op stub now, D-04 literal no-op stub, owner 2026-08-21).
        // Phase 7 (07-03, FEAT-05): 47 → 42 (the 5 mode-automation descriptors removed — the 3
        // Standard-tier rows + the 2 Advanced-only rows added by 06-01/06-02 above; their Settings UI
        // section is gone. 3 of the 5 backing `AppSettings` accessors survive as frozen
        // hidden/unregistered flags, the other 2 are deleted outright).
        // Phase 7 (07-04, FEAT-04, D-05, SAFETY): 42 → 40 (`childModeEnabled` + `childAllowed`
        // descriptors removed — Child Mode UI deleted; both backing accessors survive,
        // `childModeEnabled` as a getter-level frozen constant, `childAllowed` unchanged).
        // Phase 7 (07-05, FEAT-08, D-06/D-07, SAFETY): 40 → 39 (the custom alert-rules engine's
        // descriptor removed — editor UI deleted; the backing accessor survives as a getter-level
        // frozen constant).
        // Phase 8 (08-01, LOCK-05): 39 → 38 (`autoSyncPumpTime` removed — pump-clock UI deleted; the
        // backing accessor survives as a force-set-false init pin).
        #expect(SettingsCatalog.descriptors.count == 38)
        #expect(SettingsCatalog.byKey.count == 38)   // Dictionary(uniqueKeysWithValues:) also traps on dup
        let keys = SettingsCatalog.descriptors.map(\.key)
        #expect(Set(keys).count == keys.count)       // no duplicate literal
    }

    // MARK: Golden equivalence — the catalog's backup set == what backupSnapshot actually emits

    /// Drift guard, read-only (no singleton mutation → safe under parallel execution). If a key is added to
    /// `backupSnapshot()` without the catalog, `snapshot ⊄ backedUpKeys` fails; if an unconditional key is
    /// dropped from `backupSnapshot()`, `unconditional ⊄ snapshot` fails.
    @Test @MainActor func backedUpSetMatchesBackupSnapshot() {
        let snapshotKeys = Set(AppSettings.shared.backupSnapshot().keys)
        #expect(snapshotKeys.isSubset(of: SettingsCatalog.backedUpKeys))
        let unconditional = SettingsCatalog.backedUpKeys.subtracting(conditionalBackupKeys)
        #expect(unconditional.isSubset(of: snapshotKeys))
        // Phase 5 (05-04): 42 → 44 (liveActivityEnabled + liveActivityFields, both unconditional).
        // Phase 5 (05-03): 44 → 45 (glucoseBadgeEnabled, unconditional).
        // Owner-requested toggle: 45 → 46 (showGlucoseUnitLabels, unconditional).
        // Phase 6 (06-01, 999.2/D-01): 46 → 47 (the auto-temp-rate row, unconditional).
        // Phase 6 (06-02, 999.2/D-02): 47 → 48 (the auto-profile-activation row, unconditional).
        // Phase 09.7-02 (D-01): historySyncEnabled is NOT backed up (device-local), no count change here.
        // Phase 09.13-01 (D-01/D-02/D-04): 48 → 50 (glucosePlotFloor + glucosePlotCeiling, both unconditional).
        // Phase 09.13-02 (D-05): 50 → 52 (glucosePlotFloorSmall + glucosePlotCeilingSmall, both conditional).
        // Phase 09.18a-04 (D-10/D-17): 52 → 53 (siteAtlasEnabled, unconditional).
        // Phase 09.26-01 tracer (D-11/D-21): 53 → 54 (liveActivityStyle, unconditional).
        // Phase 09.26-02 (D-15/D-18/D-19): 54 → 61 (the 7 new full-bleed display settings, all
        // unconditional).
        // Phase 09.26-07 (D-22): 61 → 62 (liveActivityShowBolusShortcut, unconditional).
        // Phase 3 (03-02, REMOTE-02, Pitfall B/F-1): 62 → 60 (remoteBluetoothEnabled +
        // requireRemoteBolusApproval, both unconditional, removed from the catalog AND backupSnapshot).
        // Phase 3 (03-03, REMOTE-03): 60 → 59 (watchBolusEnabled, unconditional, removed from the
        // catalog AND backupSnapshot — hidden-flag pattern, accessor stays).
        // Phase 4 (04-02, D-05/NUDGE-01): 59 → 58 (siteAtlasEnabled, unconditional, removed from the
        // catalog AND backupSnapshot — the eating trio was never backed up, so no further drop).
        // Phase 5 (05-02, HEALTH-02): 58 → 57 (nightscoutUploadEnabled, unconditional, removed from
        // the catalog AND backupSnapshot).
        // Phase 6 (06-02/06-03, BACKUP-01): 57 → 57, NO CHANGE — re-derived LIVE. `siteAtlasEnabled`
        // was already dropped from `backupSnapshot()`/`applyBackup()` by Phase 4 (04-02, see the
        // NOTE at `AppSettings.swift:1143`/`:1247`), so 06-02's property deletion changes nothing
        // here; the removed backup-engine types never emitted their own catalog-backed key.
        // Phase 7 (07-01, FEAT-01): 57 → 46 (all 11 liveActivity* keys removed, all unconditional).
        // Phase 7 (07-02, FEAT-03): 46 → 45 (glucoseBadgeEnabled removed from the catalog AND
        // backupSnapshot/applyBackup, unconditional — the badge is a main-only no-op stub now).
        // Phase 7 (07-03, FEAT-05): 45 → 40 (the 5 mode-automation rows removed from the catalog; the
        // 3 frozen accessors' backup/applyBackup lines removed too — hidden/unregistered, never
        // backed up going forward; the other 2 accessors are deleted outright).
        // Phase 7 (07-04, FEAT-04, D-05, SAFETY): 40 → 38 (`childModeEnabled`, unconditional, removed
        // from the catalog AND backupSnapshot/applyBackup — getter-level frozen constant now;
        // `childAllowed`, conditional, removed from the catalog only — its own backupSnapshot/
        // applyBackup participation is unchanged, but it no longer counts toward this total since it
        // has no catalog descriptor to be "backed up" through).
        // Phase 7 (07-05, FEAT-08, D-06/D-07, SAFETY): 38 → 37 (the custom alert-rules engine's
        // persisted key, conditional, removed from the catalog AND backupSnapshot/applyBackup —
        // getter-level frozen constant now, same posture as `childModeEnabled`).
        // Phase 8 (08-01, LOCK-05): 37 → 36 (`autoSyncPumpTime`, unconditional, removed from the
        // catalog AND backupSnapshot/applyBackup — force-set-false init pin now).
        #expect(SettingsCatalog.backedUpKeys.count == 36)                      // 32 unconditional + 4 conditional
        #expect(conditionalBackupKeys.isSubset(of: SettingsCatalog.backedUpKeys))
    }

    /// applyBackup ∘ backupSnapshot is a no-op round-trip: re-applying the current values leaves every
    /// backed-up key byte-identical (idempotent, so safe even if another suite reads `.shared` meanwhile).
    @Test @MainActor func backupRoundTripsThroughBackupValue() {
        let before = AppSettings.shared.backupSnapshot()
        AppSettings.shared.applyBackup(before)
        let after = AppSettings.shared.backupSnapshot()
        #expect(before == after)
    }

    /// P16 F2 backup-format tolerance. `basalScheduleByHour` / `basalScheduleSource` were removed with the
    /// dead display-only basal cache. A backup written by an OLDER build may still carry those keys; restore
    /// must (a) decode such a file (an unknown *key* with a valid `BackupValue` is not an unknown *type*, so
    /// it survives JSON) and (b) silently ignore them in `applyBackup` — never crash, never resurrect a
    /// removed setting. Start from the current snapshot so the assertion stays an idempotent no-op round-trip.
    @Test @MainActor func restoreToleratesLegacyBasalScheduleKeys() {
        let base = AppSettings.shared.backupSnapshot()
        var legacy = base
        legacy["basalScheduleByHour"] = .data(Data([0, 1, 2, 3]))   // stand-in for the old [Double] cache blob
        legacy["basalScheduleSource"] = .string("Nightscout")
        // Survive a full JSON encode→decode like a real on-disk backup, not just an in-memory dict.
        let backup = FaBolusBackup(meta: .init(createdAt: Date(), appVersion: "test",
                                               pumpModel: "unknown", deviceName: "test"),
                                   appSettings: legacy)
        let decoded = try? FaBolusBackup.decode(backup.encoded())
        #expect(decoded != nil, "a legacy backup carrying removed keys must still decode")
        #expect(decoded?.appSettings?["basalScheduleByHour"] != nil)   // the unknown key round-trips…
        AppSettings.shared.applyBackup(decoded?.appSettings ?? [:])    // …and applying it must not crash
        #expect(AppSettings.shared.backupSnapshot() == base)           // removed keys ignored; nothing changed
    }

    /// The `childAllowed` set is the ONLY `Set`-backed persisted value, and `Set` serializes to a JSON array
    /// in hash-iteration order — randomized per process. If we ever encode it raw again, the same set of
    /// features would produce different bytes across launches/devices, reintroducing spurious backup/iCloud
    /// diffs and the flaky `backupRoundTripsThroughBackupValue` failure this replaced. Pin the invariant
    /// directly and process-independently: the canonical encoding lists features in ascending `rawValue`
    /// order (not whatever order the set happens to iterate), and still decodes back to the identical set.
    @Test func childAllowedEncodingIsCanonicalAndLossless() {
        let set = Set(ChildFeature.allCases)
        let data = AppSettings.canonicalChildAllowedData(set)
        let arr = try? JSONDecoder().decode([String].self, from: data)
        #expect(arr == set.map(\.rawValue).sorted(), "canonical encoding must be ascending-rawValue order")
        #expect((try? JSONDecoder().decode(Set<ChildFeature>.self, from: data)) == set)
    }

    // MARK: iCloud safety — the single biggest correctness item in the slice (C5)

    @Test func iCloudSubsetExcludesEveryCommandAdjacentFlag() {
        let synced = SettingsCatalog.iCloudSyncedKeys
        #expect(synced.isDisjoint(with: SettingsCatalog.commandAdjacentFlags))
        // The five flags must all actually exist in the catalog (and be backed up), or the exclusion is
        // vacuous — a flag we forgot to model would silently sync.
        for flag in SettingsCatalog.commandAdjacentFlags {
            let d = SettingsCatalog.byKey[flag]
            #expect(d != nil, "command-adjacent flag \(flag) missing from catalog")
            #expect(d?.backsUp == true)
            #expect(d?.syncsToICloud == false)
        }
    }

    @Test func syncingImpliesBackedUp() {
        // iCloud only ships `SettingsBackup.appSettingsSnapshot()` == `backupSnapshot()`, so a key that is
        // not backed up can never sync regardless of how the row is written.
        for d in SettingsCatalog.descriptors where d.syncsToICloud {
            #expect(d.backsUp, "\(d.key) syncs to iCloud but is not backed up")
        }
    }

    // MARK: Mode axis

    @Test func everyModeSetIsNonEmptyAndIncludesAdvanced() {
        for d in SettingsCatalog.descriptors {
            #expect(!d.modes.isEmpty)
            #expect(d.isVisible(in: .advanced), "\(d.key) is not visible in Advanced")
        }
    }

    @Test func simpleModeIsANonEmptyProperSubsetOfAdvanced() {
        let simple = SettingsCatalog.descriptors.filter { $0.isVisible(in: .simple) }.map(\.key)
        let advanced = SettingsCatalog.descriptors.filter { $0.isVisible(in: .advanced) }.map(\.key)
        #expect(!simple.isEmpty)                       // Simple is a real, usable subset
        #expect(simple.count < advanced.count)         // …and strictly fewer than Advanced sees
        #expect(Set(simple).isSubset(of: Set(advanced)))
    }

    // MARK: Tier axis (S1 state)

    @Test func allCurrentKeysAreUserTier() {
        // Every one of the 45 keys is an app/display/remote preference the user owns. The `.clinician` /
        // `.fixed` tiers exist in the vocabulary but are reserved for the pump-therapy descriptors S6–S8
        // add as *separate* rows; if one is ever added here it must update this assertion deliberately.
        #expect(SettingsCatalog.descriptors.allSatisfy { $0.tier == .user })
    }

    // MARK: Phase 01-03 (task #93, SG3a) — the escalating-friction disable toggle's registration

    /// The SG3a escalating-friction disable toggle must be a `.user`-tier row visible from Simple minimum
    /// mode (never `.clinician`/`.fixed`) — it only gates a UI friction-tier presentation choice, not a
    /// therapy parameter.
    @Test func stackingGuardFrictionEnabledIsRegisteredAtUserTierFromSimple() {
        let d = SettingsCatalog.byKey["stackingGuardFrictionEnabled"]
        #expect(d != nil, "stackingGuardFrictionEnabled missing from the catalog")
        #expect(d?.tier == .user)
        #expect(d?.isVisible(in: .simple) == true)
        #expect(d?.backsUp == true)
    }

    // MARK: Ambient-surface flags are per-device (never iCloud-synced)

    /// The ambient always-on-screen opt-ins (`liveActivityEnabled`, `liveActivityFields`,
    /// `glucoseBadgeEnabled`) had to stay per-device: enabling the Live Activity or the glucose badge on
    /// one iPhone must never silently switch it on for the same owner on another device. They still
    /// backed up (a restore is an explicit user action) and were not command-adjacent — a distinct
    /// exclusion reason from C5, asserted independently of `commandAdjacentFlags`.
    @Test func ambientSurfaceFlagsAreBackedUpButNeverICloudSynced() {
        // Phase 7 (07-01, FEAT-01): liveActivityEnabled/liveActivityFields removed from this set —
        // the 11 liveActivity* descriptors that shared this ambient-surface reasoning are gone.
        // Phase 7 (07-02, FEAT-03): glucoseBadgeEnabled removed from this set too — its descriptor is
        // gone (the badge is a main-only no-op stub now, D-04). The set is now empty: EVERY ambient-
        // surface flag this milestone ever tracked here has been removed from narrow `main`. This
        // remains a deliberately non-tautological, vacuous-green check (same posture as
        // `CompileGateAudit.gatedOffSearchTokens`'s per-surface entries) — the loop below is a no-op on
        // an empty set, so the test trivially passes; it stays in the suite as a live placeholder in
        // case a future ambient-surface flag is added.
        let ambientSurfaceFlags: Set<String> = []
        let synced = SettingsCatalog.iCloudSyncedKeys
        #expect(synced.isDisjoint(with: ambientSurfaceFlags))
        for flag in ambientSurfaceFlags {
            let d = SettingsCatalog.byKey[flag]
            #expect(d != nil, "ambient-surface flag \(flag) missing from catalog")
            #expect(d?.backsUp == true, "\(flag) must still back up (local persistence unaffected)")
            #expect(d?.syncsToICloud == false, "\(flag) must not ride iCloud settings sync")
            #expect(!SettingsCatalog.commandAdjacentFlags.contains(flag),
                     "\(flag) is excluded for ambient-surface reasons, not C5 command-adjacency")
        }
    }

    // MARK: Phase 04-01 (mmol/L display-unit support, D-03) — the glucoseDisplayUnit setting's registration

    /// D-03: `.display` category, `backsUp: true` with iCloud ON (a display unit is NOT command-adjacent).
    @Test func glucoseDisplayUnitIsRegisteredInDisplayWithICloudSyncOn() {
        let d = SettingsCatalog.byKey["glucoseDisplayUnit"]
        #expect(d != nil, "glucoseDisplayUnit missing from the catalog")
        #expect(d?.category == .display)
        #expect(d?.backsUp == true)
        #expect(d?.syncsToICloud == true)
        #expect(!SettingsCatalog.commandAdjacentFlags.contains("glucoseDisplayUnit"))
    }

    /// D-03: default = mg/dL (behavior-preserving for existing users) on a fresh install, and the setting
    /// round-trips across a re-init of `AppSettings` over the SAME backing store (persists, doesn't just
    /// live in memory).
    @Test @MainActor func glucoseDisplayUnitDefaultsToMgdlAndRoundTripsAcrossReinit() {
        let suiteName = "SettingsCatalogTests.glucoseDisplayUnit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.glucoseDisplayUnit == .mgdl)   // D-03: behavior-preserving default

        fresh.glucoseDisplayUnit = .mmol
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.glucoseDisplayUnit == .mmol)   // persisted across re-init
    }

    // MARK: Owner-requested "Show unit labels" toggle — the setting's registration

    /// Registered `.display`, `backsUp: true`, iCloud ON (a display-format preference, mirroring
    /// `glucoseDisplayUnit`'s reasoning — NOT a per-device ambient-surface toggle like
    /// `liveActivityEnabled`/`glucoseBadgeEnabled`, so it is deliberately excluded from
    /// `ambientSurfaceFlags` above).
    @Test func showGlucoseUnitLabelsIsRegisteredInDisplayWithICloudSyncOn() {
        let d = SettingsCatalog.byKey["showGlucoseUnitLabels"]
        #expect(d != nil, "showGlucoseUnitLabels missing from the catalog")
        #expect(d?.category == .display)
        #expect(d?.backsUp == true)
        #expect(d?.syncsToICloud == true)
        #expect(!SettingsCatalog.commandAdjacentFlags.contains("showGlucoseUnitLabels"))
    }

    /// Default OFF (owner request) on a fresh install, and round-trips across a re-init of
    /// `AppSettings` over the SAME backing store.
    @Test @MainActor func showGlucoseUnitLabelsDefaultsToOffAndRoundTripsAcrossReinit() {
        let suiteName = "SettingsCatalogTests.showGlucoseUnitLabels.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.showGlucoseUnitLabels == false)   // default OFF

        fresh.showGlucoseUnitLabels = true
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.showGlucoseUnitLabels == true)   // persisted across re-init
    }

    // MARK: Phase 09.13-01 (glucose plot height customization, D-01/D-02/D-04) — bound registration

    /// D-04: `.display` category, `backsUp: true` with iCloud ON (a display-format preference, NOT
    /// command-adjacent — same class as `glucoseDisplayUnit`), for BOTH the floor and ceiling keys.
    @Test func glucosePlotBoundsAreRegisteredInDisplayWithICloudSyncOn() {
        for key in ["glucosePlotFloor", "glucosePlotCeiling"] {
            let d = SettingsCatalog.byKey[key]
            #expect(d != nil, "\(key) missing from the catalog")
            #expect(d?.category == .display)
            #expect(d?.backsUp == true)
            #expect(d?.syncsToICloud == true)
            #expect(!SettingsCatalog.commandAdjacentFlags.contains(key))
        }
        #expect(SettingsCatalog.backedUpKeys.isSuperset(of: ["glucosePlotFloor", "glucosePlotCeiling"]))
    }

    /// D-01: defaults floor 40 / ceiling 300 on a fresh install; both persist across a re-init of
    /// `AppSettings` over the SAME backing store.
    @Test @MainActor func glucosePlotBoundsDefaultAndRoundTripAcrossReinit() {
        let suiteName = "SettingsCatalogTests.glucosePlotBounds.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.glucosePlotFloor == 40)      // D-01 default
        #expect(fresh.glucosePlotCeiling == 300)   // D-01 default

        fresh.glucosePlotFloor = 50
        fresh.glucosePlotCeiling = 400
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.glucosePlotFloor == 50)
        #expect(reloaded.glucosePlotCeiling == 400)
    }

    /// D-01/D-10: a legacy/corrupt out-of-set stored ceiling snaps to a safe in-set option (via
    /// `GlucosePlotScale.resolve`) rather than surfacing an invalid value in the UI.
    @Test @MainActor func glucosePlotBoundsSnapOutOfSetStoredValueAtInit() {
        let suiteName = "SettingsCatalogTests.glucosePlotBoundsSnap.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(320, forKey: "glucosePlotCeiling")   // legacy out-of-set value

        let fresh = AppSettings(defaults: defaults)
        #expect(AppSettings.glucosePlotCeilingOptions.contains(fresh.glucosePlotCeiling))
        #expect(fresh.glucosePlotFloor < fresh.glucosePlotCeiling)
    }

    // MARK: Phase 09.13-02 (glucose plot height customization, D-05) — small-screen override registration

    /// D-05: `.remotes` category (like `watchChartRanges`), `backsUp: true`, for BOTH override keys.
    @Test func glucosePlotSmallOverrideIsRegisteredInRemotesWithBacksUpTrue() {
        for key in ["glucosePlotFloorSmall", "glucosePlotCeilingSmall"] {
            let d = SettingsCatalog.byKey[key]
            #expect(d != nil, "\(key) missing from the catalog")
            #expect(d?.category == .remotes)
            #expect(d?.backsUp == true)
            #expect(!SettingsCatalog.commandAdjacentFlags.contains(key))
        }
    }

    /// D-05: fresh install ⇒ both nil ("Same as phone"); setting to nil removes the persisted key; the
    /// pair persists across a re-init of `AppSettings` over the SAME backing store.
    @Test @MainActor func glucosePlotSmallOverrideDefaultsToNilAndRoundTripsAcrossReinit() {
        let suiteName = "SettingsCatalogTests.glucosePlotSmallOverride.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.glucosePlotFloorSmall == nil)      // D-05 default: Same as phone
        #expect(fresh.glucosePlotCeilingSmall == nil)

        fresh.glucosePlotFloorSmall = 50
        fresh.glucosePlotCeilingSmall = 400
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.glucosePlotFloorSmall == 50)
        #expect(reloaded.glucosePlotCeilingSmall == 400)

        reloaded.glucosePlotFloorSmall = nil
        reloaded.glucosePlotCeilingSmall = nil
        #expect(defaults.object(forKey: "glucosePlotFloorSmall") == nil)   // key removed, not just nulled
        #expect(defaults.object(forKey: "glucosePlotCeilingSmall") == nil)
        let afterClear = AppSettings(defaults: defaults)
        #expect(afterClear.glucosePlotFloorSmall == nil)
        #expect(afterClear.glucosePlotCeilingSmall == nil)
    }

    /// D-05/D-10: a legacy/corrupt out-of-set stored override snaps to a safe in-set pair (via
    /// `GlucosePlotScale.resolve`), same guarantee as the shared bounds.
    @Test @MainActor func glucosePlotSmallOverrideSnapsOutOfSetStoredValueAtInit() {
        let suiteName = "SettingsCatalogTests.glucosePlotSmallOverrideSnap.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(320, forKey: "glucosePlotFloorSmall")     // legacy out-of-set value
        defaults.set(320, forKey: "glucosePlotCeilingSmall")

        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.glucosePlotFloorSmall != nil)
        #expect(fresh.glucosePlotCeilingSmall != nil)
        #expect(AppSettings.glucosePlotFloorOptions.contains(fresh.glucosePlotFloorSmall!))
        #expect(AppSettings.glucosePlotCeilingOptions.contains(fresh.glucosePlotCeilingSmall!))
        #expect(fresh.glucosePlotFloorSmall! < fresh.glucosePlotCeilingSmall!)
    }

    /// D-05: the pair is treated as ONE unit — only one of the two keys present on disk (a partial/
    /// corrupt state) is treated as absent (Same as phone), never a half-applied override.
    @Test @MainActor func glucosePlotSmallOverridePartialStoredStateIsTreatedAsAbsent() {
        let suiteName = "SettingsCatalogTests.glucosePlotSmallOverridePartial.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(50, forKey: "glucosePlotFloorSmall")   // only the floor half persisted

        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.glucosePlotFloorSmall == nil)
        #expect(fresh.glucosePlotCeilingSmall == nil)
    }

    /// D-05: `backupSnapshot` emits the override pair ONLY when both are set (conditional, like
    /// `remoteBolusCeiling`); the round-trip preserves a set override.
    @Test @MainActor func glucosePlotSmallOverrideBackupIsConditionalAndRoundTrips() {
        let suiteName = "SettingsCatalogTests.glucosePlotSmallOverrideBackup.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let s = AppSettings(defaults: defaults)

        let offSnapshot = s.backupSnapshot()
        #expect(offSnapshot["glucosePlotFloorSmall"] == nil)
        #expect(offSnapshot["glucosePlotCeilingSmall"] == nil)

        s.glucosePlotFloorSmall = 50
        s.glucosePlotCeilingSmall = 400
        let onSnapshot = s.backupSnapshot()
        #expect(onSnapshot["glucosePlotFloorSmall"] == .int(50))
        #expect(onSnapshot["glucosePlotCeilingSmall"] == .int(400))

        let s2 = AppSettings(defaults: defaults)
        s2.applyBackup(onSnapshot)
        #expect(s2.glucosePlotFloorSmall == 50)
        #expect(s2.glucosePlotCeilingSmall == 400)
    }

    // MARK: Phase 00-04 (INV-02 §6c) — reusable no-dangling-refs / cohesive-UX completeness helper
    //
    // The reusable "no orphaned compile-gated setting" check every later removal phase parametrizes
    // (see `CompileGateAudit` below). SettingsCatalog is already the single source of truth for every
    // persisted key; SettingsIndex is the searchable settings surface. When a phase compiles a surface
    // OUT, any SettingsIndex row that still advertises it is a §6c dangling ref (search would route the
    // user to a feature that no longer exists). Phase 0 removes NO surface, so this is vacuous-green
    // today — the fixture test below proves the helper is NOT a tautology (T-00-09).

    /// Vacuous-green on the CURRENT build: Phase 0 removes NO surface (every `FABOLUS_*` compile gate
    /// defaults present), so the gated-off token set is empty and there are zero orphaned SettingsIndex
    /// rows. Later phases populate `gatedOffSearchTokens` per surface they remove.
    @Test func noOrphanedCompileGatedSettingsOnCurrentBuild() {
        let orphans = CompileGateAudit.orphanedSettingsIndexEntries(
            forGatedOffTokens: CompileGateAudit.gatedOffSearchTokens)
        #expect(orphans.isEmpty,
                "a compile-gated-off feature still has a live SettingsIndex row: \(orphans.map(\.title))")
    }

    /// Non-vacuous proof (T-00-09): the helper is NOT a tautology. Fed a token owned by a STILL-PRESENT
    /// SettingsIndex row, it must flag that row as an orphan. A helper that always returned `[]` — a
    /// tautological pass that would give every later removal phase a false sense of safety — fails here.
    @Test func orphanDetectorIsNonVacuous() {
        let orphans = CompileGateAudit.orphanedSettingsIndexEntries(
            forGatedOffTokens: ["Failover CGM source"])
        #expect(!orphans.isEmpty,
                "the §6c helper must detect a dangling settings row for a removed feature")
        #expect(orphans.contains { $0.title == "Failover CGM source" })
    }

    /// Phase 1, Plan 01 (CGM-05) — the §6c non-vacuous proof for the xDrip removal: the "xdrip" token
    /// was part of the "Failover CGM source" row's keyword string before the trim (RED) and is gone
    /// after it (GREEN) — this is the observed RED→GREEN transition the plan's `<behavior>` block
    /// requires, not a vacuous pass.
    @Test func xdripRemovalLeavesNoOrphanedSettingsIndexEntry() {
        let orphans = CompileGateAudit.orphanedSettingsIndexEntries(forGatedOffTokens: ["xdrip"])
        #expect(orphans.isEmpty,
                "xDrip was removed but a SettingsIndex row still advertises it: \(orphans.map(\.title))")
    }

    /// Phase 1, Plan 02 (CGM-03/CGM-04) — the §6c non-vacuous proof for the G6 + LibreLinkUp removal:
    /// the "libre" token was part of the "CGM account credentials" row's keyword string before the
    /// trim (RED) and is gone after it (GREEN), generalizing the check to both gated-off tokens this
    /// phase has removed so far.
    @Test func g6AndLibreLinkUpRemovalLeavesNoOrphanedSettingsIndexEntry() {
        let orphans = CompileGateAudit.orphanedSettingsIndexEntries(forGatedOffTokens: ["libre", "xdrip"])
        #expect(orphans.isEmpty,
                "G6/LibreLinkUp were removed but a SettingsIndex row still advertises them: \(orphans.map(\.title))")
    }

    /// Phase 6 (06-02/06-03, BACKUP-01) — the §6c non-vacuous proof for the backup/restore removal:
    /// before 06-02, "icloud"/"restore"/"files"/"import" were all part of the "Backup & restore" row's
    /// keyword string; after it (and after 06-02's `.backupRestore` case/tag/link/index removal), no
    /// live `SettingsIndex` OR `SettingsExtraIndex` row advertises any of them. Checked against BOTH
    /// indices — the removed row lived in `SettingsExtraIndex` (the iPad-sidebar extra-row index), not
    /// `SettingsIndex` (the category index `CompileGateAudit` reads) — so this test also proves the
    /// audit tokens don't collide with a still-live `SettingsIndex` row (e.g. "restore"/"icloud"/
    /// "files"/"import" appear in none of its entries either).
    @Test func backupRestoreRemovalLeavesNoOrphanedSettingsIndexEntry() {
        let tokens = Set(["icloud", "restore", "files", "import"])
        let orphans = CompileGateAudit.orphanedSettingsIndexEntries(forGatedOffTokens: tokens)
        #expect(orphans.isEmpty,
                "Backup & restore was removed but a SettingsIndex row still advertises it: \(orphans.map(\.title))")
        let extraOrphans = SettingsExtraIndex.entries.filter { entry in tokens.contains { entry.matches($0) } }
        #expect(extraOrphans.isEmpty,
                "Backup & restore was removed but a SettingsExtraIndex row still advertises it: \(extraOrphans.map(\.title))")
    }
}
