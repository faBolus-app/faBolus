import Foundation
import TandemMessages
import os

/// Phase 09 Wave 3, Target B part 1 (D-06): the BLE read cascade's **send side**, extracted verbatim out
/// of `TandemBackend` behind the unchanged `PumpBackend` seam. Owns the reference-required post-pair
/// bootstrap trio, the three tiered read message lists (fast/alert/static), the recurring `pollTimer`
/// cadence gating, the `pollCycleGeneration`/`scheduleAlertRead` generation guard, the predictive-burst
/// lifecycle, the single-flight glucose/calc-input coalescers, and the `badOpcodes` never-resend backstop.
///
/// Depends ONLY on injected closures/providers (`send`, `isConnected`, `pumpTimeAnchor`,
/// `onStartPollingCycleBegin`) — never a whole-`TandemBackend` back-pointer — mirroring
/// `DeliveryLedgerCoordinator`'s D-04 hook pattern: `var`s with safe no-op defaults, assigned by
/// `TandemBackend` as separate statements right after construction (Swift's two-phase init forbids a
/// `[weak self]`-capturing closure inside the very expression that initializes the property holding it).
///
/// D-07 (landed in Wave 4): the response-applier — the `didReceiveFrame` status cases, including
/// `applyEgvReading` — moved into `PumpResponseApplier`, which calls into this scheduler's exposed
/// completion/scheduling methods (`completeGlucoseRead()`, `noteCalcInputArrived(iob:)`,
/// `schedulePredictiveBurst(afterReadingAt:)`, `cgmReadingDate(pumpSec:now:)`, `insertBadOpcode(_:)`) via
/// its own injected closures — the same calls TandemBackend made directly before this extraction,
/// still routed through this scheduler.
///
/// NO wire bytes, send order, or cadence change (D-06) — every member below is a verbatim move (including
/// its fix-cycle doc-comment history) from `TandemBackend.swift`.
@MainActor
final class PumpReadScheduler {
    /// Same subsystem/category as `TandemBackend.pairingLog` — declared separately (that constant is
    /// `private` to `TandemBackend`) so the merged `log show` timeline still shows every "read send →"
    /// line from this scheduler alongside the pairing/response lines TandemBackend itself still logs.
    private static let pairingLog = Logger(subsystem: "com.fabolus.app", category: "ble")

    // MARK: - Injected seams (settable post-construction, D-04 hook pattern)

    /// Bound to `client.send` via `tx` (byte-identical wire path — this scheduler never touches BLE
    /// directly). Returns the wire txId so `sendStatusRead` can correlate an opcode-less op77
    /// `ErrorResponse` back to the read that provoked it (debug pump-pairing-loop-api25, mechanism B).
    var send: (Message) throws -> UInt8 = { _ in 0 }
    /// Bound to `snapshot.connection == .connected`.
    var isConnected: () -> Bool = { false }
    /// Bound to `pumpTimeAnchor` (the phone↔pump clock anchor TandemBackend owns).
    var pumpTimeAnchor: () -> (pump: UInt32, phone: Date)? = { nil }
    /// Bound to `{ responseApplier.resetCycleState() }` (Phase 09 Wave 4) — `lastCgmPumpSec` moved to
    /// `PumpResponseApplier` with `applyEgvReading` (its only reader/writer, D-07), but its reset is part
    /// of `startPolling()`'s fresh-connection-cycle setup, which lives here — so this hook keeps that
    /// reset atomic with the rest of `startPolling()`'s cycle-begin work, exactly as it ran inline before
    /// either move.
    var onStartPollingCycleBegin: () -> Void = {}
    /// debug pump-pairing-loop-api25 (refinement): return this pump's DURABLE learned-bad-opcode set —
    /// opcodes this specific pump rejected on a PRIOR connection (persisted across reconnects AND app
    /// relaunches, keyed to pump identity). `startPolling()` folds it into `badOpcodes` BEFORE any read
    /// goes out, so an opcode already proven unsupported by THIS pump is skipped from the very first
    /// `fastRead()` of this cycle — the API-2.5 t:slim X2 drops op20 exactly once (first-ever connect),
    /// never again, and never after a relaunch. Bound by `TandemBackend` to a peripheral-UUID-keyed
    /// `PumpBadOpcodeStore`; the default (persistence off) returns nothing so a bare scheduler is unchanged.
    var loadPersistedBadOpcodes: () -> Set<UInt8> = { [] }
    /// debug pump-pairing-loop-api25 (refinement): persist one newly-learned rejected opcode durably,
    /// keyed to the current pump, so it survives a reconnect and an app relaunch. Bound by `TandemBackend`;
    /// the default is a no-op (persistence off). Never called with op0 (`insertBadOpcode` guards it).
    var persistBadOpcode: (UInt8) -> Void = { _ in }

