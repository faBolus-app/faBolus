import Testing
import Foundation
import HistoryStore
import faBolusCore
@testable import faBolus

/// Phase 09.18a-04 — SiteAtlas body-map UI + default-ON toggle.
///
/// Covers (a) the vendored age-state / reuse-window helpers the markers depend on, (b) a persistence
/// round-trip through `SiteAtlasStore` over an in-memory `GlucoseHistoryStore` (add → list → delete),
/// (c) input-validation at the store trust boundary (coord clamp + note bound, T-09.18a-12), (d) the
/// advisory reuse-window proximity check, and (e) the `siteAtlasEnabled` default-ON + round-trip.
struct SiteAtlasTests {

    // MARK: - Age-state / reuse-window helpers (SiteAtlas_Theme)

    @Test func safeReuseWindowIsTypeSpecific() {
        #expect(SiteAtlas_Theme.safeReuseDays(for: .pump) == 10)
        #expect(SiteAtlas_Theme.safeReuseDays(for: .sensor) == 5)
    }

    @Test func ageOpacityFadesFromFreshToSafeReuse() {
        // Fresh = fully opaque; at/after the window = fully faded; midway = partial.
        #expect(SiteAtlas_Theme.ageOpacity(daysSincePlaced: 0, type: .pump) == 1.0)
        #expect(SiteAtlas_Theme.ageOpacity(daysSincePlaced: 10, type: .pump) == 0.0)
        #expect(SiteAtlas_Theme.ageOpacity(daysSincePlaced: 20, type: .pump) == 0.0)   // clamped
        let mid = SiteAtlas_Theme.ageOpacity(daysSincePlaced: 5, type: .pump)
        #expect(mid > 0.4 && mid < 0.6)
    }

    @Test func shouldDisplayHidesPastTheReuseWindow() {
        #expect(SiteAtlas_Theme.shouldDisplayOnBodyMap(daysSincePlaced: 4, type: .sensor) == true)
        #expect(SiteAtlas_Theme.shouldDisplayOnBodyMap(daysSincePlaced: 5, type: .sensor) == false)
        #expect(SiteAtlas_Theme.shouldDisplayOnBodyMap(daysSincePlaced: 9, type: .pump) == true)
        #expect(SiteAtlas_Theme.shouldDisplayOnBodyMap(daysSincePlaced: 10, type: .pump) == false)
    }

    // MARK: - Persistence round-trip through the store adapter

    @MainActor
    private func makeStore() -> SiteAtlasStore {
        SiteAtlasStore(history: try! GlucoseHistoryStore(inMemory: true))
    }

    @MainActor @Test func addListDeleteRoundTrips() {
        let store = makeStore()
        #expect(store.allSites().isEmpty)

        let id = store.add(type: .pump, bodySide: .front, normalizedX: 0.5, normalizedY: 0.4, note: "left")
        let all = store.allSites()
        #expect(all.count == 1)
        let site = all[0]
        #expect(site.id == id)
        #expect(site.type == .pump)
        #expect(site.bodySide == .front)
        #expect(site.note == "left")

        store.delete(id: id)
        #expect(store.allSites().isEmpty)
    }

    @MainActor @Test func sitesFilterByBodySide() {
        let store = makeStore()
        store.add(type: .pump, bodySide: .front, normalizedX: 0.5, normalizedY: 0.4)
        store.add(type: .sensor, bodySide: .back, normalizedX: 0.4, normalizedY: 0.5)
        #expect(store.sites(on: .front).count == 1)
        #expect(store.sites(on: .back).count == 1)
        #expect(store.sites(on: .front).first?.type == .pump)
    }

    // MARK: - V5 input validation at the trust boundary (T-09.18a-12)

    @MainActor @Test func outOfBoundsCoordsAreClamped() {
        let store = makeStore()
        store.add(type: .pump, bodySide: .front, normalizedX: 1.9, normalizedY: -0.5)
        let site = store.allSites()[0]
        #expect(site.normalizedX == 1.0)
        #expect(site.normalizedY == 0.0)
    }

    @MainActor @Test func longNoteIsBoundedAndBlankCollapsesToNil() {
        let store = makeStore()
        let idLong = store.add(type: .sensor, bodySide: .back, normalizedX: 0.5, normalizedY: 0.5,
                               note: String(repeating: "x", count: 2000))
        let idBlank = store.add(type: .pump, bodySide: .front, normalizedX: 0.2, normalizedY: 0.2,
                                note: "   \n ")
        let byId = Dictionary(uniqueKeysWithValues: store.allSites().map { ($0.id, $0) })
        #expect((byId[idLong]?.note?.count ?? 0) == SiteAtlasStore.maxNoteLength)
        #expect(byId[idBlank]?.note == nil)
    }

    // MARK: - Advisory reuse-window proximity (non-blocking)

