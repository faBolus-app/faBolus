// This is a Tandem-only importer that intentionally stays in `Data/App/`, NOT in
// `Data/Tandem/` — it is dose/gate-adjacent (it unblocks the P0 delivery lock after reconnect).
import Foundation
import CoreBluetooth
import TandemMessages
import TandemAuth
import TandemBLE
import faBolusCore
import os

/// Connection/pairing-lifecycle subset, behind injected closures. Gate-adjacent: never owns the
/// auth key or the delivery lock — `TandemBackend` keeps those; this type reaches them only through
/// get/set closures. `linkDroppedCleanup()` stays on `TandemBackend`; this type only calls out to it.
/// `didReceiveFrame`'s CRC gate + `ResponseParser.parse` + HMAC handoff stay in `TandemBackend`.
@MainActor
final class PumpConnectionLifecycle {

    // MARK: - Injected seams (settable post-construction)

    /// Bound to a closure that mutates `TandemBackend.snapshot` in place (its setter is `private(set)`) —
    /// same shape as `PumpHistorySyncCoordinator.withSnapshot`.
    var withSnapshot: ((inout PumpSnapshot) -> Void) -> Void = { _ in }
    /// Computed proxy — NEVER stores a snapshot copy itself. Every `snapshot.foo = bar` / `snapshot.foo`
    /// read in the moved bodies below round-trips through `withSnapshot`, so `TandemBackend`'s
    /// `private(set)` snapshot stays the single source of truth.
    private var snapshot: PumpSnapshot {
        get {
            var value = PumpSnapshot()
            withSnapshot { value = $0 }
            return value
        }
        set {
            withSnapshot { $0 = newValue }
        }
    }

    /// Bound to `{ [weak self] in self?.onChange?() }`.
    var onChange: (() -> Void)?

    /// Shared refs: `TandemBackend`'s own `readScheduler`/`bgSession` instances, passed
    /// through directly rather than wrapped in per-method closures — both are already independent,
    /// injected-seam collaborators, so holding a direct reference here is no different from
    /// `TandemBackend` holding one. Defaults are inert placeholders, overwritten by the real instances in
    /// `TandemBackend.wireConnectionLifecycle()`.
    var readScheduler = PumpReadScheduler()
    var bgSession = PumpBackgroundSession()
    /// The raw kit client, for the two BLE calls the pairing-watchdog quartet issues
    /// (`connectKnownPeripheral`/`startScan`/`disconnect`). Optional (unlike `readScheduler`/`bgSession`)
    /// because `PumpBLEClient` has no cheap inert default; `TandemBackend` wires the real one.
    var client: PumpBLEClient?

    /// Bound to `{ [weak self] in self?.linkDroppedCleanup() }` — calls back into the shared teardown
    /// spine, which STAYS a single ordered method on `TandemBackend` (review concern #5). This type never
    /// re-implements or reorders it.
    var linkDroppedCleanup: () -> Void = {}

    var getPairingCode: () -> String = { "" }
    var setPairingCode: (String) -> Void = { _ in }
    /// Computed proxy onto `TandemBackend.pairingCode` (a `public` property set by the pairing UI before
    /// `connect()`) — never stored here.
    private var pairingCode: String {
        get { getPairingCode() }
        set { setPairingCode(newValue) }
    }

    var getAuthenticationKey: () -> [UInt8] = { [] }
    var setAuthenticationKey: ([UInt8]) -> Void = { _ in }
    /// Computed proxy onto `TandemBackend.authenticationKey` — the auth key is NEVER stored in this
    /// type; every read/write here round-trips through the injected closures.
    private var authenticationKey: [UInt8] {
        get { getAuthenticationKey() }
        set { setAuthenticationKey(newValue) }
    }
    /// Verbatim copy of `TandemBackend.isPaired`'s own definition, computed off the proxied key.
    private var isPaired: Bool { !authenticationKey.isEmpty }

    var getCoordinator: () -> (any PairingCoordinating)? = { nil }
    var setCoordinator: ((any PairingCoordinating)?) -> Void = { _ in }
    /// Computed proxy onto `TandemBackend.coordinator` — the delivery-adjacent pairing coordinator is
    /// NEVER stored in this type.
    private var coordinator: (any PairingCoordinating)? {
        get { getCoordinator() }
        set { setCoordinator(newValue) }
    }

