import Testing
import Foundation
@testable import faBolus

/// detailsOrder, watchDetailsOrder, and pillsOrder must keep falling back to their full list when a
/// persisted [] is restored.
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