    @MainActor @Test func reuseAdvisoryFiresForNearbyRecentSameKindOnly() {
        let store = makeStore()
        store.add(type: .pump, bodySide: .front, normalizedX: 0.50, normalizedY: 0.40)   // fresh, today

        // Same kind, nearby → advisory.
        #expect(store.recentNearbySite(type: .pump, bodySide: .front,
                                       normalizedX: 0.52, normalizedY: 0.41) != nil)
        // Different kind, same spot → no advisory.
        #expect(store.recentNearbySite(type: .sensor, bodySide: .front,
                                       normalizedX: 0.50, normalizedY: 0.40) == nil)
        // Same kind, far away → no advisory.
        #expect(store.recentNearbySite(type: .pump, bodySide: .front,
                                       normalizedX: 0.10, normalizedY: 0.90) == nil)
        // Same kind + spot, but on the other body side → no advisory.
        #expect(store.recentNearbySite(type: .pump, bodySide: .back,
                                       normalizedX: 0.50, normalizedY: 0.40) == nil)
    }

    @MainActor @Test func reuseAdvisoryIgnoresSitesPastTheReuseWindow() {
        let store = makeStore()
        let old = Calendar.current.date(byAdding: .day, value: -20, to: Date())!
        store.add(type: .pump, bodySide: .front, normalizedX: 0.5, normalizedY: 0.4, date: old)
        // 20 days > pump 10-day window → the aged site no longer triggers the advisory.
        #expect(store.recentNearbySite(type: .pump, bodySide: .front,
                                       normalizedX: 0.5, normalizedY: 0.4) == nil)
    }

    // MARK: - Task 2: siteAtlasEnabled default-ON + round-trip

    @MainActor @Test func siteAtlasEnabledDefaultsOnAndRoundTripsAcrossReinit() {
        let suiteName = "SiteAtlasTests.siteAtlasEnabled.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.siteAtlasEnabled == true)   // D-17: discoverable / on

        fresh.siteAtlasEnabled = false
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.siteAtlasEnabled == false)   // persisted across re-init
    }

    @MainActor @Test func siteAtlasEnabledBacksUpAndRestores() {
        let suiteName = "SiteAtlasTests.siteAtlasBackup.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let s = AppSettings(defaults: defaults)
        s.siteAtlasEnabled = false
        let snapshot = s.backupSnapshot()
        #expect(snapshot["siteAtlasEnabled"] == .bool(false))

        let s2 = AppSettings(defaults: defaults)
        s2.siteAtlasEnabled = true
        s2.applyBackup(snapshot)
        #expect(s2.siteAtlasEnabled == false)   // restored from the backup
    }

    // MARK: - One-time "About Smart Features" explainer ack (D-16)

    @MainActor @Test func smartFeaturesNoticeAckIsOneShot() {
        let suiteName = "SiteAtlasTests.smartFeaturesAck.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let s = AppSettings(defaults: defaults)
        #expect(s.hasAcknowledgedSmartFeaturesNotice == false)
        s.acknowledgeSmartFeaturesNotice()
        #expect(s.hasAcknowledgedSmartFeaturesNotice == true)
        let firstAck = s.smartFeaturesNoticeAckAt
        s.acknowledgeSmartFeaturesNotice()   // second call must not move the timestamp
        #expect(s.smartFeaturesNoticeAckAt == firstAck)
    }

    // MARK: - WR-01: SiteAtlas backup → restore round-trip

    /// Proves the end-to-end wiring: N placements snapshot into a backup section, survive a full
    /// `FaBolusBackup` encode/decode, and restore into a SEPARATE empty store — the misleading
    /// delete-copy ("removed from your history and backup") is now true. Exercises the exact
    /// `AppModel.siteAtlasBackup()` / `restoreSiteAtlas(_:)` methods that `BackupRestoreView` calls.
    @MainActor @Test func siteAtlasBacksUpAndRestoresIntoAnEmptyStore() throws {
        // Source model + N placements in its (in-memory) shared store.
        let source = AppModel(source: MockBackend())
        let srcStore = try GlucoseHistoryStore(inMemory: true)
        source.setHistoryStoreForTesting(srcStore)
        let logger = SiteAtlasStore(history: srcStore)
        let id1 = logger.add(type: .pump, bodySide: .front, normalizedX: 0.58, normalizedY: 0.44,
                             note: "left abdomen", date: Date(timeIntervalSince1970: 1_700_000_000))
        let id2 = logger.add(type: .sensor, bodySide: .back, normalizedX: 0.30, normalizedY: 0.25,
                             note: nil, date: Date(timeIntervalSince1970: 1_700_100_000))
        #expect(logger.allSites().count == 2)

        // Snapshot into the backup section (what createBackup writes) and round-trip the whole envelope.
        let section = source.siteAtlasBackup()
        #expect(section.entries.count == 2)
        let meta = FaBolusBackup.Meta(createdAt: Date(), appVersion: "test",
                                      pumpModel: "mobi", deviceName: "test")
        let decoded = try FaBolusBackup.decode(FaBolusBackup(meta: meta, siteAtlas: section).encoded())
        let restoredSection = try #require(decoded.siteAtlas)

        // Restore into a DIFFERENT, empty model/store (what RestoreSheet does).
        let dest = AppModel(source: MockBackend())
        let destStore = try GlucoseHistoryStore(inMemory: true)
        dest.setHistoryStoreForTesting(destStore)
        let destLogger = SiteAtlasStore(history: destStore)
        #expect(destLogger.allSites().isEmpty)

        dest.restoreSiteAtlas(restoredSection)

        // All N placements are present, with identity + fields preserved across the round-trip.
        let restored = destLogger.allSites()
        #expect(restored.count == 2)
        let byId = Dictionary(uniqueKeysWithValues: restored.map { ($0.id, $0) })
        #expect(byId[id1]?.type == .pump)
        #expect(byId[id1]?.bodySide == .front)
        #expect(byId[id1]?.note == "left abdomen")
        #expect(byId[id2]?.type == .sensor)
        #expect(byId[id2]?.bodySide == .back)
        #expect(byId[id2]?.note == nil)
    }
}
