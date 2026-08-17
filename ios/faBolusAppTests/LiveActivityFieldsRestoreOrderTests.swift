import Testing
import Foundation
@testable import faBolus

/// Phase 09.14 (D-01/WR-04) — `AppSettings.restoreOrder`'s `emptyMeansEmpty` parameter, which lets the
/// `liveActivityFields` restore path distinguish "key absent" (`nil` → fall back to `all`) from "key
/// present but `[]`" (→ honor the explicit empty selection), scoped to the Live Activity field list
/// ONLY. The other three `restoreOrder` consumers (`detailsOrder`/`watchDetailsOrder`/`pillsOrder`)
/// keep falling back to their full list on a persisted `[]` — pinned here as named non-regression
/// tests so a future edit to the shared helper cannot silently change their behavior.
struct LiveActivityFieldsRestoreOrderTests {

    private func freshSuiteName() -> String { "LiveActivityFieldsRestoreOrderTests.\(UUID().uuidString)" }

    // MARK: The fix — an explicit empty LA selection survives a re-init

    /// Setting `liveActivityFields = []` on a fresh instance, then re-initing a second `AppSettings`
    /// over the SAME backing `UserDefaults`, must yield `[]` again — not a silent collapse back to the
    /// full 7-field vocabulary.
    @Test @MainActor func explicitEmptySelectionSurvivesReinit() {
        let suiteName = freshSuiteName()
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fresh = AppSettings(defaults: defaults)
        fresh.liveActivityFields = []

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.liveActivityFields == [])
    }

    // MARK: Non-regression — the other 3 restoreOrder consumers still fall back to `all` on empty

    /// `detailsOrder` persisting `[]` still falls back to the full `detailFields` list on re-init —
    /// completely unaffected by the LA-only `emptyMeansEmpty` fix.
    @Test @MainActor func detailsOrderStillFallsBackToAllFieldsWhenPersistedEmpty() {
        let suiteName = freshSuiteName()
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fresh = AppSettings(defaults: defaults)
        fresh.detailsOrder = []

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.detailsOrder == AppSettings.detailFields)
    }

    /// `watchDetailsOrder` persisting `[]` still falls back to the full `detailFields` list on re-init.
    @Test @MainActor func watchDetailsOrderStillFallsBackToAllFieldsWhenPersistedEmpty() {
        let suiteName = freshSuiteName()
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fresh = AppSettings(defaults: defaults)
        fresh.watchDetailsOrder = []

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.watchDetailsOrder == AppSettings.detailFields)
    }

    /// `pillsOrder` persisting `[]` still falls back to the full `pillItems` list on re-init (its call
    /// site's `?? Self.defaultPills` pre-coalesce never even sees a nil, so the empty-array branch of
    /// `restoreOrder` is exercised the same way it always has been).
    @Test @MainActor func pillsOrderStillFallsBackToAllPillsWhenPersistedEmpty() {
        let suiteName = freshSuiteName()
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fresh = AppSettings(defaults: defaults)
        fresh.pillsOrder = []

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.pillsOrder == AppSettings.pillItems)
    }

    // MARK: Supporting pins — unaffected paths

    /// A fresh install (the `liveActivityFields` key was never set) still resolves to the curated
    /// 3-field starter set — the nil-key fallback is untouched by this fix.
    @Test @MainActor func freshInstallDefaultsToCuratedThreeFieldSet() {
        let suiteName = freshSuiteName()
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.liveActivityFields == AppSettings.defaultLiveActivityFields)
    }

    /// A normal, non-empty custom selection still round-trips exactly across a re-init.
    @Test @MainActor func nonEmptySelectionStillRoundTrips() {
        let suiteName = freshSuiteName()
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fresh = AppSettings(defaults: defaults)
        fresh.liveActivityFields = ["battery", "connection"]

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.liveActivityFields == ["battery", "connection"])
    }
}
