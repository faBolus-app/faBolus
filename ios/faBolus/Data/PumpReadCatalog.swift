import Foundation
import TandemMessages

/// Single source of truth (debug `pump-pairing-loop-api25` hardening pass) for:
///  1. every CURRENT_STATUS read opcode the app sends, and its human-readable name (transparency 4a);
///  2. the delivery/control-WRITE opcodes that must NEVER enter the read-only `badOpcodes` never-resend set
///     (Guardrail A) — the read-only exclusion set can only ever DROP A READ, never a delivery command;
///  3. which excluded reads degrade a DOSE-PATH safety pre-guard to "relying on the pump's own protection"
///     and so must be disclosed to the user (transparency 4b).
///
/// **Opcode-space collision (the reason Guardrail A is subtle).** Raw request opcodes are REUSED across BLE
/// characteristics, disambiguated only by characteristic. In the pinned kit (1a09dba):
///   - op164 is BOTH `SetTempRateRequest` on `.control` (a delivery WRITE) AND `LastBolusStatusV2Request`
///     on `.currentStatus` (a READ);
///   - op144 is BOTH `EnterChangeCartridgeModeRequest` (`.control` WRITE) AND `CurrentBatteryV2Request`
///     (`.currentStatus` READ).
/// `PumpReadScheduler.badOpcodes` stores raw `UInt8` with NO characteristic, and is consulted ONLY by
/// `sendStatusRead` (the `.currentStatus` read path) — the `.control` delivery/control write path
/// (`deliverBolus`/`deliverExtendedBolus`/`sendControl` → `PumpTransactionCoordinator`) never consults it.
/// So a raw op164 in `badOpcodes` suppresses only the op164 READ and has ZERO effect on the SetTempRate
/// WRITE. Therefore `deliveryControlWriteOpcodes` below is the delivery/control set MINUS every read-
/// colliding opcode: excluding only the PURE delivery opcodes (a) stops an op77 that NAMES a delivery
/// command — or a foreign/legacy persisted entry — from ever poisoning `badOpcodes`, while (b) never
/// breaking a colliding READ's legitimate self-heal (op164/op144 stay learnable as reads).
///
/// Non-isolated, immutable, `Sendable` constants — safe to read from the `@MainActor` scheduler, the
/// (non-isolated) diagnostics builders, and the test suite alike.
enum PumpReadCatalog {

    // MARK: - CURRENT_STATUS reads (the only opcodes that may legitimately enter `badOpcodes`)

    /// Opcode → human-readable name for every CURRENT_STATUS read the app polls (fast/alert/static/
    /// bootstrap) or sends on demand. Names are plain machine tokens (no PHI) suitable for diagnostics.
    static let readNamesByOpcode: [UInt8: String] = [
        LoadStatusRequest.props.opCode: "Cartridge/load status",
        ControlIQIOBRequest.props.opCode: "Control-IQ IOB",
        CurrentEGVGuiDataRequest.props.opCode: "CGM reading",
        InsulinStatusRequest.props.opCode: "Reservoir/insulin status",
        LastBolusStatusV2Request.props.opCode: "Last bolus status",
        CurrentBatteryV2Request.props.opCode: "Battery",
        HomeScreenMirrorRequest.props.opCode: "Home-screen mirror",
        CurrentBasalStatusRequest.props.opCode: "Basal status",
        BolusCalcDataSnapshotRequest.props.opCode: "Bolus-calculator settings",
        PumpFeaturesV1Request.props.opCode: "Pump features",
        ControlIQInfoV2Request.props.opCode: "Control-IQ info",
        BasalLimitSettingsRequest.props.opCode: "Basal-limit settings",
        ApiVersionRequest.props.opCode: "API version",
        PumpVersionRequest.props.opCode: "Pump version",
        TimeSinceResetRequest.props.opCode: "Pump clock",
        AlertStatusRequest.props.opCode: "Alerts",
        AlarmStatusRequest.props.opCode: "Alarms",
        CGMAlertStatusRequest.props.opCode: "CGM alerts",
        ReminderStatusRequest.props.opCode: "Reminders",
        MalfunctionStatusRequest.props.opCode: "Malfunctions",
        CGMStatusRequest.props.opCode: "CGM session status",
    ]

