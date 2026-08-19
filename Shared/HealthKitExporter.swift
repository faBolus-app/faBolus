import Foundation
import HealthKit
import faBolusCore

/// Phase 09.23 (D-07/D-08/D-12/D-14): writes faBolus data OUT to Apple Health so the wider
/// ecosystem/clinic tools can consume it. Wave 1 (09.23-01) shipped the tracer's ONE write type
/// (bolus, `.insulinDelivery` with the bolus delivery reason); this file (09.23-03) extends the
/// same shape to Carbs (`.dietaryCarbohydrates`) and Glucose (`.bloodGlucose`) — the full D-14
/// export set. Heart rate is NEVER exported (D-08 — it originates from the user's own sensors; this
/// file has no heart-rate write path at all).
///
/// Both D-12 export cadences exist:
/// - **D-12a automatic go-forward** (`exportNew*`): writes only entries newer than a per-type
///   persisted high-water mark (mirrors `NightscoutUploader.lastBolusEpoch`/`lastEntryMs`), and
///   advances that mark on success — so a relaunch never re-sends an already-written entry.
/// - **D-12b manual backfill** (`exportHistorical*`): a user-invoked one-shot over a caller-supplied
///   historical range, independent of the go-forward marks, reusing the same per-entry write
///   methods (re-writing the SAME entry updates the existing Health sample via the stable
///   sync-identifier rather than duplicating it — Apple's own idempotency idiom).
///
/// Modeled on `NightscoutUploader`'s opt-in/fire-and-forget/`do/catch`-returns-Bool shape. Every
/// write is tagged with the shared origin key (`HealthKitOriginTag.key`) plus Apple's own
/// sync-identifier/version idiom, so `HealthKitHistoryImporter`'s echo-guard filters it back out on
/// the next import (D-12). Every metadata builder and the high-water-mark selector are
/// `nonisolated static` PURE functions — unit-testable without the entitlement
/// (`HealthKitExporterTests`) — and, like the importer, this file is NOT gated behind
/// `#if FABOLUS_HEALTHKIT` (only the pre-existing HealthKit CGM/HR call sites, and the AppModel
/// export hook that drives this class, are — D-13).
///
/// Source: MIT-ported idiom from `github.com/LoopKit/LoopKit`,
/// `LoopKit/InsulinKit/HKQuantitySample+InsulinKit.swift`.
@MainActor
final class HealthKitExporter {
    private let store = HKHealthStore()
    private let insulinType = HKQuantityType(.insulinDelivery)
    private let carbType = HKQuantityType(.dietaryCarbohydrates)
    private let glucoseType = HKQuantityType(.bloodGlucose)
    private let unitsUnit = HKUnit.internationalUnit()
    private let gramUnit = HKUnit.gram()
    private let mgdlUnit = HKUnit(from: "mg/dL")
    private let d: UserDefaults

    init() { d = .standard }

    #if DEBUG
    /// Test seam (WR-01): inject an isolated `UserDefaults` suite so a test can exercise the
    /// per-type high-water-mark seeding/dedup logic in isolation, without polluting the real
    /// `UserDefaults.standard` a production instance reads/writes (mirrors `AppSettings
    /// (defaults:)`'s injectable-suite idiom). Production never calls this.
    init(defaults: UserDefaults) { d = defaults }
    #endif

