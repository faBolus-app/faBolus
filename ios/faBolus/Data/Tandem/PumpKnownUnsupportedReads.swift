import Foundation
import TandemMessages

/// Static registry of CURRENT_STATUS read opcodes a specific pump model + firmware is known to reject.
/// Additive on top of the on-device dynamic op77 self-heal, which stays.
///
/// **Why a static table on top of the dynamic self-heal.** On a fresh install / never-before-seen pump the
/// app cannot know it is a bad combo at `startPolling()` time — `softwareVersion` is unknown until the async
/// op33 `ApiVersionResponse` returns; only `isMobi` (from the BLE name) is known before then. So op20
/// `LoadStatusRequest` (the last read of `PumpReadScheduler.fastRead()`) was sent blindly in the pre-version
/// burst and the evidenced pump dropped the BLE link ~2-3× (~25 s) before the dynamic self-heal learned and
/// persisted the skip. This registry lets the scheduler seed the exclusion into the never-resend `badOpcodes`
/// set BEFORE op20 is ever sent — provided op20 is deferred out of the pre-version burst and dispatched only
/// once the bootstrap version responses identify the pump (`PumpReadScheduler.noteBootstrapVersionIdentified`).
///
/// **On-wire evidence for the seeded entry.** On the API-2.5, non-Control-IQ t:slim X2 (software/API
/// version "2.5"), op20 → an op77 `ErrorResponse` whose real 2-byte currentStatus cargo is `[0,0]` (no
/// opcode) → the pump tears the link down ~90 ms later (CBErrorDomain#7). op164/op144 (both minApi=API_V2_5)
/// succeed on this pump, proving it is ≥ API_V2_5, so there is no minApi/version gate the client could use —
/// the rejection is specific to this (model, firmware) combo.
///
/// **Identity fields.** `ApiVersionResponse` (op33) carries `majorVersion`/`minorVersion` (→
/// `PumpSnapshot.softwareVersion` "major.minor") and a computed `isMobi` (`major>3 || (major==3 &&
/// minor>=5)`) — the full evidenced key. `PumpVersionResponse` (op85) additionally carries `modelNum`
/// (offset 44); it rides the same bootstrap trio and is available for a finer key, but the current
/// evidenced entry needs only op33's fields.
///
/// **Keyed precisely — never broadened.** The entry matches ONLY `isMobi == false` (a t:slim X2, not a Mobi)
/// AND `softwareVersion == "2.5"`. It deliberately does NOT exclude op20 for all t:slim X2: a newer firmware
/// may support op20, and the dynamic op77 self-heal + per-pump persistence already cover any unknown-bad
/// combo (one-drop-then-learn). The static table is re-derived from identity on EVERY connect and is NEVER
/// persisted — it stays additive to, and distinct from, the per-pump learned `PumpBadOpcodeStore`.
///
/// Non-isolated, pure, `Sendable` — safe to read from the `@MainActor` scheduler and the test suite alike.
enum PumpKnownUnsupportedReads {

    /// The CURRENT_STATUS read opcodes this (model, firmware) is KNOWN to reject. Empty for any combo not in
    /// the table (the dynamic self-heal remains the net there).
    ///
    /// - Parameters:
    ///   - isMobi: the pump model class from the bootstrap version identity (`false` = t:slim X2, `true` =
    ///     Mobi, `nil` = not yet known — returns empty, so a read is never suppressed on an unknown identity).
    ///   - softwareVersion: `PumpSnapshot.softwareVersion` ("major.minor" from op33), or "" when not yet read.
    static func unsupportedReadOpcodes(isMobi: Bool?, softwareVersion: String) -> Set<UInt8> {
        // Evidenced entries — t:slim X2 (non-Mobi), software/API 2.5:
        //   • op20  LoadStatusRequest  → op77 ErrorResponse cargo [0,0] → BLE teardown (~90 ms). See type doc.
        //   • op120 HighestAamRequest / op146 ActiveAamBitsRequest — Control-IQ-era auto-adjustment-mode
        //     (AAM) reads. On this Control-IQ-off / no-CGM API-2.5 t:slim X2 the pump rejects them (op-77)
        //     and tears the BLE link down ~90 ms later (HCI 0x13 remote-user-terminated) → a connect/
        //     disconnect flap that only looked like a fixed ~2 s watchdog because the deterministic read
        //     schedule reached the offending tail at a fixed offset. Seeded into `badOpcodes` the instant
        //     op33 identifies the pump, before the deferred `alertRead()` burst sends them (see
        //     `PumpReadScheduler.runIdentityGatedReadsOnce`). READ-only, precisely-keyed static seed —
        //     the dynamic op77 self-heal + per-pump persistence remain the net for any other combo.
        //     op118 MalfunctionStatus was also 0/18-answered in the capture but is a safety/malfunction
        //     read with only medium-confidence evidence, so it is deliberately NOT suppressed here;
        //     on-device bisection decides it.
        if isMobi == false, softwareVersion == "2.5" {
            return [LoadStatusRequest.props.opCode,
                    HighestAamRequest.props.opCode,
                    ActiveAamBitsRequest.props.opCode]
        }
        return []
    }

    /// The union of every read opcode that appears in ANY registry entry — the reads whose support depends on
    /// the pump identity and which must therefore be HELD OUT of the pre-version burst (sent only after the
    /// bootstrap version responses identify the pump, so a known-bad combo can suppress them before the first
    /// send). Single source of truth for `PumpReadScheduler`'s deferral: adding a future entry that names a
    /// new read opcode must add it here too. Currently just op20 `LoadStatusRequest`.
    static let identityGatedReadOpcodes: Set<UInt8> = [LoadStatusRequest.props.opCode]
}
