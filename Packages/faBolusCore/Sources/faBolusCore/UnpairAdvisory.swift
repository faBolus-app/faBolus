import Foundation

/// P14 S12 (§2.2.3): the unpair-flow advisory. §2.2.3 requires warning the user, before an unpair, that
/// a **Tandem Mobi can only be paired again on its charging base** — so an unpair away from home is a
/// therapy event (no way to reconnect until you're back at the base). That warning is KEPT
/// unconditionally (owner OQ8). Pure and pump-neutral so the copy lives in one place and is testable.
///
/// OQ8 evaluation — forced settings backup before unpair (NOT built, deliberately): an unpair
/// (`forgetPairing`) drops only the pairing bond. App preferences persist locally in `UserDefaults`
/// (untouched by an unpair) and the pump's therapy settings live on the pump itself — neither is lost.
/// A *settings* backup contains neither the pairing bond nor the pump-side therapy values, so forcing
/// one before an unpair would protect nothing that the unpair puts at risk. The real, unavoidable cost
/// is re-pairing (and, for a Mobi, needing the base) — which a backup cannot restore. So there is no
/// settings-loss gap to close: the interlock is the warning, not a forced backup.
public enum UnpairAdvisory {
    /// Whether re-pairing this model needs the charging base — the load-bearing §2.2.3 Mobi warning.
    public static func requiresChargingBaseToRepair(_ model: PumpModel) -> Bool { model == .mobi }

    /// Resolve the model for the unpair warning: prefer the LIVE snapshot model; when it's `.unknown`
    /// (disconnected / the name has cleared), fall back to the persisted offline Mobi signal. C19: that
    /// stored flag is the only offline Mobi signal, so a Mobi still warns about the charging base even
    /// after it has disconnected. `storedIsMobi == nil` (never recorded) ⇒ `.unknown` (plain note). Pure
    /// so the fallback — which the live MockBackend never exercises — is deterministically testable.
    public static func resolvedModel(snapshotModel: PumpModel, storedIsMobi: Bool?) -> PumpModel {
        if snapshotModel != .unknown { return snapshotModel }
        switch storedIsMobi {
        case .some(true):  return .mobi
        case .some(false): return .tslimX2
        case .none:        return .unknown
        }
    }

    /// The unpair confirmation message for a pump model. A Mobi carries the unconditional charging-base
    /// warning; t:slim / unknown get a plain re-pair note (re-pairing is from the pump's own screen).
    public static func confirmationMessage(for model: PumpModel) -> String {
        if requiresChargingBaseToRepair(model) {
            return "This forgets the pump pairing. A Tandem Mobi can only be paired again on its charging "
                + "base — you won't be able to reconnect while away from it. Unpair anyway?"
        }
        return "This forgets the pump pairing. You'll re-pair from the pump's Bluetooth screen. Unpair anyway?"
    }
}
