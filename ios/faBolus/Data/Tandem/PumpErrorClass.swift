import Foundation
import TandemMessages

/// What an inbound op-77 `ErrorResponse` actually TELLS US about the read that provoked it.
///
/// Added for debug session `tslim-reservoir-battery-zero`. `PumpReadScheduler.resolveErrorResponse`
/// used to take only `requestCodeId` and `txId` — `errorCodeId` was never passed in, so every error
/// class reached the durable never-resend store identically. A brand-new t:slim X2 (Software 4.0)
/// arrived with five ordinary `.currentStatus` reads (op-20, op-36, op-56, op-144, op-164) durably
/// blacklisted, learned from an UNSTABLE link. The reservoir and battery rows never got a value again.
///
/// NO RATE IS CLAIMED HERE ON PURPOSE. The diagnostics export's `connectCount` and its
/// `disconnects`/`totalUptimeSeconds` rows are NON-DIVISIBLE BY CONSTRUCTION and no ratio between any
/// two rows of that export is meaningful: `connectCount` increments on `SafetyEdge.connection == .clear`
/// (including by-design-silent background reconnects, `.bolusing -> .connected` returns, and relaunches),
/// whereas `disconnects` and `totalUptimeSeconds` are written only on `.raise`, which requires a TERMINAL
/// down state. So a reported total uptime is the sum of a handful of truncated spans, not time-connected,
/// and dividing it by the connect count yields a meaningless "mean session". An earlier draft of this
/// comment did exactly that; see debug session `pump-link-thrash-190-connects`. The classification below
/// does not depend on any rate — only on the fact that transient protocol errors occur at all.
///
/// The protocol's own enum (vendored reference
/// `pumpx2-oracle/messages/.../response/ErrorResponse.java`, `ErrorCode`) draws the line for us:
/// exactly ONE code is a statement about opcode SUPPORT. Everything else is a statement about THIS
/// EXCHANGE — back-pressure, a corrupted frame, a transaction-id slip, an auth hiccup — and says
/// nothing whatsoever about whether the pump implements the opcode.
enum PumpErrorClass: Equatable {
    /// `BAD_OPCODE(6)` — the pump is telling us it does not recognise/support the opcode. The only
    /// authoritative capability statement in the enum, and the one the original never-resend backstop
    /// was designed around (op-192 `CurrentEgvGuiDataV2Request` on an older t:slim X2).
    case unsupportedOpcode
    /// `UNDEFINED_ERROR(0)` — genuinely ambiguous. It is the opcode-less `[0,0]` currentStatus reply the
    /// API-2.5 non-Control-IQ t:slim X2 sends for op-20 right before tearing the link down (the
    /// documented `pump-pairing-loop-api25` mechanism, which MUST stay learnable), and it is also what a
    /// stressed link produces. Also the value a TRUNCATED op-77 leaves `errorCodeId` defaulted to. So it
    /// is trusted only as far as the opcode correlation is unambiguous — see
    /// `PumpOpcodeCorrelation`.
    case ambiguous
    /// Every other code: `CRC_MISMATCH(1)`, `TRANSACTION_ID_MISMATCH(3)`, `BAD_CARGO_LENGTH(4)`,
    /// `INVALID_REQUIRED_PARAMETER(7)`, `MESSAGE_BUFFER_FULL(8)`, `INVALID_AUTHENTICATION_ERROR(9)` —
    /// plus any code not in the enum at all. Retryable and exchange-scoped. `BAD_CARGO_LENGTH(4)` and
    /// `INVALID_REQUIRED_PARAMETER(7)` land here deliberately: every read in the fast/alert/static tiers
    /// is an EMPTY-cargo request, so a cargo/parameter complaint about one is a framing artifact, never a
    /// capability statement.
    case transient

    /// Classify a raw `ErrorResponse.errorCodeId`. An UNRECOGNISED code fails SAFE as `.transient` —
    /// the cost of re-probing a read the pump really does not support is one bounded op-77 per
    /// connection (already absorbed by the in-memory session skip), whereas the cost of a wrong durable
    /// exclusion is a permanently blind pre-guard and a permanently blank row.
    static func of(errorCodeId: Int) -> PumpErrorClass {
        switch errorCodeId {
        case 6: return .unsupportedOpcode
        case 0: return .ambiguous
        default: return .transient
        }
    }
}

/// HOW `resolveErrorResponse` established WHICH opcode an op-77 refers to. Independent of
/// `PumpErrorClass` (which is about what the error MEANS) — this is about how much we can trust the
/// attribution, and the two combine into `PumpBadOpcodeDurability`.
enum PumpOpcodeCorrelation: Equatable {
    /// The cargo's `requestCodeId` named the opcode outright. Authoritative attribution.
    case namedByPump
    /// The cargo was opcode-less, but exactly ONE read was outstanding — so no guess was involved.
    /// This is the on-demand `refreshLoadStatus()` shape the API-2.5 op-20 self-heal relies on.
    case soleOutstandingRead
    /// The cargo was opcode-less and the attribution came from the echoed request txId while MULTIPLE
    /// reads were in flight. The attribution is probably right, but this is precisely the situation
    /// `PumpReadCatalog`'s alert-burst note already flags as the mis-correlation / back-pressure zone:
    /// `startPolling()` emits ~16 reads back-to-back with no pacing, so an error produced by the BURST
    /// (rather than by any one opcode) gets pinned onto whichever read the echo points at.
    case txIdEchoUnderBurst
}

/// Whether a resolved rejection may be written to the DURABLE per-pump store, and on what terms.
/// The in-memory, connection-scoped skip is applied in every case — it is what prevents re-thrashing a
/// bad exchange every 15 s poll and re-running the ~70-90 ms teardown risk. Only the DURABLE write,
/// which is what makes a mistake permanent, is rationed here.
enum PumpBadOpcodeDurability: Equatable {
    /// Persist on this single observation (today's behaviour, preserved for the authoritative cases).
    case immediate
    /// Suppress in memory now, but require `PumpBadOpcodeStore.durableStrikeThreshold` observations on
    /// DISTINCT connection cycles before the exclusion becomes durable. A genuinely unsupported read
    /// still converges (it fails on every cycle); a one-off burst artefact never does.
    case afterCorroboratingStrikes
    /// Never persist. The skip lives only for this connection cycle and is dropped at the next
    /// `startPolling()` — the same treatment `PumpReadCatalog.alertReadOpcodes` and
    /// `doseInputReadOpcodes` already get, generalised from a per-family allowlist to a per-error-class
    /// rule.
    case neverPersist

    /// The decision matrix. `PumpErrorClass` supplies "does this mean unsupported?" and
    /// `PumpOpcodeCorrelation` supplies "are we sure which opcode?" — a durable, permanent exclusion
    /// requires a satisfactory answer to both.
    static func of(errorClass: PumpErrorClass, correlation: PumpOpcodeCorrelation) -> PumpBadOpcodeDurability {
        switch errorClass {
        case .transient:
            // No amount of attribution confidence turns a buffer-full into a capability statement.
            return .neverPersist
        case .unsupportedOpcode:
            // BAD_OPCODE is deliberate and specific; the pump identified the opcode it rejected.
            return .immediate
        case .ambiguous:
            switch correlation {
            case .namedByPump, .soleOutstandingRead:
                // No guess was involved, and this is the documented API-2.5 op-20 path — unchanged.
                return .immediate
            case .txIdEchoUnderBurst:
                // The zone where a burst-produced error gets pinned onto an innocent read. Corroborate.
                return .afterCorroboratingStrikes
            }
        }
    }
}
