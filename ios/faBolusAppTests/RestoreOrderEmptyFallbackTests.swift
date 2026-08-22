import Testing
import Foundation
@testable import faBolus

/// Phase 09.14 (D-01/WR-04) — `AppSettings.restoreOrder`'s `emptyMeansEmpty` parameter was originally
/// added so the (now-removed) `liveActivityFields` restore path could distinguish "key absent" (`nil`
/// → fall back to `all`) from "key present but `[]`" (→ honor the explicit empty selection). Live
/// Activity, and this file's 3 `liveActivityFields`-specific tests, were removed in Phase 7 (07-01,
/// FEAT-01) — renamed from `LiveActivityFieldsRestoreOrderTests.swift`. What remains is the
/// non-regression coverage for the shared `restoreOrder` helper's OTHER 3 consumers
/// (`detailsOrder`/`watchDetailsOrder`/`pillsOrder`), which keep falling back to their full list on a
/// persisted `[]` and must never silently change that behavior.
struct RestoreOrderEmptyFallbackTests {

    private func freshSuiteName() -> String { "RestoreOrderEmptyFallbackTests.\(UUID().uuidString)" }

    // MARK: Non-regression — the 3 restoreOrder consumers still fall back to `all` on empty

    /// `detailsOrder` persisting `[]` still falls back to the full `detailFields` list on re-init.
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
}