    var getDetectedIsMobi: () -> Bool? = { nil }
    var setDetectedIsMobi: (Bool?) -> Void = { _ in }
    /// Computed proxy onto `TandemBackend.detectedIsMobi`.
    private var detectedIsMobi: Bool? {
        get { getDetectedIsMobi() }
        set { setDetectedIsMobi(newValue) }
    }

    /// Bound to `{ [weak self] in await self?.reconcileIndeterminateDelivery() }` — fired once
    /// from `onPaired`, result discarded, exactly as the pre-move `Task { … }` did.
    var reconcileIndeterminateDelivery: () async -> Void = {}
    /// Bound to `{ [weak self] event in self?.onReliabilityEvent?(event) }`.
    var onReliabilityEvent: ((ReliabilityEvent) -> Void)?
    /// Test seam forwarded from `TandemBackend.onPairingSendForTesting` — fires with the same non-PHI
    /// facts (type name / opcode / cargo byte COUNT) the pairing send site always logged.
    var onPairingSendForTesting: ((_ typeName: String, _ opcode: UInt8, _ cargoBytes: Int) -> Void)?

    /// Seam replacing a direct `Timer` inside this type (no wall-clock here): schedule a one-shot
    /// callback `seconds` from now, returning an opaque cancellable token. Production wiring
    /// (`TandemBackend.wireConnectionLifecycle()`) binds this to a real `Timer.scheduledTimer`, byte-
    /// identical to the pre-move dispatch (`MainActor.assumeIsolated` + the same fire callback).
    var scheduleWatchdog: (TimeInterval, @escaping @MainActor () -> Void) -> Any? = { _, _ in nil }
    /// Cancel a token returned by `scheduleWatchdog` (production: `(token as? Timer)?.invalidate()`).
    var cancelWatchdog: (Any?) -> Void = { _ in }

    /// Same subsystem/category as `TandemBackend.pairingLog` — declared separately (that constant is
    /// `private` to that file) — mirrors `PumpReadScheduler.pairingLog`'s own precedent for this exact
    /// reason.
    private static let pairingLog = Logger(subsystem: "com.fabolus.app", category: "ble")

    // MARK: - Resume-retry budget (sole store here)

    private var resumeRetryCount = 0
    private static let maxResumeRetries = 2
    /// Which reconnect action `handleResumeFailure()`'s retry branch invoked —
    /// `.reestablish` (`connectKnownPeripheral`) or `.disconnect` (the pre-fix bug that killed
    /// the kit's reconnect ladder). Forwarded by `TandemBackend.resumeRetryActionForTesting`.
    enum ResumeRetryAction: Equatable { case reestablish, disconnect }
    private(set) var resumeRetryActionForTesting: ResumeRetryAction?
    /// Forwarded by `TandemBackend.resumeRetryCountForTesting`.
    var resumeRetryCountForTesting: Int { resumeRetryCount }

    // MARK: - Pairing-handshake watchdog (Timer replaced by scheduleWatchdog/cancelWatchdog)

    private var pairingWatchdogToken: Any?
    private var pairingWatchdogClearStore = false
    private static let defaultPairingTimeoutSec: Double = 30
    /// Test seam: override the pairing-handshake watchdog deadline. Forwarded by
    /// `TandemBackend.pairingTimeoutSecForTesting`.
    var pairingTimeoutSecForTesting: Double?
    private var pairingTimeoutSec: Double {
        #if DEBUG
        if let override = pairingTimeoutSecForTesting { return override }
        #endif
        return Self.defaultPairingTimeoutSec
    }

    // MARK: - applyClientState / linkDetail