    // MARK: - Status read dispatch
    //
    // An EARLIER fix cycle in `.planning/debug/pump-pairing-loop.md` added an app-level `readQueue`
    // that spaced every CURRENT_STATUS read `readSpacingSec` (200ms) apart, one at a time, built on an
    // on-device capture showing `startPolling()`'s old unthrottled 13-message burst answered 0/13 before
    // the pump tore the link down ~170ms later. A LATER capture (on-device capture #6) isolated that
    // same drop to exactly ONE opcode: `CurrentEgvGuiDataV2Request` (op192), answered with
    // `ErrorResponse`/BAD_OPCODE ~70ms after being sent, right before the teardown. Once the pump drops
    // the link after that one rejection, every OTHER already-in-flight read in the same burst also goes
    // unanswered — fully explaining "0 of 13 answered" without burst VOLUME being a factor at all. Nor
    // does the vendored jwoglom/pumpx2-oracle reference pace its own reads: `TandemPump.java
    // #onPumpConnected` fires its `ApiVersionRequest`/`PumpVersionRequest`/`TimeSinceResetRequest`
    // bootstrap trio via `sendCommand()` back-to-back, with no delay between calls, relying on the same
    // OS-level write serialization `PumpBLEClient.send()`/CoreBluetooth already provide for
    // `.withResponse` writes (the OS itself won't dispatch a second GATT write before the first
    // completes) — matching `WriteType.WITH_RESPONSE` in the reference's own `sendCommand()`. With op192
    // no longer sent at all (see the EGV request sites below) and the opcode-agnostic `badOpcodes`
    // backstop in place regardless, the app-level pacing/queue had no independent justification and was
    // REMOVED — reads are sent directly, matching the reference's own unpaced approach.
    /// SEVENTH fix cycle (`.planning/debug/pump-pairing-loop.md`, on-device capture #6): opcodes the
    /// pump has explicitly rejected with `ErrorResponse` this connection-lifetime — `sendStatusRead()`
    /// silently skips (never re-sends) any message whose opcode is in this set, so a single BAD_OPCODE
    /// (or any other pump-side rejection) can never re-trigger the observed teardown loop again.
    /// Generic/opcode-agnostic — a backstop independent of any per-message version handling, for
    /// whatever the app doesn't otherwise anticipate. Deliberately NOT reset on disconnect (unlike
    /// `pumpFeatureBits`/`detectedIsMobi`, which stay on `TandemBackend`): an opcode already proven
    /// unsupported by THIS pump stays proven unsupported across a BLE reconnect to the same physical
    /// device — re-learning it every cycle would just reproduce one bad exchange (and its ~70ms drop
    /// risk) on every single reconnect.
    ///
    /// EIGHTH fix cycle (`.planning/debug/pump-pairing-loop-api25.md`, refinement): this in-memory set is
    /// now also HYDRATED at each `startPolling()` from a DURABLE, per-pump store (`loadPersistedBadOpcodes`)
    /// and every insertion is PERSISTED (`persistBadOpcode`), keyed to pump identity. So an opcode this pump
    /// proved unsupported survives not just a reconnect but an app relaunch — the API-2.5 t:slim X2 drops
    /// op20 exactly once, ever. The persistence is keyed to the pump (peripheral UUID + firmware stamp), so
    /// a DIFFERENT pump/firmware never inherits this skip and keeps polling op20 (keeping the 09.9
    /// `cartridgeReadyForBolus` pre-guard live on pumps that support it).
    private var badOpcodes: Set<UInt8> = []
    /// Sends one CURRENT_STATUS/pairing-adjacent read directly. Applies the `badOpcodes` never-resend
    /// guard every status read needs (see its own doc comment) and logs the type/opcode/send outcome as
    /// `"read send →"` — distinct from TandemBackend's `"pairing send →"`/`"pairing recv ←"` lines, so a
    /// future on-device capture can name exactly which read request the pump was answering (or not)
    /// around a drop. Never logs cargo/payload bytes (per D-08).
    @discardableResult
    private func sendStatusRead(_ message: Message) -> Bool {
        let typeName = String(describing: type(of: message))
        let opcode = message.opCode
        // SEVENTH fix cycle: never (re-)send an opcode the pump has already rejected with
        // ErrorResponse this connection-lifetime — see `badOpcodes`'s doc comment.
        guard !badOpcodes.contains(opcode) else {
            Self.pairingLog.log("read send → \(typeName, privacy: .public) opcode=\(opcode, privacy: .public) result=skipped (previously rejected by pump)")
            #if DEBUG
            onReadSkippedForTesting?(typeName, opcode)
            #endif
            return false
        }
        var sent = false
        do {
            let txId = try send(message)
            Self.pairingLog.log("read send → \(typeName, privacy: .public) opcode=\(opcode, privacy: .public) result=sent")
            // Mechanism B (debug pump-pairing-loop-api25): remember this read's wire txId so an
            // opcode-less op77 `ErrorResponse` (real 2-byte currentStatus cargo `[0,0]` on this
            // API-2.5 t:slim X2) can be correlated back to the read that provoked it — see
            // `resolveErrorResponse`. Only recorded on a genuine send (never on a throw), so a
            // never-sent read can't poison the correlation.
            recordOutstandingRead(txId: txId, opcode: opcode)
            sent = true
        } catch {
            Self.pairingLog.log("read send → \(typeName, privacy: .public) opcode=\(opcode, privacy: .public) result=threw")
        }
        #if DEBUG
        onReadDispatchedForTesting?(typeName, opcode)
        #endif
        return sent
    }
    #if DEBUG
    /// Test seam: fires each time `sendStatusRead` actually attempts a real send (regardless of
    /// `send`'s own throw/success) — reports the type name/opcode, so a test can assert send ORDER
    /// (e.g. the reference-required bootstrap trio first, per the "MARK: - Post-pair bootstrap order"
    /// fix below) without a live `CBCentralManager`.
    var onReadDispatchedForTesting: ((_ typeName: String, _ opcode: UInt8) -> Void)?
    /// SEVENTH fix cycle test seam: fires instead of `onReadDispatchedForTesting` when `sendStatusRead`
    /// SKIPS a read because its opcode is in `badOpcodes` — lets a test assert a previously-error'd
    /// opcode is dropped, not sent, on a later poll.
    var onReadSkippedForTesting: ((_ typeName: String, _ opcode: UInt8) -> Void)?
    #endif

    /// Feed for the `ErrorResponse` delegate case (which stays in `TandemBackend` this wave) — records an
    /// opcode the pump has just rejected so `sendStatusRead()` never re-sends it this connection-lifetime,
    /// AND persists it durably for this pump (debug pump-pairing-loop-api25 refinement) so the skip survives
    /// a reconnect and an app relaunch. op0 is never suppressed — it is the empty-cargo artifact / bootstrap
    /// opcode; `resolveErrorResponse` never resolves to it, and this guard is the belt-and-suspenders.
    func insertBadOpcode(_ opcode: UInt8) {
        guard opcode != 0 else { return }
        // Guardrail A (debug pump-pairing-loop-api25 hardening): the never-resend set governs ONLY
        // CURRENT_STATUS reads (`sendStatusRead`). It must NEVER hold a pure delivery/control-WRITE opcode —
        // otherwise an op77 whose cargo NAMES a delivery command (`resolveErrorResponse`'s `named` path)
        // could record e.g. InitiateBolus here. `PumpReadCatalog.deliveryControlWriteOpcodes` deliberately
        // EXCLUDES read-colliding opcodes (op164/op144), so a colliding READ still self-heals; the
        // `.control` delivery path never consults this set, so this guard removes the only way a delivery
        // opcode could ever enter it. Belt-and-suspenders with the same guard in `startPolling`'s hydration
        // union and `PumpBadOpcodeStore.record`.
        guard !PumpReadCatalog.deliveryControlWriteOpcodes.contains(opcode) else { return }
        badOpcodes.insert(opcode)
        persistBadOpcode(opcode)
    }

    /// WR-05 (debug pump-pairing-loop-api25, deep review): drop opcodes from the IN-MEMORY never-resend set.
    /// `badOpcodes` deliberately survives a reconnect for the scheduler's lifetime, so when the durable
    /// per-pump store is reset on a firmware change (same UUID, new `softwareVersion`) the in-memory copy
    /// learned under the OLD firmware must be purged too — otherwise a firmware update that newly supports
    /// op20 keeps it skipped until the app is relaunched, longer than the "a firmware update must never keep
    /// the pre-guard starved" invariant intends. Called by `TandemBackend`'s firmware-change detection (via
    /// the `loadPersistedBadOpcodes` hydration path) BEFORE the fresh union in `startPolling`.
    func clearLearned(_ opcodes: Set<UInt8>) {
        badOpcodes.subtract(opcodes)
    }

