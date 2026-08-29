import Foundation

/// §2.2.3: the unpair-flow advisory. §2.2.3 requires warning the user, before an unpair, that
/// a **Tandem Mobi can only be paired again on its charging base** — so an unpair away from home is a
/// therapy event (no way to reconnect until you're back at the base). That warning is KEPT
/// unconditionally. Pure and pump-neutral so the copy lives in one place and is testable.
///
/// §2.2.3 backup gate (owner decision 2026-08-09) — the unpair flow now OFFERS a settings backup, or
/// an explicit skip, BEFORE it completes. This supersedes the earlier "no forced backup" reading for a
/// reason that evaluation under-weighted: an unpair is frequently a prelude to **switching or replacing** a
/// pump (see the pump-switch settings reset), and a pump's therapy settings live only on that pump
/// — once it is unpaired and gone they cannot be re-read. A settings backup taken while still connected
/// captures the pump's therapy values (carb ratios / correction factors / targets / limits, for manual
/// re-entry or a Mobi reconfigure) AND the app's own preferences — so it DOES protect something the
/// unpair-to-switch puts at risk. (The earlier reasoning holds only for re-pairing the *same* pump, where
/// nothing is lost.) The gate never blocks: "skip backup" is always available as an explicit, acknowledged
/// choice, and the charging-base warning below is still shown at the final confirm.
public enum UnpairAdvisory {
    /// Whether re-pairing this model needs the charging base — the load-bearing §2.2.3 Mobi warning.
    public static func requiresChargingBaseToRepair(_ model: PumpModel) -> Bool { model == .mobi }

    // MARK: §2.2.3 backup gate — step 1 of the two-step unpair flow (A4)

    /// The two ordered steps the unpair flow must present: the backup-or-skip choice ALWAYS precedes the
    /// model-appropriate confirm, so an unpair can never complete without the user having made a
    /// backup-or-skip choice first. Pure so the gate's presence + ordering is testable without the UI.
    public enum Step: Equatable, Sendable { case backupChoice, confirm }
    public static let steps: [Step] = [.backupChoice, .confirm]

    /// Copy for the step-1 backup prompt. `skipBackup` is the explicit acknowledgment (never a default).
    public static let backupPromptTitle = "Back up your settings first?"
    public static let backupPromptMessage =
        "Backing up now saves your app settings and a snapshot of this pump's therapy settings (carb "
        + "ratios, correction factors, targets, limits) to a file — worth doing if you're switching or "
        + "replacing pumps, because those settings live only on the pump and can't be re-read once it's "
        + "unpaired."
    public static let backUpNowLabel = "Back up settings"
    public static let skipBackupLabel = "Skip backup and continue"

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