    /// Fold a kit BLE state into the snapshot.
    func applyClientState(_ state: PumpBLEClient.State) {
        switch state {
        case .scanning:
            snapshot.connection = .scanning
            snapshot.connectionDetail = nil
        case .connecting, .discovering:
            // An unintended BLE drop often surfaces HERE as `.connecting` (the kit skips the
            // `.disconnected` flicker and goes straight to reconnecting), so `linkDroppedCleanup()`
            // — which otherwise runs only from the `.disconnected…`/`.reconnectExhausted` cases —
            // never fires across the reconnect gap. If the link was PREVIOUSLY live, run the shared
            // teardown so the cycle-N `pollTimer`, an armed `scheduleAlertRead`, and the prior
            // `coordinator`/`authenticationKey` don't survive into the gap and inject stale reads /
            // a signed read into the pre-auth window before `pumpClientDidBecomeReady` rebuilds
            // them. Guard on the PRE-transition state so a normal first-connect `.scanning →
            // .connecting` climb is untouched. Keep `.connecting` (not `.disconnected`) so the
            // reconnect-window semantics pinned by `TandemConnectionStateTests` are preserved.
            let wasLive = snapshot.connection == .connected || snapshot.connection == .bolusing
            snapshot.connection = .connecting
            snapshot.connectionDetail = nil
            if wasLive { linkDroppedCleanup() }
            // A live-link → `.connecting` transition IS one re-pair/re-drop flap cycle — exactly
            // the edge `SafetyEdge.connection` folds to `.none`. Count them; when a storm crosses
            // the threshold within the window, emit the typed `.connectionUnstable` edge so
            // `AppModel` raises the non-muteable "can't hold a connection" alert. Observed HERE
            // (every kit transition), not in the sampled `refresh()` tick, so a fast ~2 s cycle
            // is never missed.
            if wasLive, flapDetector.recordFlap(at: Date()) {
                onReliabilityEvent?(.connectionUnstable)
            }
            // This is the SINGLE hook that covers all THREE `didDiscover`-bypass
            // reconnect shapes (silent retrieve, CoreBluetooth state restoration, watchdog-rescan-direct-
            // connect — 15.5-RESEARCH.md §A2) — `state` transitions to `.connecting`/`.discovering`
            // synchronously on every one of them (`PumpBLEClient.connect(_:)`/`willRestoreState`), so a
            // trusted identity persisted at a PRIOR discovery can be reapplied here before the earliest
            // possible send, without the kit needing any new delegate method. Unconditional (not gated on
            // `wasLive`): a restoration silent reconnect can arrive with `wasLive == false`.
            reapplyTrustedIdentityIfKnown()
        case .ready:
            // Transport-ready ≠ application-usable. The kit's `.ready` only means the BLE link is
            // up; pairing (`onPaired` → `authenticationKey`) has NOT completed yet and polling has
            // not started. Publish `.connecting` (the not-usable intermediate the UI/gate already
            // treat as unusable — `isLinked == .connected || .bolusing`), NOT `.connected`. The
            // application-usable `.connected` state is published at the single "we are now polling"
            // moment via `markUsableAndStartPolling()`. This closes the ghost-"Connected" window
            // where a lost handshake frame or a thrown pairing write would otherwise pin a green
            // HUD that never polls and never escalates staleness.
            snapshot.connection = .connecting
            snapshot.connectionDetail = nil
            bgSession.linkDidBecomeReady()  // reconnect recovered → release the H1 window
        case .disconnected, .idle, .poweredOff, .unauthorized, .unsupported, .resetting:
            snapshot.connection = .disconnected
            snapshot.connectionDetail = Self.linkDetail(for: state)
            linkDroppedCleanup()
            bgSession.linkDidTerminate()  // link down & NOT retrying → release the H1 window
        case .reconnectExhausted:
            // The kit's reconnect ladder gave up (`maxReconnectAttempts` consecutive cycles that
            // never held `.ready` long enough to count as recovered — see
            // `PumpBLEClient.readyStabilityWindow`). Real-pump-confirmed: `CBErrorDomain` code 7 —
            // the #1 known cause is the official t:connect app still holding the pump
            // (one-connection-at-a-time). `.error` (not `.disconnected`) so this doesn't read as a
            // plain, retryable drop — automatic retry has actually stopped.
            snapshot.connection = .error
            snapshot.connectionDetail =
                "Pairing keeps dropping — close t:connect if it's open (only one app can connect to the pump at a time), then try again."
            linkDroppedCleanup()
            bgSession.linkDidTerminate()  // ladder gave up → release the H1 window
        default:
            // `.unknown` (startup) or any future kit state: fail the DISPLAY safe to disconnected — never
            // leave a stale connected/linked state showing. (Was `default: break`.) Reachable via
            // `.unknown`, so no frozen-enum exhaustiveness warning on this external-module enum.
            snapshot.connection = .disconnected
            snapshot.connectionDetail = nil
        }
    }

