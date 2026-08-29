import Foundation
import TandemMessages
import os

/// BLE read cascade **send side**. Owns the post-pair bootstrap trio, tiered read lists,
/// poll cadence, predictive burst, coalescers, and the `badOpcodes` never-resend backstop.
/// Depends only on injected closures — never a whole-`TandemBackend` back-pointer.
/// No wire bytes, send order, or cadence change.
@MainActor
final class PumpReadScheduler {
    /// Same subsystem/category as `TandemBackend.pairingLog` — declared separately (that constant is
    /// `private` to `TandemBackend`) so the merged `log show` timeline still shows every "read send →"
    /// line from this scheduler alongside the pairing/response lines TandemBackend itself still logs.
    private static let pairingLog = Logger(subsystem: "com.fabolus.app", category: "ble")

    // MARK: - Injected seams (settable post-construction)

    /// Bound to `client.send` via `tx` (byte-identical wire path — this scheduler never touches BLE
    /// directly). Returns the wire txId so `sendStatusRead` can correlate an opcode-less op77
    /// `ErrorResponse` back to the read that provoked it.
    var send: (Message) throws -> UInt8 = { _ in 0 }
    /// Bound to `snapshot.connection == .connected`.
    var isConnected: () -> Bool = { false }
    /// Bound to `pumpTimeAnchor` (the phone↔pump clock anchor TandemBackend owns).
    var pumpTimeAnchor: () -> (pump: UInt32, phone: Date)? = { nil }
    /// Bound to `{ responseApplier.resetCycleState() }` — `lastCgmPumpSec` lives with
    /// `applyEgvReading` in `PumpResponseApplier`, but its reset is part of `startPolling()`'s
    /// fresh-connection-cycle setup, which lives here. This hook keeps that reset atomic with
    /// the rest of cycle-begin work.
    var onStartPollingCycleBegin: () -> Void = {}
    /// This pump's durable learned-bad-opcode set — opcodes this specific pump rejected on a
    /// PRIOR connection (persisted across reconnects AND app relaunches, keyed to pump identity).
    /// `startPolling()` folds it into `badOpcodes` BEFORE any read goes out, so an opcode already
    /// proven unsupported by THIS pump is skipped from the very first `fastRead()` — the API-2.5
    /// t:slim X2 drops op20 exactly once (first-ever connect), never again, and never after a
    /// relaunch. Bound to a peripheral-UUID-keyed `PumpBadOpcodeStore`; default returns nothing.
    var loadPersistedBadOpcodes: () -> Set<UInt8> = { [] }
    /// Persist one newly-learned rejected opcode durably, keyed to the current pump, so it
    /// survives a reconnect and an app relaunch. Default is a no-op. Never called with op0
    /// (`insertBadOpcode` guards it).
    var persistBadOpcode: (UInt8) -> Void = { _ in }
    /// Current pump identity — model class (`isMobi`) + `softwareVersion` — as populated by the
    /// bootstrap version responses (op33/op85). Consulted by `noteBootstrapVersionIdentified()`
    /// to key the static `PumpKnownUnsupportedReads` registry so a known-bad combo's identity-gated
    /// read (op20) is seeded into `badOpcodes` BEFORE it is ever sent — including the first-ever
    /// connect with no persisted history. Default returns an unknown identity (empty exclusion).
    var pumpIdentityForStaticExclusion: () -> (isMobi: Bool?, softwareVersion: String) = { (nil, "") }