    // MARK: - op77 correlation backstop (debug pump-pairing-loop-api25, mechanism B)
    //
    // The op192-era `badOpcodes` backstop assumed an inbound op77 `ErrorResponse` names the failing
    // opcode in its cargo. It does for BAD_OPCODE (errorCodeId 6, requestCodeId = the opcode), but the
    // API-2.5 non-Control-IQ t:slim X2 answers an unsupported currentStatus read (op20 LoadStatus, and
    // possibly op40/op114/op178/op138) with a size-2 cargo of `[0,0]` — errorCode UNDEFINED_ERROR, NO
    // opcode — then tears the BLE link down. Trusting that empty cargo records opcode 0 (useless), so the
    // read is re-sent every reconnect → the loop. The true opcode is recoverable only by CORRELATION: the
    // pump echoes the request txId in the inbound frame's frame[1] (kit's hardware-confirmed t:slim
    // behavior), or, failing that, by in-order FIFO of the reads still outstanding this connection.

    /// Reads sent this connection whose (non-error) reply may still be outstanding, most-recent last.
    /// Deduped by opcode (an opcode re-sent refreshes its txId), so it stays bounded to the ~20 distinct
    /// reads. Cleared at each fresh `startPolling()` cycle. NOT the `badOpcodes` set — this is the
    /// transient in-flight map the op77 correlation consults, not the durable never-resend proof.
    private var outstandingReads: [(txId: UInt8, opcode: UInt8)] = []
    private func recordOutstandingRead(txId: UInt8, opcode: UInt8) {
        outstandingReads.removeAll { $0.opcode == opcode }
        outstandingReads.append((txId: txId, opcode: opcode))
    }

    /// Resolve an inbound op77 `ErrorResponse` to the TRUE failing opcode, record it in the never-resend
    /// `badOpcodes` set, and RETURN it for the caller's standing diagnostic log line.
    /// - When the cargo names the opcode (`requestCodeId != 0`, e.g. the op192 BAD_OPCODE case) that
    ///   value is authoritative and used directly.
    /// - When the cargo is opcode-less (`requestCodeId == 0`, the `[0,0]` currentStatus variant this
    ///   firmware sends), correlate to the outstanding read: PRIMARY via the echoed request txId
    ///   (frame[1]); if that matches nothing, use the exactly-one-outstanding shortcut (unambiguous even
    ///   without an echo — the single-read on-demand `refreshLoadStatus()` case); otherwise FAIL CLOSED.
    /// Returns 0 when nothing can be safely correlated — so opcode 0 (the empty-cargo artifact) is never
    /// what gets suppressed, and no INNOCENT read is guessed at.
    ///
    /// WR-02 (debug pump-pairing-loop-api25, deep review): the old blind FIFO-oldest fallback
    /// (`outstandingReads.first`) was DOUBLY wrong for the very read this fix targets — op20 is
    /// `fastRead()`'s LAST send, so "oldest outstanding" is always a bootstrap/early read (ApiVersion,
    /// ControlIQIOB), never op20. An echo-less op77 under a full burst would therefore durably blacklist an
    /// innocent supported read (e.g. op109 ControlIQIOB, a dose input) AND leave op20 un-suppressed so the
    /// loop persisted. Guessing the oldest is never safe: prefer the txId echo, accept only the
    /// unambiguous single-outstanding case, else resolve to 0 (logged, nothing suppressed). The txId echo
    /// is the mechanism the on-device `[0,0]` teardown relies on (kit's hardware-confirmed frame[1] echo).
    @discardableResult
    func resolveErrorResponse(requestCodeId: Int, txId: UInt8) -> UInt8 {
        let named = UInt8(truncatingIfNeeded: requestCodeId)
        let resolved: UInt8
        if named != 0 {
            resolved = named
        } else if let byTxId = outstandingReads.last(where: { $0.txId == txId })?.opcode {
            resolved = byTxId                                   // PRIMARY: the pump echoes the request txId in frame[1]
        } else if outstandingReads.count == 1, let only = outstandingReads.first?.opcode {
            resolved = only                                    // unambiguous: exactly one read outstanding (no guess)
        } else {
            resolved = 0                                       // WR-02: FAIL CLOSED — never guess the oldest
        }
        if resolved != 0 {
            insertBadOpcode(resolved)   // in-memory never-resend skip + durable per-pump persist (refinement)
            outstandingReads.removeAll { $0.opcode == resolved }
        }
        return resolved
    }

    /// On-demand single status read (e.g. the pump wizard's `refreshLoadStatus()`), routed through the
    /// same guarded `sendStatusRead()` as the tiered polls so it (a) honours the `badOpcodes` never-resend
    /// guard, (b) is observable via `onReadDispatchedForTesting`/`onReadSkippedForTesting`, and (c) records
    /// the outstanding read for the op77 correlation above. op20 LoadStatus rides BOTH the recurring
    /// `fastRead()` poll AND this on-demand path (debug pump-pairing-loop-api25 refinement restored it to
    /// the poll); both consult the same per-pump persisted `badOpcodes` skip, so on the API-2.5 pump that
    /// learned op20 is unsupported, neither re-sends it, while a supported pump keeps its load-state fresh.
    @discardableResult
    func sendOnDemandRead(_ message: Message) -> Bool { sendStatusRead(message) }
    /// Test accessor: opcodes currently marked as pump-rejected (never re-sent this session).
    var badOpcodesForTesting: Set<UInt8> { badOpcodes }
    #if DEBUG
    /// Test accessor (WR-03, debug pump-pairing-loop-api25 deep review): the in-flight op77-correlation map
    /// (txId → opcode) as recorded by `sendStatusRead` this cycle. Lets a burst test look up a SPECIFIC
    /// read's real wire txId (e.g. op20's) so it can inject an op77 echoing exactly that txId and prove the
    /// correlation resolves to THAT read, not the FIFO-oldest.
    var outstandingReadsForTesting: [(txId: UInt8, opcode: UInt8)] { outstandingReads }
    #endif
    /// Production read accessor for the `[Capability/opcode]` diagnostics section — mirrors
    /// `badOpcodesForTesting` exactly (additive, internal, no new send/re-derivation). Consumed via
    /// `TandemBackend.badOpcodesForDiagnostics` → `AppModel.badOpcodesForDiagnostics`.
    var badOpcodesForDiagnostics: Set<UInt8> { badOpcodes }