    /// Reapply a peripheral's persisted TRUSTED identity into the kit on every reconnect shape
    /// that bypasses `didDiscover`, before the earliest possible send.
    ///
    /// Reads `TrustedPumpIdentityStore` (NOT `PumpModelStore`, NOT the op33 heuristic) — the only
    /// writer of that store is a genuine BLE-name detection (`applyDidDiscover` below).
    ///
    /// Guard chain, in order: (1) `PumpPeripheralStore.id()` must be present; (2) the kit's own
    /// `client.reconnectTargetId` must be present AND equal to it — else the kit is actually
    /// driving a DIFFERENT peripheral (pump-swap-mid-reconnect, or a restoration that adopted a
    /// different peripheral) and a stale trusted record for the wrong peripheral must never be
    /// applied; (3) a persisted trusted record must exist for that peripheral — else there is
    /// nothing to reapply (a genuinely never-discovered-by-name pump).
    ///
    /// For the matching peripheral only:
    ///   (a) restore `detectedIsMobi` from the persisted (name-derived) value. Without this, op33
    ///       arriving LATER the same reconnect cycle recomputes `nameTrusted =
    ///       (detectedIsMobi() != nil) == false` and CLOBBERS the trust this method just stamped
    ///       back to `false`, permanently over-gating a legitimate Mobi's Suspend/Resume/SetTempRate/
    ///       Modes/IDP/Fill after every silent reconnect. Restoring `detectedIsMobi` here means
    ///       op33 later this cycle sees a non-nil name-authority value, computes
    ///       `nameTrusted == true`, and forwards `trusted: true` — no clobber, AND op33's own
    ///       `if detectedIsMobi() == nil` heuristic-overwrite block is skipped.
    ///   (b) call `client.setDeviceContext(model:, apiVersion: nil, trusted: true)` — apiVersion
    ///       stays nil (MODEL dimension only).
    private func reapplyTrustedIdentityIfKnown() {
        guard let storeId = PumpPeripheralStore.id() else { return }
        // The kit must actually be (re)connecting THIS peripheral — a stale trusted record
        // for a different one (pump-swap-mid-reconnect, or a restoration adopting a different
        // peripheral) must never be inherited by the current session.
        //
        // The `reconnectTargetId == nil` "unknown target" case is a plain no-op (nothing to reapply,
        // nothing to clear — this is e.g. the very first connection this launch, where a value already
        // set at a live `didDiscover` this same session must be left intact).
        guard let target = client?.reconnectTargetId else { return }
        // A GENUINE peripheral mismatch (`target != storeId`, not merely
        // "unknown") — the kit is driving a DIFFERENT peripheral than the stored one. Defensively
        // clear `detectedIsMobi` before returning so a future `applyDeviceContext` can never inherit a
        // stale name-authority value for the WRONG peripheral, even if some other invariant across the
        // reconnect state machine regresses. This makes the function self-defensive rather than
        // relying solely on the cross-file `linkDroppedCleanup()`/`forgetPairing()` nil-ing convention.
        guard target == storeId else {
            detectedIsMobi = nil
            return
        }
        guard let isMobi = TrustedPumpIdentityStore.isMobi(for: storeId) else { return }
        detectedIsMobi = isMobi  // restore the app-side name-authority signal
        // Also restore the PUBLISHED model fields `applyDidDiscover` sets, not only the private
        // `detectedIsMobi` above. On a `didDiscover`-bypass fast-path reconnect (cold launch →
        // `connectKnownPeripheral`) the snapshot starts empty (`pumpModelName == ""` ⇒
        // `pumpModel == .unknown`) and `didDiscover` never runs to fill it. op33 then SKIPS its
        // own `snapshot.pumpModelName` assignment because it is guarded by
        // `if detectedIsMobi() == nil` and the line above just made that non-nil — so without
        // restoring the snapshot HERE, `pumpModel` stays `.unknown` and `validateDeliver`'s family
        // gate (`snapshot.pumpModel == .tslimX2`) refuses a genuine t:slim with the
        // Mobi-not-supported copy. This mirrors `applyDidDiscover` exactly (same trusted,
        // name-derived source), so a Mobi still resolves to `.mobi` (and the MOBI-03 backstop
        // still tears it down) — no reclassification.
        snapshot.isMobi = isMobi
        snapshot.pumpModelName = isMobi ? "Mobi" : "t:slim X2"
        client?.setDeviceContext(model: isMobi ? .mobi : .tslim, apiVersion: nil, trusted: true)
    }