    // MARK: - Status read dispatch
    //
    // Reads are sent directly with no app-level pacing. A capture that showed an unthrottled
    // 13-message burst answered 0/13 isolated the drop to ONE opcode: `CurrentEgvGuiDataV2Request`
    // (op192), answered with `ErrorResponse`/BAD_OPCODE ~70ms later; once the pump drops the link,
    // every other already-in-flight read also goes unanswered. The vendored jwoglom/pumpx2-oracle
    // `TandemPump.java#onPumpConnected` fires its `ApiVersionRequest`/`PumpVersionRequest`/
    // `TimeSinceResetRequest` trio via `sendCommand()` back-to-back, relying on the same OS-level
    // write serialization `PumpBLEClient.send()`/CoreBluetooth already provide for `.withResponse`
    // writes (`WriteType.WITH_RESPONSE` in the reference). With op192 no longer sent and the
    // `badOpcodes` backstop in place, an app-level queue had no independent justification.
    /// Opcodes the pump has explicitly rejected with `ErrorResponse` this connection-lifetime —
    /// `sendStatusRead()` silently skips any message whose opcode is in this set, so a single
    /// BAD_OPCODE can never re-trigger the observed teardown loop. Opcode-agnostic backstop,
    /// independent of per-message version handling. Deliberately NOT reset on disconnect: an
    /// opcode already proven unsupported by THIS pump stays proven across a BLE reconnect —
    /// re-learning it every cycle would reproduce one bad exchange (and its ~70ms drop risk)
    /// on every reconnect.
    ///
    /// Also hydrated at each `startPolling()` from a durable, per-pump store
    /// (`loadPersistedBadOpcodes`) and every insertion is persisted (`persistBadOpcode`), keyed
    /// to pump identity (peripheral UUID + firmware stamp). The API-2.5 t:slim X2 drops op20
    /// exactly once, ever. A different pump/firmware never inherits this skip and keeps polling
    /// op20 (keeping the `cartridgeReadyForBolus` pre-guard live on pumps that support it).
    private var badOpcodes: Set<UInt8> = []
    /// Sends one CURRENT_STATUS/pairing-adjacent read directly. Applies the `badOpcodes`
    /// never-resend guard and logs type/opcode/send outcome as `"read send →"` — distinct from
    /// TandemBackend's `"pairing send →"`/`"pairing recv ←"` lines. Never logs cargo/payload bytes.
    @discardableResult
    private func sendStatusRead(_ message: Message) -> Bool {
        let typeName = String(describing: type(of: message))
        let opcode = message.opCode
        // Never re-send an opcode the pump has already rejected with ErrorResponse this
        // connection-lifetime — see `badOpcodes`'s doc comment.
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
            // Remember this read's wire txId so an opcode-less op77 `ErrorResponse` (real 2-byte
            // currentStatus cargo `[0,0]` on this API-2.5 t:slim X2) can be correlated back to the
            // read that provoked it — see `resolveErrorResponse`. Only recorded on a genuine send
            // (never on a throw), so a never-sent read can't poison the correlation.
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
    /// Test seam: fires instead of `onReadDispatchedForTesting` when `sendStatusRead` SKIPS a
    /// read because its opcode is in `badOpcodes`.
    var onReadSkippedForTesting: ((_ typeName: String, _ opcode: UInt8) -> Void)?
    #endif

    /// Feed for the `ErrorResponse` delegate case — records an opcode the pump has just rejected
    /// so `sendStatusRead()` never re-sends it this connection-lifetime, AND persists it durably
    /// for this pump so the skip survives a reconnect and an app relaunch. op0 is never suppressed
    /// — it is the empty-cargo artifact / bootstrap opcode; `resolveErrorResponse` never resolves
    /// to it, and this guard is the belt-and-suspenders.
    func insertBadOpcode(_ opcode: UInt8) {
        guard opcode != 0 else { return }
        // The never-resend set governs ONLY CURRENT_STATUS reads (`sendStatusRead`). It must NEVER
        // hold a pure delivery/control-WRITE opcode — otherwise an op77 whose cargo NAMES a delivery
        // command (`resolveErrorResponse`'s `named` path) could record e.g. InitiateBolus here.
        // `PumpReadCatalog.deliveryControlWriteOpcodes` deliberately EXCLUDES read-colliding opcodes
        // (op164/op144), so a colliding READ still self-heals; the `.control` delivery path never
        // consults this set, so this guard removes the only way a delivery opcode could ever enter it.
        guard !PumpReadCatalog.deliveryControlWriteOpcodes.contains(opcode) else { return }
        badOpcodes.insert(opcode)
        // A dose-input READ (op108 IOB / op115 therapy) may be skipped for the REST of this
        // session (it stays in the in-memory `badOpcodes` above, so it is not re-thrashed every
        // 15 s poll), but it must NEVER be written to the durable per-pump store — persisting it
        // bricks the bolus calculator forever with no re-probe (op109 is the sole IOB source).
        // `startPolling`'s hydration union drops these from the carried-over set each connect, so
        // a one-off op77 self-heals on the next connection/relaunch instead of permanently
        // starving `recommendBolus`.
        guard !PumpReadCatalog.doseInputReadOpcodes.contains(opcode) else { return }
        // Same as the dose-input guard for the alert-read burst (op72-76, incl. op74
        // `CGMAlertStatusRequest`) — `alertRead()` sends all 5 back-to-back with no per-message
        // throttling, so a transient op77 can be mis-correlated to ANY of them. A durable skip
        // would permanently silence the phone-side CGM-alert mirror with no re-probe.
        guard !PumpReadCatalog.alertReadOpcodes.contains(opcode) else { return }
        persistBadOpcode(opcode)
    }

    /// Drop opcodes from the IN-MEMORY never-resend set. `badOpcodes` deliberately survives a
    /// reconnect for the scheduler's lifetime, so when the durable per-pump store is reset on a
    /// firmware change (same UUID, new `softwareVersion`) the in-memory copy learned under the OLD
    /// firmware must be purged too — otherwise a firmware update that newly supports op20 keeps it
    /// skipped until the app is relaunched. Called by `TandemBackend`'s firmware-change detection
    /// BEFORE the fresh union in `startPolling`.
    func clearLearned(_ opcodes: Set<UInt8>) {
        badOpcodes.subtract(opcodes)
    }

    // MARK: - Static known-unsupported-reads registry
    //
    // The dynamic op77 self-heal above learns an unsupported read AFTER the pump rejects it once
    // (a ~2-3-drop / ~25 s cost on a first-ever connect). For a combo the app already KNOWS is
    // bad (`PumpKnownUnsupportedReads`), that cost is avoidable: hold the identity-gated read(s)
    // (op20) OUT of the pre-version burst, and once the bootstrap version responses (op33/op85)
    // identify the pump, seed the static exclusion into `badOpcodes` BEFORE the gated read is
    // ever sent. Additive to the dynamic path and to the per-pump persisted store (this
    // exclusion is re-derived from identity every connect, never persisted).

    /// Set true once this connection's bootstrap version responses (op33 `ApiVersionResponse`, which carries
    /// the model/firmware identity) have been processed. Reset each `startPolling()` cycle.
    private var bootstrapVersionIdentified = false
    /// Guards `runIdentityGatedReadsOnce()` so the deferred identity-gated read(s) go out exactly once per
    /// connection cycle (op33 can arrive from both the bootstrap trio and the ~10-min `staticRead()`). Reset
    /// each `startPolling()` cycle.
    private var identityGatedReadsDispatchedThisCycle = false

    /// Called by the applier the moment the bootstrap version response (op33) has populated the pump identity
    /// (`snapshot.isMobi` + `softwareVersion`). Consults the STATIC registry with that identity, seeds any
    /// known-unsupported read into `badOpcodes` (Guardrail-A filtered), then dispatches the deferred
    /// identity-gated read(s) ONCE — so on a known-bad combo the gated read is already suppressed and never
    /// sent, while on any other pump it goes out and keeps its pre-guard live.
    func noteBootstrapVersionIdentified() {
        bootstrapVersionIdentified = true
        runIdentityGatedReadsOnce()
    }

    private func runIdentityGatedReadsOnce() {
        guard bootstrapVersionIdentified, !identityGatedReadsDispatchedThisCycle else { return }
        identityGatedReadsDispatchedThisCycle = true
        // STATIC known-unsupported registry → seed the exclusion BEFORE the gated read is sent. Guardrail A:
        // filter out any delivery/control-WRITE opcode (belt-and-suspenders — the registry only ever names
        // reads, but the union bypasses `insertBadOpcode`'s guard, so mirror it here). NOT persisted: this is
        // authoritative-per-identity, re-derived each connect, kept distinct from the learned store.
        let id = pumpIdentityForStaticExclusion()
        let staticExclusions = PumpKnownUnsupportedReads
            .unsupportedReadOpcodes(isMobi: id.isMobi, softwareVersion: id.softwareVersion)
            .subtracting(PumpReadCatalog.deliveryControlWriteOpcodes)
        badOpcodes.formUnion(staticExclusions)
        // Now send the deferred identity-gated reads; on a known-bad combo they are already in `badOpcodes`
        // (either statically seeded just above, or from the dynamic/persisted set) → `sendStatusRead` skips
        // them, so they are never sent even once.
        for r in fastReadMessages() where PumpKnownUnsupportedReads.identityGatedReadOpcodes.contains(r.opCode) {
            sendStatusRead(r)
        }
    }

    // MARK: - op77 correlation backstop
    //
    // The `badOpcodes` backstop assumed an inbound op77 `ErrorResponse` names the failing opcode
    // in its cargo. It does for BAD_OPCODE (errorCodeId 6, requestCodeId = the opcode), but the
    // API-2.5 non-Control-IQ t:slim X2 answers an unsupported currentStatus read (op20 LoadStatus,
    // and possibly op40/op114/op178/op138) with a size-2 cargo of `[0,0]` — errorCode
    // UNDEFINED_ERROR, NO opcode — then tears the BLE link down. Trusting that empty cargo records
    // opcode 0 (useless), so the read is re-sent every reconnect. The true opcode is recoverable
    // only by CORRELATION: the pump echoes the request txId in the inbound frame's frame[1]
    // (kit's hardware-confirmed t:slim behavior), or, failing that, by in-order FIFO of the
    // reads still outstanding this connection.

    /// Reads sent this connection whose (non-error) reply may still be outstanding, most-recent last.
    /// Deduped by opcode (an opcode re-sent refreshes its txId), so it stays bounded to the ~20 distinct
    /// reads. Cleared at each fresh `startPolling()` cycle. NOT the `badOpcodes` set — this is the
    /// transient in-flight map the op77 correlation consults, not the durable never-resend proof.
    private var outstandingReads: [(txId: UInt8, opcode: UInt8)] = []
    private func recordOutstandingRead(txId: UInt8, opcode: UInt8) {
        outstandingReads.removeAll { $0.opcode == opcode }
        outstandingReads.append((txId: txId, opcode: opcode))
    }

    /// Resolve an inbound op77 `ErrorResponse` to the TRUE failing opcode, record it in the
    /// never-resend `badOpcodes` set, and RETURN it for the caller's diagnostic log line.
    /// - When the cargo names the opcode (`requestCodeId != 0`) that value is authoritative.
    /// - When the cargo is opcode-less (`requestCodeId == 0`, the `[0,0]` currentStatus variant
    ///   this firmware sends), correlate to the outstanding read: PRIMARY via the echoed request
    ///   txId (frame[1]); if that matches nothing, use the exactly-one-outstanding shortcut
    ///   (unambiguous even without an echo); otherwise FAIL CLOSED.
    /// Returns 0 when nothing can be safely correlated — so opcode 0 is never what gets
    /// suppressed, and no INNOCENT read is guessed at.
    ///
    /// A blind FIFO-oldest fallback (`outstandingReads.first`) was doubly wrong for the read
    /// this targets — op20 is `fastRead()`'s LAST send, so "oldest outstanding" is always a
    /// bootstrap/early read (ApiVersion, ControlIQIOB), never op20. An echo-less op77 under a
    /// full burst would therefore durably blacklist an innocent supported read (e.g. op109
    /// ControlIQIOB, a dose input) AND leave op20 un-suppressed. Guessing the oldest is never
    /// safe: prefer the txId echo, accept only the unambiguous single-outstanding case, else
    /// resolve to 0.
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
            resolved = 0                                       // FAIL CLOSED — never guess the oldest
        }
        if resolved != 0 {
            insertBadOpcode(resolved)   // in-memory never-resend skip + durable per-pump persist (refinement)
            outstandingReads.removeAll { $0.opcode == resolved }
        }
        return resolved
    }

    /// On-demand single status read (e.g. the pump wizard's `refreshLoadStatus()`), routed through
    /// the same guarded `sendStatusRead()` as the tiered polls so it honours the `badOpcodes`
    /// never-resend guard, is observable via the test seams, and records the outstanding read for
    /// op77 correlation. op20 LoadStatus rides BOTH the recurring `fastRead()` poll AND this
    /// on-demand path; both consult the same per-pump persisted skip, so on the API-2.5 pump that
    /// learned op20 is unsupported, neither re-sends it, while a supported pump keeps its
    /// load-state fresh.
    @discardableResult
    func sendOnDemandRead(_ message: Message) -> Bool { sendStatusRead(message) }
    /// Test accessor: opcodes currently marked as pump-rejected (never re-sent this session).
    var badOpcodesForTesting: Set<UInt8> { badOpcodes }
    #if DEBUG
    /// Test accessor: the in-flight op77-correlation map (txId → opcode) as recorded by
    /// `sendStatusRead` this cycle. Lets a burst test look up a SPECIFIC read's real wire txId
    /// (e.g. op20's) so it can inject an op77 echoing exactly that txId and prove the
    /// correlation resolves to THAT read, not the FIFO-oldest.
    var outstandingReadsForTesting: [(txId: UInt8, opcode: UInt8)] { outstandingReads }
    #endif
    /// Production read accessor for the `[Capability/opcode]` diagnostics section — mirrors
    /// `badOpcodesForTesting` exactly (additive, internal, no new send/re-derivation). Consumed via
    /// `TandemBackend.badOpcodesForDiagnostics` → `AppModel.badOpcodesForDiagnostics`.
    var badOpcodesForDiagnostics: Set<UInt8> { badOpcodes }

    // MARK: - Post-pair bootstrap order
    //
    // The vendored jwoglom/pumpX2 reference (`TandemKit/vendor/pumpx2-oracle/.../TandemPump.java`,
    // `onPumpConnected`, and `TandemBluetoothHandler.java`'s JPAKE-success branches) ALWAYS sends
    // exactly `ApiVersionRequest`, then `PumpVersionRequest`, then `TimeSinceResetRequest` — in
    // that order — as the FIRST GATT traffic issued post-auth. `ApiVersionRequest.java`'s own doc
    // comment: "this message is invoked automatically by PumpX2 on connection with the pump so
    // that the state can be tracked globally." This is NOT a signing/HMAC requirement —
    // `Packetize.java`/`Packetize.swift` only append the 24-byte HMAC block when a message
    // declares `signed`/`@MessageProps(signed=true)`, and NONE of `ControlIQIOBRequest`, the EGV
    // read, `ApiVersionRequest`, `PumpVersionRequest`, or `TimeSinceResetRequest` do. Sending a
    // CURRENT_STATUS read first (op108 ControlIQIOB) dropped the link ~315ms later. A post-pair
    // settle DELAY was also tried; capture showed the pump held an idle freshly-paired V1 link
    // for 1.5s, then dropped on the first post-settle read — settle-timing is not sufficient.
    /// Sends the reference-required post-auth bootstrap trio — `ApiVersionRequest`,
    /// `PumpVersionRequest`, `TimeSinceResetRequest`, in that order — ahead of any other read.
    /// Called once per `startPolling()` (not from the recurring `pollTimer` tick, which
    /// intentionally does NOT re-run the bootstrap — the reference only sends it once,
    /// immediately after `onPumpConnected`/`onPaired`).
    private func sendPostPairBootstrapReads() {
        for r: Message in [ApiVersionRequest(), PumpVersionRequest(), TimeSinceResetRequest()] {
            sendStatusRead(r)
        }
    }

    // MARK: - Single-flight glucose/calc-input coalescers
    //
    // Concurrent callers coalesce onto ONE in-flight pump read and are all resumed exactly once when
    // the CGM reading/calc-input frames arrive, on timeout, or on disconnect. The generation tag
    // makes a stale timeout a no-op once its read has completed.
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
    /// Single-flight: concurrent callers coalesce onto one pump read; all are resumed exactly once
    /// when the reading arrives, on timeout, or on disconnect.
    func refreshGlucoseNow() async {
        guard isConnected() else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            glucoseWaiters.append(cont)
            if glucoseReadInFlight { return }   // join the in-flight read
            glucoseReadInFlight = true
            glucoseReadGeneration &+= 1
            let gen = glucoseReadGeneration
            // Via `sendStatusRead` so the `badOpcodes` guard applies here too, and via
            // `CurrentEGVGuiDataRequest` (V1, op34) rather than the V2 request — see `fastRead()`'s
            // doc comment. If the read can't be sent at all, release the coalesced waiters now
            // instead of stalling every caller for the full 2.5s timeout.
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

    /// Force a fresh op-115 (CR/ISF/target/max) + op-109 (IOB) read (public entry point for a
    /// display refresh; the confirmation result is only needed by `recommendBolus`, which calls
    /// `refreshCalcInputsConfirmed` directly).
    func refreshCalcInputsNow() async {
        _ = await refreshCalcInputsConfirmed()
    }

    /// Per-attempt freshness proof. Forces a fresh op-115 + op-109 read and waits (bounded) for
    /// BOTH, then RETURNS whether both frames were confirmed by the read this call participated in.
    /// Single-flight: concurrent callers coalesce onto one read; all resume exactly once — with the
    /// SAME confirmation Bool — when both frames arrive, on timeout, or on disconnect. Never hangs.
    ///
    /// The returned Bool — not a wall-clock stamp comparison — is the authoritative gate, which
    /// fixes two hazards a `Date()`-based proof had: (1) a compose that JOINS an in-flight read
    /// gets that read's real outcome, so a healthy pump that answered both frames verifies even
    /// for the joiner (no spurious fail-closed on every keystroke-triggered overlapping compose);
    /// (2) there is no clock in the proof, so a backward wall-clock step can't make a stale value
    /// look freshly confirmed. `false` (⇒ fail closed) when not connected, on timeout, or on
    /// disconnect. Flags count only genuinely-received parsed frames (set via
    /// `noteCalcInputArrived`), so a cache can never satisfy the proof.
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
            // Route op-115/op-109 through the guarded `sendStatusRead` (not the raw `send` seam)
            // so they honour the `badOpcodes` never-resend guard, record into `outstandingReads`
            // for op77 correlation, and log — identical to every other status read. Fire-and-forget
            // as before (confirmation is driven by the response handlers via `noteCalcInputArrived`).
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
    /// `TandemBackend`'s op-109/op-115 delegate handlers on a genuinely-received frame — never from cache.
    ///
    /// Correlation caveat: frames are attributed to the in-flight read by OPCODE only, not per-request
    /// — the fire-and-forget reads carry no txId the delegate layer can match. So a routine-poll reply
    /// already in transit when the read began counts toward it. Bounded to ~1 s of possible staleness
    /// (the in-transit window) and clinically indistinguishable; per-request txId correlation is the
    /// complete fix (deferred to newer-firmware bench).
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
    /// through `sendStatusRead()` for the `badOpcodes` guard + logging, but is otherwise sent
    /// directly with no artificial pacing between messages.
    ///
    /// The CGM read uses `CurrentEGVGuiDataRequest` (V1, op34), never `CurrentEgvGuiDataV2Request`
    /// (V2, op192). An older t:slim X2 (API 2.5) answers op192 with `ErrorResponse`/BAD_OPCODE and
    /// tears the BLE link down ~70ms later. The reference's own message metadata backs treating V2
    /// as unconfirmed on any real pump: `CurrentEgvGuiDataV2Request.java` /
    /// `CurrentEgvGuiDataV2Response.java` both declare `minApi=KnownApiVersion.API_FUTURE` (99.99),
    /// higher than every cataloged real firmware including the newest (`MOBI_API_V3_8`, 3.8) —
    /// `MessageProps.java`'s own default `minApi()` is `API_V2_1` (2.1), so this is a deliberate
    /// override. The reference never sends V2 anywhere itself; its own automatic qualifying-event
    /// re-fetch (`QualifyingEvent.java`) uses V1 exclusively. V1 and V2 carry byte-identical cargo
    /// semantics, so using V1 unconditionally costs no data. An earlier `>= 3` major-API heuristic
    /// was never reference- or on-device-confirmed (no known pump has been shown to accept op192).
    /// The opcode-agnostic `badOpcodes` backstop stays regardless.
    ///
    /// HomeScreenMirrorRequest belongs in the fast tier: it carries the pump's own CGM trend icon
    /// (the authoritative arrow), so it has to stay as fresh as the glucose value it annotates.
    ///
    /// op20 `LoadStatusRequest` IS in this recurring burst. It feeds `PumpSnapshot.cartridgeLoadState`,
    /// which drives the fail-closed bolus pre-guard `cartridgeReadyForBolus` (default
    /// `cartridgeLoadState=6` fails OPEN). Removing op20 from the poll for every model left that
    /// pre-guard stale/ready on newer t:slim + Mobi (which DO support op20). The API-2.5
    /// non-Control-IQ t:slim X2 (sw 2.5) — which answers op20 with an opcode-less op77 `[0,0]` and
    /// tears the BLE link down ~90 ms later — is handled by the op77 correlation backstop plus
    /// durable, per-pump persistence of the learned skip: that pump drops op20 exactly ONCE
    /// (first-ever connect), learns it, persists it keyed to its peripheral UUID, and skips it on
    /// every later connect AND after an app relaunch. A pump that supports op20 never adds it to
    /// the set, so its load-state (and the pre-guard) stays live. The same backstop covers any
    /// op40/op114/op178/op138 this firmware might also reject. op20 also stays reachable on-demand
    /// via `TandemBackend.refreshLoadStatus()`.
    /// The fast tier's exact ordered read list (single source of truth for both the recurring
    /// `fastRead()` and the deferred identity-gated dispatch in `runIdentityGatedReadsOnce()`).
    private func fastReadMessages() -> [Message] {
        [ControlIQIOBRequest(), CurrentEGVGuiDataRequest(),
         InsulinStatusRequest(), LastBolusStatusV2Request(), CurrentBatteryV2Request(),
         HomeScreenMirrorRequest(), LoadStatusRequest()]
    }

    /// - Parameter includingIdentityGatedReads: when `false` (the pre-version burst inside `startPolling()`),
    ///   reads in `PumpKnownUnsupportedReads.identityGatedReadOpcodes` (op20 `LoadStatusRequest`) are HELD
    ///   BACK — not sent, not skipped — so a KNOWN-bad combo can suppress them via the static registry BEFORE
    ///   the first send (see `runIdentityGatedReadsOnce()`); they are dispatched once the bootstrap version
    ///   responses identify the pump. Every other path (the recurring `pollTimer` tick, refresh seams)
    ///   passes `true`, so op20 rides the recurring poll and the `badOpcodes` guard skips it only when the
    ///   pump (statically or dynamically) proved it unsupported — the pre-guard stays live on supported pumps.
    private func fastRead(includingIdentityGatedReads: Bool = true) {
        for r in fastReadMessages() {
            if !includingIdentityGatedReads,
               PumpKnownUnsupportedReads.identityGatedReadOpcodes.contains(r.opCode) { continue }
            sendStatusRead(r)
        }
    }

    /// Alerts/alarms/reminders/malfunctions — sent as a separate burst, spaced ~1.5s from
    /// `fastRead()`/`staticRead()` by `scheduleAlertRead()` below. Also called directly by
    /// `TandemBackend.dismissNotification` (a 1.5s re-poll after a signed dismiss).
    /// `HighestAamRequest`/`ActiveAamBitsRequest` (op120/op146) are NOT in this burst — they were
    /// dead plumbing (no UI/decision consumer) AND, auto-polled to a Control-IQ-off / no-CGM
    /// API-2.5 t:slim X2, provoked an op-77 + BLE teardown. The static
    /// `PumpKnownUnsupportedReads` {op120,op146} entries + the TandemKit op120 minApi floor stay
    /// as backstops if AAM is ever re-added.
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
        // (staticRead only runs after pairing, via startPolling). Its reply feeds `capabilities`.
        for r: Message in [CurrentBasalStatusRequest(), BolusCalcDataSnapshotRequest(), TimeSinceResetRequest(),
                           ApiVersionRequest(), PumpFeaturesV1Request(), ControlIQInfoV2Request(),
                           BasalLimitSettingsRequest()] {
            sendStatusRead(r)
        }
    }

    // MARK: - CGM reading time + predictive polling

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

    /// Convert a pump-clock reading timestamp to a real `Date` via the phone↔pump anchor. Returns
    /// `nil` when the reading time is UNTRUSTWORTHY — no anchor yet, a zero pump-time, a time > 60 s in
    /// the future, or > 24 h in the past — so a bad value is represented as "unknown age" and fails
    /// closed at the shared `GlucoseFreshness` gate (never stamped as `now`, which would read as fresh).
    func cgmReadingDate(pumpSec: UInt32, now: Date) -> Date? {
        guard pumpSec > 0, let a = pumpTimeAnchor() else { return nil }
        let candidate = a.phone.addingTimeInterval(Double(Int64(pumpSec) - Int64(a.pump)))
        if candidate > now.addingTimeInterval(60) { return nil }            // future → untrusted
        if now.timeIntervalSince(candidate) > 24 * 60 * 60 { return nil }   // absurd past → untrusted
        return candidate
    }

    /// Line up a short EGV-only poll burst around the next expected reading (~5 min after this one).
    /// A newly-arrived reading reschedules this, which naturally ends the previous burst. Called from
    /// `PumpResponseApplier.applyEgvReading` when the pump's reading timestamp has ADVANCED past the
    /// last one seen.
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
        // Both sends use `CurrentEGVGuiDataRequest` (V1, op34), never the V2 request — see
        // `fastRead()`'s doc comment. `sendStatusRead` still applies the `badOpcodes` guard.
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

    /// The recurring `pollTimer` tick's body so the cadence gating is directly callable — and
    /// therefore deterministically testable via `firePollTimerTickForTesting()` — without waiting
    /// on a live 15s-repeating `Timer`.
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
        // Fresh connection cycle: drop any op77-correlation in-flight map from a prior cycle
        // (unlike the durable `badOpcodes` set, this transient map must not survive a reconnect).
        outstandingReads.removeAll()
        // Pump identity has not been re-read yet, so the identity-gated read (op20) is held
        // back until this cycle's op33 arrives (see `noteBootstrapVersionIdentified()`).
        bootstrapVersionIdentified = false
        identityGatedReadsDispatchedThisCycle = false
        // Hydrate the never-resend set from THIS pump's durable store BEFORE any read goes out,
        // so an opcode already proven unsupported is skipped from the very first `fastRead()`
        // (one-drop-ever; no re-drop after a relaunch). A union (not a replace) so an opcode
        // learned in-memory earlier this session is preserved too, and so a pump that supports
        // op20 (empty persisted set) keeps polling it. Filter so a foreign/legacy persisted
        // delivery/control-WRITE opcode can never be unioned straight into `badOpcodes` (this
        // union bypasses `insertBadOpcode`'s guard). Evaluate `loadPersistedBadOpcodes()` into a
        // local FIRST — on a firmware change its provider resets the store AND calls
        // `clearLearned(...)`, so it must not run inside the `formUnion` argument (that would be
        // a simultaneous-access-to-`badOpcodes` violation).
        let persisted = loadPersistedBadOpcodes()
        badOpcodes.formUnion(persisted.subtracting(PumpReadCatalog.deliveryControlWriteOpcodes))
        // Re-probe the dose-input reads (op108 IOB / op115 therapy) on EVERY connection cycle so
        // a single op77 that named one on a prior connection can't permanently starve the bolus
        // calculator. These are never persisted (see `insertBadOpcode`); dropping them from the
        // carried-over in-memory set makes an intra-session reconnect re-probe too.
        badOpcodes.subtract(PumpReadCatalog.doseInputReadOpcodes)
        // Same re-probe for the alert-read burst (op72-76) — never carried over as a durable skip
        // across a reconnect, so a transient op77 can't permanently silence the CGM-alert mirror.
        badOpcodes.subtract(PumpReadCatalog.alertReadOpcodes)
        // Reference-required bootstrap trio FIRST (see "MARK: - Post-pair bootstrap order" above) —
        // must be sent ahead of fastRead()/staticRead()'s other CURRENT_STATUS reads, not after.
        sendPostPairBootstrapReads()
        // Pre-version burst omits the identity-gated read (op20) — it is dispatched by
        // `runIdentityGatedReadsOnce()` once this cycle's op33 identifies the pump, so a known-bad
        // combo suppresses it before the first send. Gated fast reads go out AFTER the bootstrap
        // trio, never before.
        fastRead(includingIdentityGatedReads: false); staticRead()
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

    /// Bumped once per `startPolling()` (once per connection/pairing-selection cycle) so a
    /// `scheduleAlertRead()` callback armed by a cycle that gets superseded by a newer
    /// reconnect/re-pair before its delay elapses recognizes it's stale and no-ops.
    private var pollCycleGeneration = 0
    private var pollTimer: Timer?

    /// Send the alert reads ~1.5 s after the fast reads so they aren't in the same request burst.
    ///
    /// `pollTimer` (armed by `startPolling()`, 15s repeating) used to never be invalidated on
    /// disconnect — only at the top of the NEXT `startPolling()` call — so a timer from a cycle
    /// that dropped less than 15s after it started kept ticking through the reconnect gap and
    /// its first tick could land inside the NEXT cycle's post-pair window, calling
    /// `scheduleAlertRead()` with no staleness guard, becoming the FIRST thing sent (AlertStatus
    /// before ApiVersion). Two-part fix: `TandemBackend.linkDroppedCleanup()` now invalidates
    /// `pollTimer` the instant the link is confirmed down, and this function's deferred call
    /// captures `pollCycleGeneration` and re-checks it before running `alertRead()`.
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

    /// `TandemBackend.perform()`'s mid-bolus pause: stop the recurring timer from firing DURING
    /// delivery so its reads don't interfere, without clearing the reference — `perform`'s
    /// `defer { readScheduler.startPolling() }` always runs next (success or throw) and
    /// unconditionally replaces `pollTimer` with a fresh one, so leaving the invalidated `Timer`
    /// in place in between is harmless.
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

    /// Advance the poll-cycle generation WITHOUT arming a new cycle. Called from
    /// `TandemBackend.linkDroppedCleanup()` on every link-down/recovery path so any already-armed
    /// `scheduleAlertRead()` or a queued read from the cycle that just ended recognizes it is
    /// stale and no-ops immediately — the same generation-guard `startPolling()` relies on, but
    /// for the teardown side.
    func notePollCycleEnded() { pollCycleGeneration += 1 }

    #if DEBUG
    // MARK: - Test seams (forwarded from TandemBackend under the same names)

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

    /// Fires the REAL recurring `pollTimer` tick body (`recurringPollTick()`) directly, without
    /// waiting on the live 15s-repeating `Timer` — unlike
    /// `simulateRecurringFastAndStaticReadTickForTesting()` above (which calls `fastRead()`/`staticRead()`
    /// directly, bypassing the `%4`/`%40` cadence gating entirely). Pins alerts-every-tick /
    /// fast-on-%4 / static-on-%40 across a sequence of ticks.
    func firePollTimerTickForTesting() { recurringPollTick() }

    /// Like `startPollingForTesting()` but does NOT immediately invalidate `pollTimer` — lets a
    /// test observe that `pollTimer` is a live `Timer` right after `startPolling()` runs, then
    /// separately verify `TandemBackend.linkDroppedCleanup()` is what tears it down.
    /// `predictivePollTimer` is still stopped here.
    func startPollingLeavingPollTimerRunningForTesting() {
        startPolling()
        predictivePollTimer?.invalidate(); predictivePollTimer = nil
    }
    /// Test accessor: whether `pollTimer` currently holds a live (non-nil) `Timer`.
    var pollTimerIsActiveForTesting: Bool { pollTimer != nil }

    /// The current poll-cycle generation, so a test can assert `notePollCycleEnded()` actually
    /// advanced it — proving an armed stale `scheduleAlertRead()` would no-op after a drop.
    var pollCycleGenerationForTesting: Int { pollCycleGeneration }

    /// The predictive-burst deadline `schedulePredictiveBurst` last armed. Lets a test pin that an
    /// advancing EGV reading schedules a burst (deadline becomes non-nil) and that a later advancing
    /// reading reschedules it, with no live `Timer` fired or waited on.
    var predictiveBurstDeadlineForTesting: Date? { predictiveBurstDeadline }

    /// Run one predictive-burst kick. Lets a test prove those EGV sends honour the `badOpcodes`
    /// guard exactly like every other status read.
    func simulatePredictiveBurstForTesting() { runPredictiveBurst() }
    #endif
}
