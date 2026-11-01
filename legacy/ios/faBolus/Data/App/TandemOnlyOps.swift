import Foundation

/// App-layer capability protocol naming the handful of concrete `TandemBackend` hooks that
/// `AppModel` reaches through `source as? TandemOnlyOps`. Lives in the APP layer, not `faBolusCore`,
/// because it names `TandemBackend` by construction — `PumpBackend` itself gains nothing.
///
/// **No behavior change.** Cast sites already fell back to a nil/idle/empty value when `source` was
/// not a `TandemBackend`. `MockBackend` intentionally does NOT conform, so `source as? TandemOnlyOps`
/// is nil for it too — the identical fallback, reached through the protocol cast instead of the
/// concrete-type cast.
///
/// History/diagnostics casts go through `PumpHistoryProviding` / `PumpDiagnosticsProviding`. This
/// protocol is the Tandem-specific residue covered by neither: `pumpIdentityDetail`.
@MainActor
protocol TandemOnlyOps: AnyObject {
    /// The concrete-Tandem-only identity detail feeding `AppModel.currentPumpIdentity()`'s "real"
    /// branch: the paired peripheral's CoreBluetooth UUID, or `"unpaired"` before first pairing. A
    /// non-Tandem backend never reaches this — the `source as? TandemOnlyOps` cast is nil and
    /// `currentPumpIdentity()` falls back on `source.snapshot.isMobi`. Genuinely Tandem-specific.
    var pumpIdentityDetail: String { get }
}