    /// A short human explanation for a specific down state; nil for the benign/transitional ones where
    /// the "Disconnected" label already says enough (plain disconnect, idle-but-powered-on).
    private static func linkDetail(for state: PumpBLEClient.State) -> String? {
        switch state {
        case .poweredOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth permission denied — enable it in Settings"
        case .unsupported: return "Bluetooth unavailable on this device"
        case .resetting: return "Bluetooth is resetting…"
        default: return nil
        }
    }

    /// Publish the application-usable `.connected` state and start polling at the SINGLE "we are
    /// now polling" moment. Every terminal site in `pumpClientDidBecomeReady` that used to call
    /// `readScheduler.startPolling()` directly now routes through here, so `.connected` is published
    /// exactly when polling begins — never at bare BLE `.ready` (which now maps to `.connecting`).
    private func markUsableAndStartPolling() {
        snapshot.connection = .connected
        // Deliberately NO `flapDetector.reset()` here. A reconnect is the SECOND HALF of every flap
        // cycle, so clearing the window at this exact point put exactly one clear between any two
        // `recordFlap` calls, pinned `flapTimes.count` at 1 against a `threshold` of 5, and made
        // escalation unreachable — this detector shipped inert (`2443fd6`) for precisely that reason.
        // A genuine recovery now needs no call at all: the window, and with it the `escalated` latch,
        // decays by AGE inside `recordFlap`, so the arithmetic cannot be defeated by what this path
        // does or forgets to do. The user-visible alert is still withdrawn on the `.clear` connection
        // edge in `RefreshEffectsCoordinator` (verified: it withdraws `pumpConnectionUnstableKey`
        // alongside `pumpDisconnectKey`) — see the KNOWN LIMITATION on that withdraw in the
        // `pump-link-thrash-190-connects` debug session.
        onChange?()
        readScheduler.startPolling()
    }

    /// Counts live→`.connecting` re-pair/re-drop flap cycles (fed from `applyClientState`) and
    /// escalates ONCE per storm past the threshold within the window. NOT reset on reconnect (that is
    /// the second half of a flap cycle and clearing it there is what shipped this inert); the window
    /// self-decays by age. Force-cleared only on a pump IDENTITY change, in `applyDidDiscover`.
    private var flapDetector = ConnectionFlapDetector()

    // MARK: - Pairing-handshake watchdog
    //
    // `PairingCoordinator`/`LegacyPairingCoordinator` (external kit) have NO deadline, and the
    // `onSendRequest` catch-and-log means a lost reply / thrown write never calls `fail`/`onError`. Without
    // a watchdog, `step` can stick in a `sentN` state forever with the link up: `onPaired`/`onError` never
    // fire, polling never starts, and no staleness/disconnect escalation runs. This watchdog fails closed
    // after `pairingTimeoutSec` if pairing hasn't completed. Armed at `coord.start()`; cancelled in
    // `onPaired`, `onError`, and `linkDroppedCleanup()` (via the `cancelPairingWatchdog()` sink call at its
    // last step — the shared teardown spine itself stays on `TandemBackend`, review concern #5).

    private func armPairingWatchdog(clearStoreOnTimeout: Bool) {
        cancelWatchdog(pairingWatchdogToken)
        pairingWatchdogClearStore = clearStoreOnTimeout
        pairingWatchdogToken = scheduleWatchdog(pairingTimeoutSec) { [weak self] in self?.firePairingWatchdog() }
    }

    func cancelPairingWatchdog() {
        cancelWatchdog(pairingWatchdogToken)
        pairingWatchdogToken = nil
    }

