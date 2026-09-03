import Foundation

/// §2.2.3: the unpair-flow advisory. §2.2.3 requires warning the user, before an unpair, that
/// a **Tandem Mobi can only be paired again on its charging base** — so an unpair away from home is a
/// therapy event (no way to reconnect until you're back at the base). That warning is KEPT
/// unconditionally. Pure and pump-neutral so the copy lives in one place and is testable.
///
/// A settings-backup step was designed for the unpair flow (an unpair is frequently a prelude to
/// switching or replacing a pump, and a pump's therapy settings can't be re-read once it's unpaired), but
/// that backup-or-skip step and its copy were never shipped and have been removed; only the
/// charging-base confirm below runs.
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
        case .some(true): return .mobi
        case .some(false): return .tslimX2
        case .none: return .unknown
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
