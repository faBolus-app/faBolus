import Foundation
import faBolusCore

/// No-op Nightscout upload/backfill. The real implementations live on `dev/nightscout`. This stub
/// preserves `AppModel`'s two call-site contracts: `NightscoutUploader.shared.sync(...)` and
/// `NightscoutBackfill.fetch()` (inside `maybeBackfillNightscout()`). Exactly one
/// `NightscoutUploader`/`NightscoutBackfill` symbol exists on any given branch.
///
/// `NightscoutSource` (the glucose-polling source) is NOT stubbed here — it has zero references from
/// the dose-frozen set and is removed via the `GlucoseSourceRegistry` descriptor deletion.
@MainActor
final class NightscoutUploader {
    static let shared = NightscoutUploader()
    private init() {}

    /// No-op — Nightscout upload is not on this branch. Never touches history/dose
    /// state; never performs a network call. Signature matches the real implementation exactly
    /// (plain, non-`async`, non-`throws`) so the frozen `AppModel` call site still compiles.
    func sync(snapshot: PumpSnapshot, glucose: [GlucoseReading], boluses: [BolusMarker]) {
        // no-op — Nightscout upload is not on this branch
    }
}

/// Stub for `AppModel.maybeBackfillNightscout()`. `fetch()` always
/// returns nil, so the frozen closure's `guard let r = await NightscoutBackfill.fetch() else { return }`
/// exits immediately and the `r.carbs`/`r.insulin` reads inside are unreachable — but the `Result`
/// type must still type-check against the frozen closure, hence the exact field-name/type match to
/// the real `NightscoutBackfill.Result`.
enum NightscoutBackfill {
    struct Result {
        var carbs: [(date: Date, grams: Double)] = []
        var insulin: [(date: Date, units: Double)] = []
    }

    /// No-op — always returns nil. Never performs a network call, never touches history/dose state.
    static func fetch(days: Int = 30) async -> Result? { nil }
}