    /// A quick-pair RESUME failed (a handshake `onError` or a watchdog timeout on the resume path).
    /// NEVER auto-wipe the stored secret — a transient link glitch must not force a full manual re-pair.
    /// Retry the resume (bounded, on the live link); when the budget is exhausted, surface a RETRYABLE
    /// error that KEEPS the derived secret. Only an explicit `forgetPairing()` wipes it. Factored so
    /// both the `onError` resume branch and `firePairingWatchdog`'s resume branch share one policy.
    ///
    /// The retry branch re-establishes via `client.connectKnownPeripheral` (never `client.disconnect()`,
    /// which would kill the kit's reconnect ladder).
    private func handleResumeFailure() {
        coordinator = nil
        if resumeRetryCount < Self.maxResumeRetries {
            resumeRetryCount += 1
            Self.pairingLog.log(
                "pairing resume retry \(self.resumeRetryCount, privacy: .public)/\(Self.maxResumeRetries, privacy: .public) — keeping stored secret"
            )
            linkDroppedCleanup()  // drops the auth key (delivery gate fails closed), stops timers
            #if DEBUG
            resumeRetryActionForTesting = .reestablish
            #endif
            // Re-establish, NEVER disconnect() — see the doc comment above. Mirrors `connect()`'s
            // cold-launch fast path: re-adopt the known peripheral id directly; fall back to a scan
            // if the id isn't known yet (shouldn't normally happen mid-resume, but fails safe).
            if let id = PumpPeripheralStore.id() {
                client?.connectKnownPeripheral(identifier: id)
            } else {
                client?.startScan()
            }
            // This path dies from `.connecting` — `SafetyEdge.connection` never raises here (it only
            // fires on a direct `.connected/.bolusing → down` edge) — so alarm explicitly via the typed
            // event AppModel translates into the never-suppressible `.pumpDisconnect` post + escalation.
            onReliabilityEvent?(.resumeRetryFailed)
        } else {
            Self.pairingLog.log("pairing resume retries exhausted — retryable error, secret RETAINED")
            resumeRetryCount = 0
            linkDroppedCleanup()
            snapshot.connection = .error
            snapshot.connectionDetail =
                "Couldn’t reconnect securely. Tap to retry — or Forget Pairing in Settings to re-pair."
            onChange?()
        }
    }

    private func firePairingWatchdog() {
        cancelPairingWatchdog()
        // If pairing actually completed, do nothing (defensive — `onPaired` already cancels the watchdog).
        guard !isPaired else { return }
        Self.pairingLog.log("pairing outcome → watchdog timeout (fail-closed)")
        // A RESUME timeout (saved material, pairingWatchdogClearStore == true) must NEVER auto-wipe
        // the stored secret — route to the SAME bounded-retry / retryable-keep-secret path as
        // `onError`. A FRESH full-pair timeout keeps its existing fail-closed behavior (it never
        // had a stored secret to protect).
        if pairingWatchdogClearStore {
            handleResumeFailure()
        } else {
            coordinator = nil
            linkDroppedCleanup()
            client?.disconnect()  // re-enter the kit's bounded reconnect ladder
            snapshot.connection = .error
            snapshot.connectionDetail =
                "Pairing didn’t finish — close t:connect if it’s open (only one app can connect to the pump at a time), then try again."
            onChange?()
        }
    }

    /// Test seam: fire the armed pairing-handshake watchdog synchronously. Forwarded by
    /// `TandemBackend.firePairingWatchdogForTesting()`.
    func firePairingWatchdogForTesting() { firePairingWatchdog() }

    // MARK: - didDiscover model detection (moved off TandemBackend)