    /// Additively request WRITE (share) access to exactly the given type(s) — never a read type.
    /// Requested lazily on each export attempt (not a persisted one-shot guard, so a permission that
    /// flips to granted mid-session is still picked up by the very next export) — exports are
    /// already throttled/opt-in at the call site.
    private func requestAuthorization(share types: Set<HKSampleType>) async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do {
            try await store.requestAuthorization(toShare: types, read: [])
            return true
        } catch {
            return false
        }
    }

    // MARK: - Insulin/bolus export (Wave 1 tracer)

    /// Writes a single bolus to Apple Health, origin-tagged (D-12) so the importer's echo-guard
    /// drops it on the next import. Degrades silently on denied/unavailable/save-failure — never
    /// throws, never retries (mirrors `NightscoutUploader.post`'s `do/catch`-returns-Bool shape).
    func exportBolus(_ marker: BolusMarker) async -> Bool {
        guard await requestAuthorization(share: [insulinType]) else { return false }
        let quantity = HKQuantity(unit: unitsUnit, doubleValue: marker.units)
        let metadata = Self.bolusMetadata(date: marker.date, units: marker.units)
        let sample = HKQuantitySample(type: insulinType, quantity: quantity,
                                      start: marker.date, end: marker.date, metadata: metadata)
        do {
            try await store.save(sample)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Carbs export (D-14) — no `HKMetadataKeyInsulinDeliveryReason`, carbs carry no such concept

    /// Writes a single carb entry to Apple Health, origin-tagged (D-12). Mirrors `exportBolus`'s
    /// shape exactly, minus the insulin-delivery-reason metadata.
    func exportCarbs(_ entry: (date: Date, grams: Double)) async -> Bool {
        guard await requestAuthorization(share: [carbType]) else { return false }
        let quantity = HKQuantity(unit: gramUnit, doubleValue: entry.grams)
        let metadata = Self.carbMetadata(date: entry.date, grams: entry.grams)
        let sample = HKQuantitySample(type: carbType, quantity: quantity,
                                      start: entry.date, end: entry.date, metadata: metadata)
        do {
            try await store.save(sample)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Glucose export (D-14)

    /// Writes a single glucose reading to Apple Health, origin-tagged (D-12). Mirrors `exportBolus`'s
    /// shape exactly.
    func exportGlucose(_ reading: GlucoseReading) async -> Bool {
        guard await requestAuthorization(share: [glucoseType]) else { return false }
        let quantity = HKQuantity(unit: mgdlUnit, doubleValue: Double(reading.mgdl))
        let metadata = Self.glucoseMetadata(date: reading.date, mgdl: reading.mgdl)
        let sample = HKQuantitySample(type: glucoseType, quantity: quantity,
                                      start: reading.date, end: reading.date, metadata: metadata)
        do {
            try await store.save(sample)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Per-type high-water-mark dedup (D-12a automatic go-forward export) — mirrors
    // NightscoutUploader.lastBolusEpoch/lastEntryMs: one persisted mark per exported type so
    // automatic export never re-sends an already-written entry after an app relaunch.

    private var lastCarbExportEpoch: Double {
        get { d.double(forKey: "hk.export.lastCarbEpoch") } set { d.set(newValue, forKey: "hk.export.lastCarbEpoch") }
    }
    private var lastInsulinExportEpoch: Double {
        get { d.double(forKey: "hk.export.lastInsulinEpoch") } set { d.set(newValue, forKey: "hk.export.lastInsulinEpoch") }
    }
    private var lastGlucoseExportEpoch: Double {
        get { d.double(forKey: "hk.export.lastGlucoseEpoch") } set { d.set(newValue, forKey: "hk.export.lastGlucoseEpoch") }
    }

    /// D-12a: writes ONLY carb entries newer than the carb high-water mark, advancing the mark to
    /// the newest exported entry on any success (mirrors `NightscoutUploader.run`'s "filter-newer,
    /// advance-on-success" shape). WR-01: on the type's very first-ever auto-export cycle (mark
    /// still unset), seeds the mark to "now" and exports nothing THIS cycle — see
    /// `firstCycleSeedMark`.
    func exportNewCarbs(_ candidates: [(date: Date, grams: Double)]) async {
        if let seed = Self.firstCycleSeedMark(currentMark: lastCarbExportEpoch) {
            lastCarbExportEpoch = seed
            return
        }
        let (kept, newMark) = Self.newerThanMark(candidates, mark: lastCarbExportEpoch) { $0.date.timeIntervalSince1970 }
        guard !kept.isEmpty else { return }
        var anySucceeded = false
        for entry in kept {
            if await exportCarbs(entry) { anySucceeded = true }
        }
        if anySucceeded { lastCarbExportEpoch = newMark }
    }

    /// D-12a: writes ONLY bolus markers newer than the insulin high-water mark, advancing the mark
    /// on any success. Same shape as `exportNewCarbs` (incl. the WR-01 first-cycle seed), driving
    /// the Wave 1 `exportBolus` writer.
    func exportNewInsulin(_ candidates: [BolusMarker]) async {
        if let seed = Self.firstCycleSeedMark(currentMark: lastInsulinExportEpoch) {
            lastInsulinExportEpoch = seed
            return
        }
        let (kept, newMark) = Self.newerThanMark(candidates, mark: lastInsulinExportEpoch) { $0.date.timeIntervalSince1970 }
        guard !kept.isEmpty else { return }
        var anySucceeded = false
        for marker in kept {
            if await exportBolus(marker) { anySucceeded = true }
        }
        if anySucceeded { lastInsulinExportEpoch = newMark }
    }

    /// D-12a: writes ONLY glucose readings newer than the glucose high-water mark, advancing the
    /// mark on any success. Same shape as `exportNewCarbs` (incl. the WR-01 first-cycle seed).
    func exportNewGlucose(_ candidates: [GlucoseReading]) async {
        if let seed = Self.firstCycleSeedMark(currentMark: lastGlucoseExportEpoch) {
            lastGlucoseExportEpoch = seed
            return
        }
        let (kept, newMark) = Self.newerThanMark(candidates, mark: lastGlucoseExportEpoch) { $0.date.timeIntervalSince1970 }
        guard !kept.isEmpty else { return }
        var anySucceeded = false
        for reading in kept {
            if await exportGlucose(reading) { anySucceeded = true }
        }
        if anySucceeded { lastGlucoseExportEpoch = newMark }
    }

    // MARK: - Manual historical backfill (D-12b) — a user-invoked one-shot over an explicit
    // caller-supplied range, independent of the D-12a go-forward high-water marks above. Reuses the
    // same per-entry write methods; the stable sync-identifier means re-exporting an entry already
    // in Health updates it rather than duplicating it.

    func exportHistoricalCarbs(_ entries: [(date: Date, grams: Double)]) async {
        for entry in entries { _ = await exportCarbs(entry) }
    }

    func exportHistoricalInsulin(_ markers: [BolusMarker]) async {
        for marker in markers { _ = await exportBolus(marker) }
    }

    func exportHistoricalGlucose(_ readings: [GlucoseReading]) async {
        for reading in readings { _ = await exportGlucose(reading) }
    }

    // MARK: - Pure metadata builders (D-12) — unit-testable without the entitlement

    /// Stable sync-identifier derived from `(date, units)` — re-writing the SAME bolus updates the
    /// existing Health sample instead of duplicating it (Apple's own sync-identifier idiom).
    nonisolated static func syncIdentifier(date: Date, units: Double) -> String {
        "fabolus-bolus-\(Int(date.timeIntervalSince1970))-\(units)"
    }

    /// The bolus write's metadata dictionary: insulin-delivery-reason (bolus), sync-identifier +
    /// version (Apple's update/idempotency idiom), and the shared origin tag (D-12).
    nonisolated static func bolusMetadata(date: Date, units: Double) -> [String: Any] {
        [
            HKMetadataKeySyncVersion: 1,
            HKMetadataKeySyncIdentifier: Self.syncIdentifier(date: date, units: units),
            HealthKitOriginTag.key: true,
            HKMetadataKeyInsulinDeliveryReason: HKInsulinDeliveryReason.bolus.rawValue,
        ]
    }

    /// Stable sync-identifier derived from `(date, grams)` — re-exporting the SAME carb entry
    /// updates the existing Health sample instead of duplicating it.
    nonisolated static func carbSyncIdentifier(date: Date, grams: Double) -> String {
        "fabolus-carb-\(Int(date.timeIntervalSince1970))-\(grams)"
    }

    /// The carb write's metadata dictionary: sync-identifier + version + the shared origin tag
    /// (D-12). Deliberately carries NO `HKMetadataKeyInsulinDeliveryReason` — carbs are not insulin
    /// deliveries.
    nonisolated static func carbMetadata(date: Date, grams: Double) -> [String: Any] {
        [
            HKMetadataKeySyncVersion: 1,
            HKMetadataKeySyncIdentifier: Self.carbSyncIdentifier(date: date, grams: grams),
            HealthKitOriginTag.key: true,
        ]
    }

    /// Stable sync-identifier derived from `(date, mgdl)` — re-exporting the SAME glucose reading
    /// updates the existing Health sample instead of duplicating it.
    nonisolated static func glucoseSyncIdentifier(date: Date, mgdl: Int) -> String {
        "fabolus-glucose-\(Int(date.timeIntervalSince1970))-\(mgdl)"
    }

    /// The glucose write's metadata dictionary: sync-identifier + version + the shared origin tag
    /// (D-12).
    nonisolated static func glucoseMetadata(date: Date, mgdl: Int) -> [String: Any] {
        [
            HKMetadataKeySyncVersion: 1,
            HKMetadataKeySyncIdentifier: Self.glucoseSyncIdentifier(date: date, mgdl: mgdl),
            HealthKitOriginTag.key: true,
        ]
    }

    // MARK: - Pure per-type high-water-mark selector (D-12a) — unit-testable without the entitlement

    /// Given candidate entries and a type's persisted high-water mark, returns only the entries
    /// newer than the mark plus the mark's NEXT value (the newest kept candidate's epoch, or the
    /// mark unchanged when nothing qualifies) — mirrors `NightscoutUploader.run`'s inline
    /// filter-then-`.max() ?? lastMark` idiom, generalized across every exported type via a
    /// caller-supplied epoch extractor so one function serves carbs/insulin/glucose alike.
    nonisolated static func newerThanMark<T>(_ candidates: [T], mark: Double,
                                             epoch: (T) -> Double) -> (kept: [T], newMark: Double) {
        let kept = candidates.filter { epoch($0) > mark }
        let newMark = kept.map(epoch).max() ?? mark
        return (kept, newMark)
    }

    // MARK: - WR-01: go-forward-only guard for a type's first-ever auto-export cycle — unit-testable
    // without the entitlement, same PURE `nonisolated static` shape as `newerThanMark`.

    /// `UserDefaults.double(forKey:)`'s unset default is `0`, which `newerThanMark` would otherwise
    /// read as "every existing entry is newer than the mark" — silently backfilling a type's ENTIRE
    /// history the first time its auto-export toggle is enabled (WR-01: auto-export must be
    /// go-forward only per D-12; historical backfill is the explicit MANUAL `exportHistorical*`
    /// action). Returns the value to seed the mark to (== `now`, exporting nothing this cycle) when
    /// `currentMark` is still at that unset default; returns `nil` when a real mark already exists
    /// (a later cycle), so the caller falls through to `newerThanMark` as normal.
    nonisolated static func firstCycleSeedMark(currentMark: Double, now: Double = Date().timeIntervalSince1970) -> Double? {
        currentMark == 0 ? now : nil
    }
}
