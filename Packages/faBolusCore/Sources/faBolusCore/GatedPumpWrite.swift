import Foundation

/// The authoritative, enumerated set of every consequential pump-**write** entry point reachable through
/// `AppModel`, each tagged with the access gate it currently routes through. This is the declared set that
/// round-3 **R3-F** introduces as the **seed for phase P8** — the single policy evaluator. P8 enumerates
/// every (surface × action) pair against this list, so no consequential action can exist without a decided
/// gate, and `everyTherapyWriteEntryPointIsCentrallyGated` derives its ack-gated coverage from it (so the
/// test and the declared set cannot silently drift).
///
/// `rawValue` is the `AppModel` method name. This records the **current** routing, not an aspiration —
/// where the present gate is weaker than one might expect it is called out below, not hidden.
///
/// **Not included:** `setPumpSounds` — a signed `PumpBackend` method with **no `AppModel` entry point**
/// today (nothing surfaces it, so it is not a reachable action; add a case when it is surfaced) — and the
/// pure reads (`refresh*`, `reconcile`, `readG6TransmitterId`), which mutate nothing.
public enum GatedPumpWrite: String, CaseIterable, Sendable {
    // Delivery — durable idempotency ledger + global delivery block (`runLedgeredDelivery`).
    case deliverBolus, deliverExtendedBolus

    // Child-mode ONLY — signed writes gated by child mode but deliberately NOT read-only-blocked:
    // cancelling is a safety STOP that must stay available to a read-only viewer, and clearing an alert is
    // low-risk. Phase P12's `BolusGate` formally reviews `cancelBolus`; recorded here so the gap isn't lost.
    case cancelBolus, dismissNotification

    // Unverified-therapy acknowledgment (`runGatedTherapy`) — the 8 IDP-CRUD + CGM-high/low writes.
    case createProfile, setActiveProfile, renameProfile, deleteProfile
    case addProfileSegment, modifyProfileSegment, deleteProfileSegment, setCgmHighLowAlert

    // Child-mode + phone read-only interlock (`runControl`) — every other insulin-affecting / therapy write.
    case suspendDelivery, resumeDelivery, setTempBasal, stopTempBasal, setMode, playFindMyPump
    case startG6Session, startG7Session, setSensorType, stopCgmSession
    case enterChangeCartridgeMode, exitChangeCartridgeMode, enterFillTubingMode, exitFillTubingMode, fillCannula
    case setMaxBolus, setMaxBasal, syncTimeToNow, setControlIQ
    case setLowInsulinAlert, setAutoOffAlert, setSiteChangeReminder, setAlertSnooze
    case setCgmOutOfRangeAlert, setCgmRiseFallAlert

    /// The access gate an action currently routes through in `AppModel`.
    public enum Gate: String, Sendable, CaseIterable {
        case ledgeredDelivery   // runLedgeredDelivery: durable idempotency + global delivery block
        case unverifiedAck      // runGatedTherapy: one-shot untested-feature ack (wraps runControl)
        case controlInterlock   // runControl: child-mode + phone read-only
        case childOnly          // child-mode only (NOT read-only) — see the note above
    }

    /// The gate this action currently routes through. The `switch` is exhaustive, so adding a case without
    /// classifying it is a compile error — the enumeration and its gating cannot drift apart.
    public var gate: Gate {
        switch self {
        case .deliverBolus, .deliverExtendedBolus:
            return .ledgeredDelivery
        case .cancelBolus, .dismissNotification:
            return .childOnly
        case .createProfile, .setActiveProfile, .renameProfile, .deleteProfile,
             .addProfileSegment, .modifyProfileSegment, .deleteProfileSegment, .setCgmHighLowAlert:
            return .unverifiedAck
        case .suspendDelivery, .resumeDelivery, .setTempBasal, .stopTempBasal, .setMode, .playFindMyPump,
             .startG6Session, .startG7Session, .setSensorType, .stopCgmSession,
             .enterChangeCartridgeMode, .exitChangeCartridgeMode, .enterFillTubingMode, .exitFillTubingMode, .fillCannula,
             .setMaxBolus, .setMaxBasal, .syncTimeToNow, .setControlIQ,
             .setLowInsulinAlert, .setAutoOffAlert, .setSiteChangeReminder, .setAlertSnooze,
             .setCgmOutOfRangeAlert, .setCgmRiseFallAlert:
            return .controlInterlock
        }
    }
}