    /// Model detection from the BLE advertised name at discovery, plus the device-context wire and
    /// the connect-forward. Renamed from the raw delegate method (`pumpClient(_:didDiscover:rssi:)` stays
    /// a thin forwarder on `TandemBackend`) since this type doesn't itself conform to
    /// `PumpBLEClientDelegate`.
    func applyDidDiscover(_ c: PumpBLEClient, peripheral: CBPeripheral, rssi: Int) {
        // Only act on a discovery while we are actually scanning. A late `didDiscover` that lands
        // after the user cancelled (snapshot moved off `.scanning`) must not auto-connect. The kit
        // already rejects late discoveries at the source (intentionalDisconnect + stopScan on
        // cancel); this ensures the app never auto-connects a stray discovery either.
        guard snapshot.connection == .scanning else { return }
        // Authoritative model detection from the BLE advertised name: the Mobi advertises with
        // "Mobi" in its name; anything else Tandem is a t:slim X2. This directly names the model,
        // unlike the API version (a current t:slim X2 can report API >= 3.5, which would falsely
        // read as Mobi). ApiVersionResponse is only a fallback when the name doesn't identify it.
        if let name = peripheral.name, !name.isEmpty {
            let isMobi = name.localizedCaseInsensitiveContains("mobi")
            detectedIsMobi = isMobi
            snapshot.isMobi = isMobi
            snapshot.pumpModelName = isMobi ? "Mobi" : "t:slim X2"
            PumpModelStore.set(isMobi: isMobi)
            // Persist this as the peripheral's TRUSTED identity — the ONLY writer
            // of TrustedPumpIdentityStore — so `reapplyTrustedIdentityIfKnown()` can re-establish it on a
            // future silent reconnect/restoration that bypasses this delegate callback.
            TrustedPumpIdentityStore.set(isMobi: isMobi, for: peripheral.identifier)
            // Wire the identified MODEL into the kit's device-support send gate (a live second layer
            // that agrees with PumpCapabilities — t:slim never offers the [.mobi] control ops, so
            // this only ever fires on an isMobi-misdetection). apiVersion stays nil → API dimension
            // stays fail-open. trusted: true — BLE-name detection is the authoritative, TRUSTED source.
            c.setDeviceContext(model: isMobi ? .mobi : .tslim, apiVersion: nil, trusted: true)
        }
        // A DIFFERENT physical pump: abandon the previous link's flap history outright rather than
        // letting it decay, so pump B is never escalated for pump A's instability (four stale flaps from
        // the old pump plus one from the new one would otherwise cross the threshold and blame the wrong
        // pump — a false "can't hold a connection" alert on a healthy pump). An identity change, NOT a
        // recovery, is the one place the unconditional `reset()` is correct. Safe here: this delegate is
        // guarded on `snapshot.connection == .scanning` above, so it cannot run mid-storm against the
        // pump currently being measured.
        if let previous = PumpPeripheralStore.id(), previous != peripheral.identifier {
            flapDetector.reset()
        }
        // C1: remember this peripheral so a future cold launch can retrieve-before-scan (see connect()).
        // The scan is service-UUID-filtered to the pump, so the discovered peripheral IS the pump.
        PumpPeripheralStore.set(peripheral.identifier)
        c.connect(peripheral)
    }

    // MARK: - pumpClientDidBecomeReady pairing-scheme SELECTION (moved off TandemBackend)