    /// The set of read opcodes the app sends (derived from `readNamesByOpcode`).
    static let currentStatusReadOpcodes: Set<UInt8> = Set(readNamesByOpcode.keys)

    // MARK: - Delivery / control WRITE opcodes (Guardrail A)

    /// EVERY delivery/control-WRITE opcode the app can send: the bolus lifecycle plus every insulin-
    /// affecting control command (suspend/resume/temp-basal/modes/cartridge-fill). Includes the read-
    /// colliding op164 (SetTempRate) and op144 (EnterChangeCartridge) — see the type doc — so the
    /// characteristic-isolation scope-guard can reason about the FULL write surface.
    static let allDeliveryControlWriteOpcodes: Set<UInt8> = [
        BolusPermissionRequest.props.opCode,
        BolusPermissionReleaseRequest.props.opCode,
        InitiateBolusRequest.props.opCode,
        CancelBolusRequest.props.opCode,
        SuspendPumpingRequest.props.opCode,
        ResumePumpingRequest.props.opCode,
        SetTempRateRequest.props.opCode,
        StopTempRateRequest.props.opCode,
        SetModesRequest.props.opCode,
        EnterChangeCartridgeModeRequest.props.opCode,
        EnterFillTubingModeRequest.props.opCode,
        FillCannulaRequest.props.opCode,
    ]

    /// Guardrail A: the delivery/control-WRITE opcodes that must NEVER be recorded in the read-only
    /// `badOpcodes` never-resend set — the full write set MINUS any opcode that also names a legitimate
    /// currentStatus read (op164/op144). Enforced at every entry point to `badOpcodes`
    /// (`PumpReadScheduler.insertBadOpcode`, the `startPolling` hydration union, and
    /// `PumpBadOpcodeStore.record`). By construction this is DISJOINT from `currentStatusReadOpcodes`.
    static let deliveryControlWriteOpcodes: Set<UInt8> =
        allDeliveryControlWriteOpcodes.subtracting(currentStatusReadOpcodes)

    // MARK: - Transparency (tasks 4a / 4b)

    /// Human-readable name for a read opcode; unknown opcodes fall back to "op-N" (transparency 4a).
    static func readName(for opcode: UInt8) -> String {
        readNamesByOpcode[opcode] ?? "op-\(opcode)"
    }

    /// The `[Capability/opcode]` "Rejected opcodes" label for one excluded read (transparency 4a):
    /// "Cartridge/load status (op-20)" for a known read, "op-47" for an unknown opcode.
    static func rejectedOpcodeLabel(for opcode: UInt8) -> String {
        if let name = readNamesByOpcode[opcode] { return "\(name) (op-\(opcode))" }
        return "op-\(opcode)"
    }

    /// Reads whose auto-exclusion degrades a DOSE-PATH safety pre-guard to "relying on the pump's own
    /// protection" (transparency 4b). Currently op-20 `LoadStatusRequest`: it feeds
    /// `PumpSnapshot.cartridgeLoadState` → the 09.9 `cartridgeReadyForBolus` cartridge pre-check, which —
    /// once op-20 is excluded — can no longer be confirmed (Guardrail B keeps it fail-closed/unknown, and
    /// this note discloses the degraded state instead of silently presenting confirmed-ready).
    ///
    /// CX-F-04: also op-74 `CGMAlertStatusRequest` — a currently-skipped read means the phone-side CGM-alert
    /// mirror is degraded (relying on the pump's own on-device alerting) and that must be disclosed rather
    /// than silently going quiet (CONTEXT.md "Q. CX-F-04").
    static let safetyRelevantReadOpcodes: Set<UInt8> = [
        LoadStatusRequest.props.opCode,
        CGMAlertStatusRequest.props.opCode,
    ]

