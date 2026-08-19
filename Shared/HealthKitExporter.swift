import Foundation
import HealthKit
import faBolusCore

/// Phase 09.23 (D-07/D-08/D-12/D-14, the phase TRACER's write side): writes faBolus data OUT to
/// Apple Health so the wider ecosystem/clinic tools can consume it. This tracer ships ONE write
/// type (bolus, `.insulinDelivery` with the bolus delivery reason); Waves 2-3 extend the same shape
/// to Carbs and Glucose (D-14 — Heart rate is READ-ONLY, never exported; it originates from the
/// user's own sensors).
///
/// Modeled on `NightscoutUploader`'s opt-in/fire-and-forget/`do/catch`-returns-Bool shape. Every
/// write is tagged with the shared origin key (`HealthKitOriginTag.key`) plus Apple's own
/// sync-identifier/version idiom, so `HealthKitHistoryImporter`'s echo-guard filters it back out on
/// the next import (D-12). The metadata builder is a `nonisolated static` PURE function —
/// unit-testable without the entitlement (`HealthKitTracerTests`) — and, like the importer, is NOT
/// gated behind `#if FABOLUS_HEALTHKIT` (only the pre-existing HealthKit CGM/HR call sites are —
/// D-13).
///
/// Source: MIT-ported idiom from `github.com/LoopKit/LoopKit`,
/// `LoopKit/InsulinKit/HKQuantitySample+InsulinKit.swift`.
@MainActor
final class HealthKitExporter {
    private let store = HKHealthStore()
    private let insulinType = HKQuantityType(.insulinDelivery)
    private let unitsUnit = HKUnit.internationalUnit()

    init() {}

    /// Additively request WRITE (share) access to `.insulinDelivery` only — never a read type here.
    /// Requested lazily on each export attempt (not a persisted one-shot guard, so a permission that
    /// flips to granted mid-session is still picked up by the very next export) rather than
    /// `HealthKitHeartRateSource`'s persisted-guard shape, which exists there to avoid a redundant
    /// async hop on every scrub; exports are already throttled/opt-in at the call site.
    private func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        do {
            try await store.requestAuthorization(toShare: [insulinType], read: [])
            return true
        } catch {
            return false
        }
    }

    /// Writes a single bolus to Apple Health, origin-tagged (D-12) so the importer's echo-guard
    /// drops it on the next import. Degrades silently on denied/unavailable/save-failure — never
    /// throws, never retries (mirrors `NightscoutUploader.post`'s `do/catch`-returns-Bool shape).
    func exportBolus(_ marker: BolusMarker) async -> Bool {
        guard await requestAuthorization() else { return false }
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

    // MARK: - Pure metadata builder (D-12) — unit-testable without the entitlement

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
}