    // MARK: - Post-pair bootstrap order
    //
    // THIRD fix cycle (`.planning/debug/pump-pairing-loop.md`, on-device capture #3): the settle
    // delay above worked exactly as designed — the pump held an idle freshly-paired V1 link fine
    // for the full 1.5s (no drop) — but the loop PERSISTED: the pump dropped the link ~315ms after
    // the very FIRST post-settle READ (`ControlIQIOBRequest`, op108 — `fastRead()`'s first message),
    // refuting settle-TIMING as the (sole) fix. Grounded directly in the vendored jwoglom/pumpX2
    // reference (`TandemKit/vendor/pumpx2-oracle/androidLib/src/main/java/com/jwoglom/pumpx2/pump/
    // bluetooth/TandemPump.java`, method `onPumpConnected`, and `TandemBluetoothHandler.java`'s
    // `PumpChallengeResponse`/JPAKE-success branches, which both call `internalOnPumpConnected` →
    // `tandemPump.onPumpConnected` the INSTANT auth succeeds — the exact same trigger point as this
    // port's `onPaired`): the reference's own base class, UNMODIFIED by the sample app (the only
    // consumer in this vendor tree), ALWAYS sends exactly `ApiVersionRequest`, then
    // `PumpVersionRequest`, then `TimeSinceResetRequest` — in that order — as the FIRST GATT traffic
    // issued post-auth, before any other current-status polling. `ApiVersionRequest.java`'s own doc
    // comment confirms this is foundational, not incidental: "this message is invoked automatically
    // by PumpX2 on connection with the pump so that the state can be tracked globally." This port's
    // `startPolling()` instead fired `fastRead()`'s CURRENT_STATUS reads FIRST, with
    // `ApiVersionRequest`/`TimeSinceResetRequest` not reached until position 9-10 of 13 inside
    // `staticRead()` — exactly matching capture #3 (op108 sent first, drop follows). Checked and
    // REFUTED directly against the reference: this is NOT a signing/HMAC requirement —
    // `Packetize.java`/`Packetize.swift` only append the 24-byte HMAC block when a message declares
    // `signed`/`@MessageProps(signed=true)`, and NONE of `ControlIQIOBRequest`, the EGV read,
    // `ApiVersionRequest`, `PumpVersionRequest`, or `TimeSinceResetRequest` do, in either the port or
    // the reference — it is purely a required FIRST-MESSAGE ORDER. `sendPostPairBootstrapReads()`
    // below sends that exact trio, in that order, directly, ahead of every other read every time
    // `startPolling()` (re)starts, matching the reference's required order exactly. (An earlier
    // post-pair settle DELAY was also tried here; on-device capture #3, cited above, refuted
    // settle-TIMING as a sufficient fix on its own, and it was removed once op192 stopped being sent
    // at all — the actual root cause — made it unnecessary; see `.planning/debug/pump-pairing-loop.md`.)
    /// Sends the reference-required post-auth bootstrap trio — `ApiVersionRequest`,
    /// `PumpVersionRequest`, `TimeSinceResetRequest`, in that order — ahead of any other read.
    /// Called once per `startPolling()` invocation (not from the recurring `pollTimer` tick's direct
    /// `fastRead()`/`staticRead()` calls, which intentionally do NOT re-run the bootstrap — the
    /// reference only sends it once, immediately after `onPumpConnected`/`onPaired`, not on every
    /// recurring poll).
    private func sendPostPairBootstrapReads() {
        for r: Message in [ApiVersionRequest(), PumpVersionRequest(), TimeSinceResetRequest()] {
            sendStatusRead(r)
        }
    }

    // MARK: - Single-flight glucose/calc-input coalescers (audit C-05, DIF-core)
    //
    // Concurrent callers coalesce onto ONE in-flight pump read and are all resumed exactly once when the
    // CGM reading/calc-input frames arrive, on timeout, or on disconnect. The generation tag makes a
    // stale timeout a no-op once its read has completed.
    private var glucoseWaiters: [CheckedContinuation<Void, Never>] = []
    private var glucoseReadGeneration = 0
    private var glucoseReadInFlight = false
    private var calcInputWaiters: [CheckedContinuation<Bool, Never>] = []
    private var calcInputReadGeneration = 0
    private var calcInputReadInFlight = false
    private var calcInputGotIob = false
    private var calcInputGotTherapy = false
    /// Bounded wait for `refreshCalcInputsNow` (safety timeout so a silent pump never hangs a compose).
    /// Overridable in tests to keep the fail-closed suite fast. Same 2.5 s default as the glucose refresh.
    var calcInputRefreshTimeout: TimeInterval = 2.5