    /// Renamed-free move: kept as `pumpClientDidBecomeReady(_:)` (no rename needed — this type doesn't
    /// itself conform to `PumpBLEClientDelegate`, so there's no naming clash to avoid). `TandemBackend`'s
    /// own `public func pumpClientDidBecomeReady(_ c: PumpBLEClient)` is now a thin forwarder to this.
    func pumpClientDidBecomeReady(_ c: PumpBLEClient) {
        // Pick the pairing SCHEME automatically from the code the user entered (JPAKE 6-digit vs
        // legacy V1 16-char), or resume/re-challenge from saved material. `onFirstPair` is non-nil
        // ONLY for a fresh full pair — it persists the material for silent reconnects; when it is
        // nil we used saved material, so an error there means "forget it and re-pair".
        let coord: any PairingCoordinating
        let onFirstPair: (() -> Void)?
        // A fixed scheme-name token for `pairingLog`, never the code/secret itself. Logged once the
        // scheme is settled, below.
        let schemeName: String

        if !pairingCode.isEmpty {
            let code = pairingCode
            switch PairingAuth.detectType(code) {
            case .short6Char:  // modern EC-JPAKE, resumable
                guard let full = try? PairingCoordinator(pairingCode: code) else {
                    markUsableAndStartPolling()
                    return
                }
                coord = full
                schemeName = "JPAKE (fresh)"
                onFirstPair = { [weak self] in
                    PairingStore.save(full.derivedSecret)
                    self?.pairingCode = ""
                }
            case .long16Char:  // legacy V1 — no resume, persist the code
                guard let v1 = try? LegacyPairingCoordinator(pairingCode: code) else {
                    markUsableAndStartPolling()
                    return
                }
                coord = v1
                schemeName = "V1/legacy (fresh)"
                onFirstPair = { [weak self] in
                    PairingStore.saveV1Code(code)
                    self?.pairingCode = ""
                }
            }
        } else if let v1Code = PairingStore.loadV1Code() {  // legacy reconnect: silent full re-challenge
            guard let v1 = try? LegacyPairingCoordinator(pairingCode: v1Code) else {
                PairingStore.clear()
                markUsableAndStartPolling()
                return
            }
            coord = v1
            onFirstPair = nil
            schemeName = "V1/legacy (resume re-challenge)"
        } else if let stored = PairingStore.load() {  // modern reconnect: JPAKE quick-pair resume
            coord = PairingCoordinator(resumeDerivedSecret: stored)
            onFirstPair = nil
            schemeName = "JPAKE (quick-pair resume)"
        } else {
            markUsableAndStartPolling()
            return  // no code and no saved pairing — reads will be rejected
        }
        Self.pairingLog.log("pairing scheme selected → \(schemeName, privacy: .public)")

        coord.onSendRequest = { [weak self] msg in  // AUTHORIZATION passes the interlock
            // Logs type name + opcode + CARGO byte count (payload only, before framing/CRC/HMAC —
            // recomputing the actual wire length would need a second, duplicate `Packetize` call with
            // its own txId, out of step with the one `send()` actually uses) + send outcome. Never logs
            // `msg.cargo` itself (that's where `centralChallenge` / `pumpChallengeHash` / JPAKE round
            // payloads live).
            let typeName = String(describing: type(of: msg))
            let opcode = msg.opCode
            let cargoBytes = msg.cargo.count
            do {
                try c.send(msg)
                Self.pairingLog.log(
                    """
                    pairing send → \(typeName, privacy: .public) opcode=\(opcode, privacy: .public) \
                    cargoBytes=\(cargoBytes, privacy: .public) result=sent
                    """)
            } catch {
                Self.pairingLog.log(
                    """
                    pairing send → \(typeName, privacy: .public) opcode=\(opcode, privacy: .public) \
                    cargoBytes=\(cargoBytes, privacy: .public) result=threw
                    """)
            }
            #if DEBUG
            self?.onPairingSendForTesting?(typeName, opcode, cargoBytes)
            #endif
        }
        coord.onError = { [weak self] _ in
            guard let self else { return }
            Self.pairingLog.log("pairing outcome → error")
            self.cancelPairingWatchdog()  // pairing resolved (error) — disarm the watchdog
            if onFirstPair == nil {
                // A quick-pair RESUME failed. NEVER auto-wipe the stored secret — a transient link
                // glitch must not force a full manual re-pair. Retry the resume (bounded, on the live
                // link); when exhausted, surface a RETRYABLE error that KEEPS the derived secret.
                // Only an explicit forgetPairing() wipes it.
                self.handleResumeFailure()
            } else {
                // A FRESH full pair failed — no stored secret to protect; keep the prior behavior.
                self.snapshot.connection = .error
                self.onChange?()
            }
        }
        coord.onPaired = { [weak self] key, _ in
            Self.pairingLog.log("pairing outcome → paired")
            self?.cancelPairingWatchdog()  // pairing resolved (success) — disarm the watchdog
            self?.resumeRetryCount = 0  // a successful pair clears the resume-retry budget
            self?.authenticationKey = key
            onFirstPair?()  // first full pair: persist the derived secret (JPAKE) or the code (V1)
            self?.markUsableAndStartPolling()  // publish `.connected` + start polling at the single usable moment
            // If a prior bolus outcome was left unknown (e.g. we reconnected after a mid-bolus
            // drop), reconcile it against the pump now so new deliveries can unblock.
            Task { [weak self] in await self?.reconcileIndeterminateDelivery() }
        }
        coordinator = coord
        // Arm the pairing-handshake watchdog when the handshake starts, so a lost reply /
        // thrown write can't pin a ghost link forever. `clearStoreOnTimeout` mirrors `onError`'s policy.
        armPairingWatchdog(clearStoreOnTimeout: onFirstPair == nil)
        coord.start()
    }
}