    /// R2-10: the dose-input READ opcodes that feed the bolus calculator — op108 `ControlIQIOBRequest`
    /// (active insulin / IOB, delivered via its sole op109 response) and op115 `BolusCalcDataSnapshotRequest`
    /// (CR/ISF/target/max). Unlike op20, these must NEVER be durably blacklisted: op109 is the ONLY IOB
    /// source, so a persisted skip fail-closes `recommendBolus` forever with no re-probe (bricks the
    /// calculator on that pump). Held out of the durable store (`insertBadOpcode` / `PumpBadOpcodeStore.record`),
    /// re-probed each connect (`startPolling`), and disclosed when currently unavailable (below).
    static let doseInputReadOpcodes: Set<UInt8> = [
        ControlIQIOBRequest.props.opCode,
        BolusCalcDataSnapshotRequest.props.opCode,
    ]

    /// CX-F-04: the CGM/pump-alert READ opcodes `PumpReadScheduler.alertRead()` sends as ONE unthrottled
    /// 5-message burst — `AlertStatusRequest`, `AlarmStatusRequest`, `CGMAlertStatusRequest` (op74),
    /// `ReminderStatusRequest`, `MalfunctionStatusRequest`. All five share the SAME transient-error exposure:
    /// sent back-to-back with no per-message throttling, so a single transient `ErrorResponse` (e.g.
    /// MESSAGE_BUFFER_FULL / CRC_MISMATCH / TRANSACTION_ID_MISMATCH — never `BAD_OPCODE`, which would break
    /// the documented API-2.5 `UNDEFINED_ERROR(0)` pairing-loop fix) can be mis-correlated by
    /// `resolveErrorResponse`'s txId-echo/FIFO backstop to ANY opcode still outstanding in this burst. Unlike
    /// op20 (a pre-guard confirmation read), a durably-persisted skip here PERMANENTLY silences the
    /// phone-side CGM-alert mirror with no re-probe (CONTEXT.md "Q. CX-F-04"; op74 is the confirmed
    /// mechanism finding, widened to its burst-mates since they share the identical exposure). Held out of
    /// the durable store (`insertBadOpcode` / `PumpBadOpcodeStore.record`), re-probed each connect
    /// (`startPolling`), mirroring the `doseInputReadOpcodes` precedent exactly. op74 alone is additionally
    /// in `safetyRelevantReadOpcodes` above (Task 2) so a current-session skip is disclosed.
    static let alertReadOpcodes: Set<UInt8> = [
        AlertStatusRequest.props.opCode,
        AlarmStatusRequest.props.opCode,
        CGMAlertStatusRequest.props.opCode,
        ReminderStatusRequest.props.opCode,
        MalfunctionStatusRequest.props.opCode,
    ]

    /// One user-facing safety-degraded note per excluded safety-relevant read (transparency 4b). Empty when
    /// no safety-relevant read is excluded.
    static func safetyDegradedNotes(excludedOpcodes: Set<UInt8>) -> [String] {
        var notes: [String] = excludedOpcodes.intersection(safetyRelevantReadOpcodes).sorted().map { op in
            "\(readName(for: op)) (op-\(op)) is unavailable on this pump — "
                + "relying on the pump's own protection for that check."
        }
        // R2-10: a dose-input read being unavailable is NOT "the pump handles it" — there is no pump-side
        // substitute for the IOB/therapy inputs, so the "relying on the pump's own protection" wording is
        // wrong here. The bolus calculator simply fail-closes and will not recommend a dose. Disclose that
        // explicitly, distinct from the op20 pre-guard note.
        for op in excludedOpcodes.intersection(doseInputReadOpcodes).sorted() {
            notes.append("\(readName(for: op)) (op-\(op)) is unavailable on this pump — "
                + "the bolus calculator can't confirm active insulin/therapy settings and will not recommend a dose.")
        }
        return notes
    }
}