    /// Force a fresh CGM read and wait (bounded ~2.5 s) for it, so a correction uses the newest value.
    /// Single-flight (audit C-05): concurrent callers coalesce onto one pump read; all are resumed
    /// exactly once when the reading arrives, on timeout, or on disconnect.
    func refreshGlucoseNow() async {
        guard isConnected() else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            glucoseWaiters.append(cont)
            if glucoseReadInFlight { return }   // join the in-flight read
            glucoseReadInFlight = true
            glucoseReadGeneration &+= 1
            let gen = glucoseReadGeneration
            // SEVENTH fix cycle: via `sendStatusRead` so the `badOpcodes` guard applies here too (see
            // its doc comment), and via `CurrentEGVGuiDataRequest` (V1, op34) rather than the V2
            // request — see `fastRead()`'s doc comment for why. If the read can't be sent at all,
            // release the coalesced waiters now instead of stalling every caller for the full 2.5s
            // timeout.
            guard sendStatusRead(CurrentEGVGuiDataRequest()) else {
                completeGlucoseRead()
                return
            }
            // Safety timeout so we never hang if the pump doesn't answer. Tagged by generation, so a
            // stale timeout whose read already completed is a no-op.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.glucoseReadInFlight, self.glucoseReadGeneration == gen else { return }
                self.completeGlucoseRead()
            }
        }
    }

    /// Resume every coalesced glucose waiter exactly once (CGM arrival, timeout, or disconnect). Public:
    /// called both internally and by `TandemBackend`'s response/error paths (`applyEgvReading`,
    /// `linkDroppedCleanup`, `applyClientError`) — safe to call even when no read is in flight (a no-op:
    /// clears an already-false flag and iterates an empty waiter list).
    func completeGlucoseRead() {
        glucoseReadInFlight = false
        let waiters = glucoseWaiters
        glucoseWaiters.removeAll()
        for w in waiters { w.resume() }
    }

    /// DIF-core: force a fresh op-115 (CR/ISF/target/max) + op-109 (IOB) read (public entry point for a
    /// display refresh; the confirmation result is only needed by `recommendBolus`, which calls
    /// `refreshCalcInputsConfirmed` directly).
    func refreshCalcInputsNow() async {
        _ = await refreshCalcInputsConfirmed()
    }

    /// DIF-core per-attempt freshness proof. Forces a fresh op-115 + op-109 read and waits (bounded) for
    /// BOTH, then RETURNS whether both frames were confirmed by the read this call participated in.
    /// Single-flight (audit C-05, modeled on `refreshGlucoseNow`): concurrent callers coalesce onto one
    /// read; all resume exactly once — with the SAME confirmation Bool — when both frames arrive, on
    /// timeout, or on disconnect. Never hangs (the safety timeout guarantees resumption).
    ///
    /// The returned Bool — not a wall-clock stamp comparison — is the authoritative gate, which fixes two
    /// hazards a `Date()`-based proof had: (1) a compose that JOINS an in-flight read gets that read's real
    /// outcome, so a healthy pump that answered both frames verifies even for the joiner (no spurious
    /// fail-closed on every keystroke-triggered overlapping compose); (2) there is no clock in the proof,
    /// so a backward wall-clock step can't make a stale value look freshly confirmed. `false` (⇒ fail
    /// closed) when not connected, on timeout (a frame never arrived), or on disconnect. `calcInputGotIob`/
    /// `calcInputGotTherapy` count only genuinely-received parsed frames (set via `noteCalcInputArrived`,
    /// called from the op-109/op-115 delegate handlers still in `TandemBackend`), so a cache can never
    /// satisfy the proof.
    @discardableResult
    func refreshCalcInputsConfirmed() async -> Bool {
        guard isConnected() else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            calcInputWaiters.append(cont)
            if calcInputReadInFlight { return }   // join the in-flight read; resumed with its result
            calcInputReadInFlight = true
            calcInputGotIob = false
            calcInputGotTherapy = false
            calcInputReadGeneration &+= 1
            let gen = calcInputReadGeneration
            // IN-02 (debug pump-pairing-loop-api25, deep review): route op-115/op-109 through the guarded
            // `sendStatusRead` (not the raw `send` seam) so they honour the `badOpcodes` never-resend guard,
            // record into `outstandingReads` for op77 correlation, and log — identical to every other status
            // read (and to `refreshGlucoseNow`'s own EGV send). Previously the raw seam would have re-sent
            // op-115/op-109 every cycle even if a pump rejected them (the exact pattern the fix eliminates
            // elsewhere) and left them out of correlation. Fire-and-forget as before (the confirmation is
            // driven by the op-109/op-115 response handlers via `noteCalcInputArrived`, unchanged).
            sendStatusRead(BolusCalcDataSnapshotRequest())
            sendStatusRead(ControlIQIOBRequest())
            // Safety timeout so a silent pump never hangs the compose. Tagged by generation, so a stale
            // timeout whose read already completed is a no-op.
            DispatchQueue.main.asyncAfter(deadline: .now() + calcInputRefreshTimeout) { [weak self] in
                guard let self, self.calcInputReadInFlight, self.calcInputReadGeneration == gen else { return }
                self.completeCalcInputRead()
            }
        }
    }

    /// Record that one of the two calc-input frames arrived since the read began; complete once BOTH have.
    /// A no-op when no read is in flight (routine polling also delivers these frames). Called from
    /// `TandemBackend`'s op-109/op-115 delegate handlers (still local this wave, D-07) on a
    /// genuinely-received frame — never from cache.
    ///
    /// Correlation caveat (§13 / Addendum G): frames are attributed to the in-flight read by OPCODE only,
    /// not per-request — the fire-and-forget reads carry no txId the delegate layer can match. So a
    /// routine-poll reply already in transit when the read began counts toward it. Bounded to ~1 s of
    /// possible staleness (the in-transit window) and clinically indistinguishable; per-request txId
    /// correlation (Addendum G, deferred to newer-firmware bench) is the complete fix.
    func noteCalcInputArrived(iob: Bool) {
        guard calcInputReadInFlight else { return }
        if iob { calcInputGotIob = true } else { calcInputGotTherapy = true }
        if calcInputGotIob && calcInputGotTherapy { completeCalcInputRead() }
    }

    /// Resume every coalesced calc-input waiter exactly once, with the read's confirmation (both frames
    /// arrived ⇒ true; timeout/disconnect ⇒ at least one flag false ⇒ false). The value is captured BEFORE
    /// the reset so a subsequent read cannot race it. Public: called both internally and by
    /// `TandemBackend`'s `linkDroppedCleanup`/`applyClientError` — safe to call even when no read is in
    /// flight (a no-op).
    func completeCalcInputRead() {
        calcInputReadInFlight = false
        let confirmed = calcInputGotIob && calcInputGotTherapy
        let waiters = calcInputWaiters
        calcInputWaiters.removeAll()
        for w in waiters { w.resume(returning: confirmed) }
    }

    // MARK: - Helpers (tiered polling to spare phone + pump battery)

    private var pollTick = 0

    /// Fast-changing state (~60 s): IOB, glucose, reservoir, last bolus, battery. Each send goes
    /// through `sendStatusRead()` (see its doc comment) for the `badOpcodes` guard + logging, but is
    /// otherwise sent directly with no artificial pacing between messages.
    ///
    /// SEVENTH fix cycle (`.planning/debug/pump-pairing-loop.md`, on-device capture #6): the CGM read
    /// here uses `CurrentEGVGuiDataRequest` (V1, op34), never `CurrentEgvGuiDataV2Request` (V2, op192).
    /// Capture #6 caught an older t:slim X2 (API 2.5) answering op192 with `ErrorResponse`/BAD_OPCODE
    /// and tearing the BLE link down ~70ms later — the actual root cause of this session's
    /// connect/pair/disconnect loop. The reference's own message metadata backs treating V2 as
    /// unconfirmed on any real pump, not just older ones: `CurrentEgvGuiDataV2Request.java`/
    /// `CurrentEgvGuiDataV2Response.java` both declare `minApi=KnownApiVersion.API_FUTURE` (99.99),
    /// higher than every cataloged real firmware version including the newest (`MOBI_API_V3_8`, 3.8) —
    /// `MessageProps.java`'s own default `minApi()` is `API_V2_1` (2.1, the earliest known version),
    /// so this is a deliberate override, not an oversight. The reference never sends V2 anywhere
    /// itself; its own automatic qualifying-event re-fetch (`QualifyingEvent.java`) uses V1
    /// (`CurrentEGVGuiDataRequest`) exclusively. V1 and V2 carry byte-identical cargo semantics (see
    /// TandemKit's `CurrentEGVGuiDataResponse`/`CurrentEgvGuiDataV2Response` doc comments), so using V1
    /// unconditionally costs no data on any pump generation — and it's what the owner's on-device
    /// re-capture confirmed holds the link on the API-2.5 pump. An earlier fix cycle here gated V2 vs
    /// V1 by a `>= 3` major-API-version heuristic; that threshold was never reference- or
    /// on-device-confirmed (no known pump has ever been shown to accept op192), so it was replaced by
    /// always sending V1 — simpler, and the only behavior actually verified safe. The opcode-agnostic
    /// `badOpcodes` backstop (`sendStatusRead`) stays regardless, as a safety net for any OTHER read
    /// the pump ever rejects.
    ///
    /// HomeScreenMirrorRequest belongs in the fast tier: it carries the pump's own CGM trend icon
    /// (C8 — the authoritative arrow), so it has to stay as fresh as the glucose value it annotates.
    ///
    /// EIGHTH fix cycle (`.planning/debug/pump-pairing-loop-api25.md`). op20 `LoadStatusRequest` IS in this
    /// recurring fast-read burst — restored here by the owner refinement (2026-08-19) after an initial fix
    /// (commit 9f978a5, mechanism A) had removed it for ALL models. Why it was restored: op20 feeds
    /// `PumpSnapshot.cartridgeLoadState`, which drives the 09.9 fail-closed bolus pre-guard
    /// `cartridgeReadyForBolus` (default `cartridgeLoadState=6` fails OPEN). Removing op20 from the poll for
    /// every model left that defense-in-depth pre-guard stale/ready on newer t:slim + Mobi (which DO support
    /// op20). So op20 is polled again; the API-2.5, non-Control-IQ t:slim X2 (sw 2.5) — which answers op20
    /// with an opcode-less op77 `[0,0]` and tears the BLE link down ~90 ms later — is handled instead by the
    /// mechanism-B op77 correlation backstop (`resolveErrorResponse`) plus DURABLE, per-pump persistence of
    /// the learned skip (`loadPersistedBadOpcodes`/`persistBadOpcode`, hydrated in `startPolling()` before
    /// this burst): that pump drops op20 exactly ONCE (first-ever connect), learns it, persists it keyed to
    /// its peripheral UUID, and skips it on every later connect AND after an app relaunch — no re-drop.
    /// A pump that supports op20 never adds it to the set, so its load-state (and the pre-guard) stays live.
    /// The same backstop+persistence covers any op40/op114/op178/op138 this firmware might also reject
    /// (unobservable from the capture, since the link tears down after the first error). op20 also stays
    /// reachable on-demand via `TandemBackend.refreshLoadStatus()` (`sendOnDemandRead`) for the pump wizard.
    private func fastRead() {
        for r: Message in [ControlIQIOBRequest(), CurrentEGVGuiDataRequest(),
                           InsulinStatusRequest(), LastBolusStatusV2Request(), CurrentBatteryV2Request(),
                           HomeScreenMirrorRequest(), LoadStatusRequest()] {
            sendStatusRead(r)
        }
    }

    /// Alerts/alarms/reminders/malfunctions — sent as a separate burst, spaced ~1.5s from
    /// `fastRead()`/`staticRead()` by `scheduleAlertRead()` below. Not `private`: also called directly
    /// by `TandemBackend.dismissNotification` (a 1.5s re-poll after a signed dismiss, outside the
    /// recurring cadence — that call site predates this move and stays unchanged).
    func alertRead() {
        for r: Message in [AlertStatusRequest(), AlarmStatusRequest(), CGMAlertStatusRequest(),
                           ReminderStatusRequest(), MalfunctionStatusRequest()] {
            sendStatusRead(r)
        }
    }

    /// Slow/static settings (once per connect + every ~10 min): basal, calculator snapshot
    /// (carb ratio/ISF/target/max), and the pump-clock anchor.
    private func staticRead() {
        // PumpFeaturesV1Request (op 78→79) is an unsigned empty current-status read — same shape as
        // ApiVersionRequest — so it rides the same send path here, behind auth by construction
        // (staticRead only runs after pairing, via startPolling). Its reply feeds `capabilities` (P13).
        for r: Message in [CurrentBasalStatusRequest(), BolusCalcDataSnapshotRequest(), TimeSinceResetRequest(),
                           ApiVersionRequest(), PumpFeaturesV1Request(), ControlIQInfoV2Request(),
                           BasalLimitSettingsRequest()] {
            sendStatusRead(r)
        }
    }

    // MARK: - CGM reading time + predictive polling (Bug 5)

    private var predictivePollTimer: Timer?
    private var predictiveBurstDeadline: Date?
    /// Predictive burst tuning. CGM cadence is ~5 min; start a little early and keep trying past the
    /// expected time until the reading advances, polling only the single EGV request (battery-light).
    private static let cgmIntervalSec: Double = 300
    private static let predictiveLeadSec: Double = 20
    private static let predictiveWindowSec: Double = 150
    private static let predictivePollEverySec: Double = 10
    /// Master switch; if predictive polling ever proves costly, set false to fall back to age-fix-only.
    var predictivePollingEnabled = true

    /// Convert a pump-clock reading timestamp to a real `Date` via the phone↔pump anchor. Clamps to
    /// `now`; falls back to `now` when there's no anchor or the result is implausibly far off (a sign
    /// the timestamp base is wrong), so a bad value can never masquerade as fresh or ancient. Called
    /// from `TandemBackend.applyEgvReading` (stays local this wave, D-07) via the injected
    /// `pumpTimeAnchor` provider.
    func cgmReadingDate(pumpSec: UInt32, now: Date) -> Date {
        guard pumpSec > 0, let a = pumpTimeAnchor() else { return now }
        let candidate = a.phone.addingTimeInterval(Double(Int64(pumpSec) - Int64(a.pump)))
        if candidate > now.addingTimeInterval(60) { return now }                 // future → clamp
        if now.timeIntervalSince(candidate) > 24 * 60 * 60 { return now }         // absurd past → fall back
        return candidate
    }

    /// Line up a short EGV-only poll burst around the next expected reading (~5 min after this one).
    /// A newly-arrived reading reschedules this, which naturally ends the previous burst. Called from
    /// `TandemBackend.applyEgvReading` (D-07) when the pump's reading timestamp has ADVANCED past the
    /// last one seen (that gate — `lastCgmPumpSec` — stays in `TandemBackend`, tightly coupled to
    /// `applyEgvReading` itself).
    func schedulePredictiveBurst(afterReadingAt readingDate: Date) {
        guard predictivePollingEnabled else { return }
        predictivePollTimer?.invalidate(); predictivePollTimer = nil
        let expected = readingDate.addingTimeInterval(Self.cgmIntervalSec)
        predictiveBurstDeadline = expected.addingTimeInterval(Self.predictiveWindowSec)
        let delay = max(1, expected.addingTimeInterval(-Self.predictiveLeadSec).timeIntervalSinceNow)
        predictivePollTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.runPredictiveBurst() }
        }
    }

    private func runPredictiveBurst() {
        predictivePollTimer?.invalidate(); predictivePollTimer = nil
        // Skip while a bolus is delivering (that path already fast-polls) or when disconnected.
        guard predictivePollingEnabled, isConnected() else { return }
        // SEVENTH fix cycle: both sends use `CurrentEGVGuiDataRequest` (V1, op34), never the V2
        // request — see `fastRead()`'s doc comment. `sendStatusRead` still applies the `badOpcodes`
        // guard here too, as a backstop for any OTHER read the pump ever rejects.
        sendStatusRead(CurrentEGVGuiDataRequest())
        predictivePollTimer = Timer.scheduledTimer(withTimeInterval: Self.predictivePollEverySec, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isConnected(),
                      let deadline = self.predictiveBurstDeadline, Date() < deadline else {
                    self?.predictivePollTimer?.invalidate(); self?.predictivePollTimer = nil; return
                }
                self.sendStatusRead(CurrentEGVGuiDataRequest())
            }
        }
    }

    // MARK: - Recurring poll cadence + generation guard

    /// The recurring `pollTimer` tick's body (originally extracted in Phase 09.2 Task 2, D-01/D-06 gap
    /// B2, from the `pollTimer` closure's four inline lines — verbatim: the tick-increment, the
    /// every-tick alert schedule, and the `%4`/`%40` fast/static gates, in the same order), so the
    /// cadence gating is directly callable — and therefore deterministically testable via
    /// `firePollTimerTickForTesting()` below — without waiting on a live 15s-repeating `Timer`.
    private func recurringPollTick() {
        pollTick += 1
        scheduleAlertRead()                            // ~15 s
        if pollTick % 4 == 0 { fastRead() }             // ~60 s
        if pollTick % 40 == 0 { staticRead() }          // ~10 min
    }

    func startPolling() {
        // Fresh connection/pairing cycle: bump the generation so a `scheduleAlertRead()` call armed
        // by a STALE, still-ticking `pollTimer` from a PRIOR connection cycle (see `scheduleAlertRead()`'s
        // doc comment) recognizes it's stale and no-ops, instead of injecting `alertRead()`'s messages
        // ahead of this cycle's own bootstrap trio.
        pollCycleGeneration += 1
        // Fresh connection cycle: drop any op77-correlation in-flight map from a prior cycle (unlike the
        // durable `badOpcodes` set, this transient map must not survive a reconnect — debug
        // pump-pairing-loop-api25, mechanism B).
        outstandingReads.removeAll()
        // debug pump-pairing-loop-api25 (refinement): hydrate the never-resend set from THIS pump's durable
        // store BEFORE any read goes out, so an opcode already proven unsupported by this pump — persisted
        // across reconnects AND app relaunches, keyed to pump identity (peripheral UUID + firmware stamp) —
        // is skipped from the very first `fastRead()` below (one-drop-ever; no re-drop after a relaunch). A
        // union (not a replace) so an opcode learned in-memory earlier this session is preserved too, and so
        // a pump that supports op20 (empty persisted set) keeps polling it and keeps its pre-guard live.
        // Guardrail A (hardening): filter the hydrated set so a foreign/legacy persisted delivery/control-
        // WRITE opcode can never be unioned straight into `badOpcodes` here (this union bypasses
        // `insertBadOpcode`'s guard) — the never-resend set stays reads-only by construction.
        // WR-05 (deep review): `loadPersistedBadOpcodes()` is evaluated into a local FIRST — on a firmware
        // change its provider (`TandemBackend`) resets the store AND calls `clearLearned(...)` to purge the
        // stale in-memory entries, so it must not run inside the `formUnion` argument (that would be a
        // simultaneous-access-to-`badOpcodes` violation). The subsequent union is then a clean, separate
        // mutation.
        let persisted = loadPersistedBadOpcodes()
        badOpcodes.formUnion(persisted.subtracting(PumpReadCatalog.deliveryControlWriteOpcodes))
        // Reference-required bootstrap trio FIRST (see "MARK: - Post-pair bootstrap order" above) —
        // must be sent ahead of fastRead()/staticRead()'s other CURRENT_STATUS reads, not after.
        sendPostPairBootstrapReads()
        fastRead(); staticRead()
        scheduleAlertRead()
        pollTick = 0
        pollTimer?.invalidate()
        predictivePollTimer?.invalidate(); predictivePollTimer = nil
        onStartPollingCycleBegin()   // resets TandemBackend's lastCgmPumpSec = 0
        // Tick every 15 s: alerts every tick (~15 s, so a new alert appears quickly on phone +
        // watch), the fuller fast-read every 4th tick (~60 s), settings every ~10 min. Alert
        // reads are cheap empty-cargo requests, so the tighter cadence barely affects battery.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recurringPollTick() }
        }
    }

    /// Bumped once per `startPolling()` call (i.e. once per connection/pairing-selection cycle) so a
    /// `scheduleAlertRead()` callback armed by a cycle that gets superseded by a NEWER
    /// reconnect/re-pair before its delay elapses recognizes it's stale and no-ops, instead of firing a
    /// rogue `alertRead()` burst on top of the newer cycle's already-in-progress reads. See
    /// `scheduleAlertRead()`'s doc comment for the FIFTH fix cycle mechanism this guards against.
    private var pollCycleGeneration = 0
    private var pollTimer: Timer?

    /// Send the alert reads ~1.5 s after the fast reads so they aren't in the same request burst.
    ///
    /// FIFTH fix cycle (`.planning/debug/pump-pairing-loop.md`, on-device capture #4 direct log
    /// analysis): captured evidence showed `alertRead()`'s messages (`AlertStatusRequest` et al.)
    /// dispatched BEFORE the bootstrap trio in roughly half of observed post-pair cycles, violating
    /// the FOURTH cycle's "bootstrap trio is always first" invariant even though `startPolling()`
    /// itself unconditionally calls `sendPostPairBootstrapReads()` before anything else. Root cause:
    /// `pollTimer` (armed by `startPolling()`, 15s repeating) was never invalidated on disconnect —
    /// only at the top of the NEXT `startPolling()` call — so a `pollTimer` from a cycle that dropped
    /// LESS than 15s after it started keeps ticking through the entire reconnect gap and its first
    /// tick can land squarely inside the NEXT cycle's post-pair window, calling `scheduleAlertRead()`
    /// again — which, at the time, had NO staleness guard at all — landing 1.5s later on an
    /// otherwise-idle connection and becoming the FIRST thing sent in the new cycle. Confirmed directly
    /// against the captured app log (not just theorized): cycle 2's `pollTimer`, created ~44.07s in,
    /// ticked once at ~59.07s (its own +15s), calling `scheduleAlertRead()` → firing `alertRead()` at
    /// ~60.57s — squarely between cycle 3's `pairing outcome → paired` (~59.79s) and cycle 3's own
    /// `startPolling()` — exactly matching the observed `AlertStatusRequest`-before-`ApiVersionRequest`
    /// corruption. Two-part fix, both closing this specific gap (NOT a delay/spacing VALUE tweak — no
    /// timing constant here changed): `TandemBackend.linkDroppedCleanup()` now invalidates `pollTimer`
    /// (via `invalidatePollTimerOnDisconnect()`) the instant the link is confirmed down (stops a stale
    /// timer from ever ticking again into a future, unrelated cycle), and this function's deferred call
    /// captures `pollCycleGeneration` and re-checks it before running `alertRead()` (stops any
    /// ALREADY-armed stale call — whether from a `pollTimer` tick or this function's own original
    /// invocation — that's still in flight when a NEWER `startPolling()` has since restarted the cycle).
    private static let defaultAlertReadDelaySec: Double = 1.5
    #if DEBUG
    /// Test-only: override `scheduleAlertRead()`'s delay so a test can exercise the generation guard
    /// deterministically without waiting the real 1.5s. `nil` (default) uses the real production delay
    /// — this seam changes no production behavior, only testability.
    var alertReadDelaySecForTesting: Double?
    #endif
    private var alertReadDelaySec: Double {
        #if DEBUG
        if let override = alertReadDelaySecForTesting { return override }
        #endif
        return Self.defaultAlertReadDelaySec
    }

    private func scheduleAlertRead() {
        let generation = pollCycleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + alertReadDelaySec) { [weak self] in
            guard let self, generation == self.pollCycleGeneration else { return }
            self.alertRead()
        }
    }

    // MARK: - Timer lifecycle for TandemBackend's non-polling call sites
    //
    // Three distinct shapes, all behavior-preserving moves of what used to be inline `pollTimer`/
    // `predictivePollTimer` manipulation directly in `TandemBackend`:

    /// `TandemBackend.perform()`'s mid-bolus pause (DO-NOT-TOUCH signed path, D-08): stop the recurring
    /// timer from firing DURING delivery so its reads don't interfere, without clearing the reference —
    /// `perform`'s `defer { readScheduler.startPolling() }` always runs next (success or throw) and
    /// unconditionally replaces `pollTimer` with a fresh one, so leaving the invalidated `Timer` in place
    /// in between is harmless (mirrors the pre-extraction inline `pollTimer?.invalidate()` exactly).
    func pausePollingForDelivery() { pollTimer?.invalidate() }

    /// `TandemBackend.linkDroppedCleanup()`: the link is genuinely down and NOT always immediately
    /// followed by `startPolling()`, so — unlike `pausePollingForDelivery()` — the reference must be
    /// cleared too, or a stale invalidated `Timer` instance would sit in `pollTimer` indefinitely.
    func invalidatePollTimerOnDisconnect() { pollTimer?.invalidate(); pollTimer = nil }

    /// `TandemBackend.disconnect()` / the `*ForTesting` seams below: stop BOTH timers entirely.
    func stopAllTimers() {
        pollTimer?.invalidate(); pollTimer = nil
        predictivePollTimer?.invalidate(); predictivePollTimer = nil
    }

    #if DEBUG
    // MARK: - Test seams (forwarded from TandemBackend under the same names, D-01/D-06)

    /// Test seam: runs the REAL `startPolling()` then immediately stops the Timers a live app would
    /// keep running — this seam only wants the synchronous send-order effect for assertion, not a real
    /// 15 s-repeating background `Timer` ticking during a unit test.
    func startPollingForTesting() {
        startPolling()
        stopAllTimers()
    }

    /// Test seam: exercises the recurring `pollTimer` tick's coincidence where `fastRead()` AND
    /// `staticRead()` fire together (every 40th tick, since 40 is divisible by 4 — see the ticker in
    /// `startPolling()`) directly, without waiting on a real `Timer`.
    func simulateRecurringFastAndStaticReadTickForTesting() {
        fastRead()
        staticRead()
    }

    /// Phase 09.2 Task 2 test seam (D-01/D-06, gap B2): fires the REAL recurring `pollTimer` tick body
    /// (`recurringPollTick()`) directly, without waiting on the live 15s-repeating `Timer` — unlike
    /// `simulateRecurringFastAndStaticReadTickForTesting()` above (which calls `fastRead()`/`staticRead()`
    /// directly, bypassing the `%4`/`%40` cadence gating entirely), this seam exercises the SAME gating
    /// the production timer runs, so a test can pin alerts-every-tick / fast-on-%4 / static-on-%40 across
    /// a sequence of ticks.
    func firePollTimerTickForTesting() { recurringPollTick() }

    /// FIFTH fix cycle test seam: like `startPollingForTesting()` but does NOT immediately invalidate
    /// `pollTimer` — lets a test observe that `pollTimer` is a live `Timer` right after `startPolling()`
    /// runs, then separately verify `TandemBackend.linkDroppedCleanup()` (via `applyClientState`) is what
    /// tears it down, rather than this seam's own cleanup masking the question. `predictivePollTimer` is
    /// still stopped here (unrelated to this fix; same hygiene reason `startPollingForTesting()` stops it).
    func startPollingLeavingPollTimerRunningForTesting() {
        startPolling()
        predictivePollTimer?.invalidate(); predictivePollTimer = nil
    }
    /// Test accessor: whether `pollTimer` currently holds a live (non-nil) `Timer`.
    var pollTimerIsActiveForTesting: Bool { pollTimer != nil }

    /// Test accessor (Phase 09.2 Task 3, gap B5): the predictive-burst deadline `schedulePredictiveBurst`
    /// last armed — read-only, mirrors `pollTimerIsActiveForTesting`'s shape. Lets a test pin that an
    /// advancing EGV reading schedules a burst (deadline becomes non-nil) and that a LATER advancing
    /// reading reschedules it (the deadline moves forward), with no live `Timer` fired or waited on.
    var predictiveBurstDeadlineForTesting: Date? { predictiveBurstDeadline }

    /// SEVENTH fix cycle test seam: run one predictive-burst kick (the second and third of the three
    /// direct EGV send sites). Lets a test prove those sends honour the `badOpcodes` guard exactly like
    /// every other status read.
    func simulatePredictiveBurstForTesting() { runPredictiveBurst() }
    #endif
}
