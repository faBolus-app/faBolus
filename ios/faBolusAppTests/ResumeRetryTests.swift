import Testing
import Foundation
import TandemBLE
import faBolusCore
@testable import faBolus

/// R2-07 (fix commit fb11208) — quick-pair RESUME failures RETRY on a bounded budget and NEVER auto-wipe
/// the stored pairing secret; only an explicit `forgetPairing()` (R2-06) wipes it.
///
/// Before the fix, a quick-pair RESUME failure — a handshake `onError`, or a resume-path watchdog timeout
/// (`pumpClientDidBecomeReady`'s `onFirstPair == nil` branch, built from `PairingStore.load()`) — called
/// `PairingStore.clear()` straight away, forcing a full manual re-pair after a single transient link glitch.
/// The fix routes BOTH the shared `coord.onError` resume branch AND `firePairingWatchdog`'s resume branch
/// (`pairingWatchdogClearStore == true`) through one policy, `handleResumeFailure()`:
///   • it NEVER calls `PairingStore.clear()`;
///   • while `resumeRetryCount < maxResumeRetries` (2) it increments the budget, runs `linkDroppedCleanup()`
///     + `client.disconnect()` (a bounded retry that re-enters the reconnect ladder) — no `.error`;
///   • once the budget is EXHAUSTED it resets `resumeRetryCount = 0`, runs `linkDroppedCleanup()`, and
///     publishes a RETRYABLE `.error` ("…Tap to retry — or Forget Pairing…") while KEEPING the stored secret.
/// A FRESH full pair failure (`onFirstPair != nil`) is UNCHANGED — straight to `.error`, no resume-retry
/// budget (it never had a stored secret to protect). `onPaired` resets the budget on success.
///
/// HARNESS (mirrors `PairingWatchdogTests` / `ForgetPairingTeardownTests` exactly): the resume failure is
/// injected via the existing `firePairingWatchdogForTesting()` seam. `beginPairingForTesting(code: "")` with
/// a seeded `PairingStore` secret drives the REAL `pumpClientDidBecomeReady` quick-pair RESUME branch
/// (`onFirstPair == nil`), which arms the watchdog with `clearStoreOnTimeout: true` (→ the resume branch of
/// `firePairingWatchdog`). Starting UNPAIRED (`authKey: []`) keeps `firePairingWatchdog`'s `guard !isPaired`
/// from short-circuiting — exactly as `PairingWatchdogTests.watchdogTimeoutFailsClosedWhenTheHandshakeNeverResolves`
/// does. The `PairingCoordinator(resumeDerivedSecret:)` `start()` is non-throwing (it emits round-3 and the
/// send throws `.notReady`, caught) so it does NOT synchronously consume a retry before the watchdog fires.
///
/// A genuine cryptographic `onPaired` cannot be synthesized in a unit test (see `PairingWatchdogTests`'
/// header — the JPAKE/V1 coordinators need valid AUTHORIZATION frames the test target can't build), so the
/// "successful pair resets the budget" property is not directly drivable; the equivalent budget reset that IS
/// reachable — the exhaustion branch's `resumeRetryCount = 0` — is pinned in `exhaustedResumeRetry…` below.
@Suite(.serialized) @MainActor
struct ResumeRetryTests {
    /// Arbitrary quick-pair derived-secret bytes — `PairingCoordinator(resumeDerivedSecret:)` accepts any
    /// bytes (the resume failure is driven by the watchdog, not by the secret's validity). Mirrors
    /// `PrivacyDataTests`' `PairingStore.save([9, 9, 9])`.
    private static let storedSecret: [UInt8] = [9, 9, 9]

    /// Start UNPAIRED (`authKey: []`) so `firePairingWatchdog`'s `guard !isPaired` doesn't short-circuit the
    /// very resume-failure path under test — the default double is pre-paired.
    private func resumingBackend() -> TandemBackend {
        let b = TandemBackend(testTransport: FakePumpTransport(), authKey: [])
        b.pairingTimeoutSecForTesting = 0.05   // fired manually below — never waits out the real 30 s deadline
        return b
    }

    /// 1 — Budget remaining: a quick-pair RESUME failure with a stored secret RETRIES — it consumes one unit
    /// of the retry budget, keeps the stored secret, and does NOT surface a terminal error. This is the core
    /// R2-07 guarantee that a single transient link glitch no longer forces a full manual re-pair.
    @Test func resumeFailureWithStoredSecretRetriesAndNeverWipesTheStore() {
        // R2-07: the xctest host has no functional Keychain, so the quick-pair RESUME path (gated on
        // `PairingStore.load()`) is only drivable with the in-memory seam. Scoped per-test + reset in a
        // defer so it never leaks to other suites (e.g. PrivacyDataTests relies on the no-op Keychain).
        PairingStore.useInMemoryBackingForTests = true
        defer { PairingStore.useInMemoryBackingForTests = false }
        PairingStore.clear()
        defer { PairingStore.clear() }
        PairingStore.save(Self.storedSecret)   // a modern JPAKE quick-pair resume secret

        let b = resumingBackend()
        #expect(!b.isPairedForTesting, "precondition: unpaired, so the watchdog's guard !isPaired won't short-circuit")
        b.beginPairingForTesting(code: "")   // "" + stored secret → quick-pair RESUME (onFirstPair == nil)
        #expect(b.pairingCoordinatorIsLiveForTesting, "precondition: the resume handshake is armed")
        #expect(b.resumeRetryCountForTesting == 0, "precondition: a fresh retry budget")

        b.firePairingWatchdogForTesting()   // resume-path timeout → handleResumeFailure(), budget remaining

        // Took the bounded-RETRY branch, not the error branch: the budget advanced (0 → 1).
        #expect(b.resumeRetryCountForTesting == 1, "a resume failure with budget remaining must retry, not error")
        // The retry branch re-enters the reconnect ladder without publishing a terminal error (it leaves the
        // pre-existing reconnecting posture in place) — it must NOT go straight to a terminal wiped state.
        #expect(b.snapshot.connection != .error, "must not surface a terminal error while the retry budget remains")
        // The safety-critical invariant: the stored secret survives a resume-failure retry, byte-for-byte.
        #expect(PairingStore.load() == Self.storedSecret, "the stored secret must survive a resume retry — never auto-wiped")
        #expect(PairingStore.hasAnyPairing, "hasStoredPairing stays true across a resume retry")
    }

    /// 2 — Budget exhausted: after `maxResumeRetries` (2) failures the third surfaces a RETRYABLE `.error`
    /// whose detail offers "Tap to retry"/"Forget Pairing" — and the stored secret is STILL retained, never
    /// auto-wiped. The budget resets to 0 on exhaustion so the next reconnect gets a fresh full retry budget
    /// (the reachable analogue of `onPaired`'s success-reset, which a unit test can't synthesize).
    @Test func exhaustedResumeRetryBudgetSurfacesRetryableErrorAndRetainsTheSecret() {
        // R2-07: the xctest host has no functional Keychain, so the quick-pair RESUME path (gated on
        // `PairingStore.load()`) is only drivable with the in-memory seam. Scoped per-test + reset in a
        // defer so it never leaks to other suites (e.g. PrivacyDataTests relies on the no-op Keychain).
        PairingStore.useInMemoryBackingForTests = true
        defer { PairingStore.useInMemoryBackingForTests = false }
        PairingStore.clear()
        defer { PairingStore.clear() }
        PairingStore.save(Self.storedSecret)

        let b = resumingBackend()
        b.beginPairingForTesting(code: "")   // quick-pair RESUME

        // maxResumeRetries == 2 → the first two failures RETRY (budget 1, then 2), no terminal error.
        b.firePairingWatchdogForTesting()
        #expect(b.resumeRetryCountForTesting == 1)
        #expect(b.snapshot.connection != .error, "retry 1/2: still retrying, not errored")
        b.firePairingWatchdogForTesting()
        #expect(b.resumeRetryCountForTesting == 2)
        #expect(b.snapshot.connection != .error, "retry 2/2: still retrying, not errored")

        // The third failure EXHAUSTS the budget.
        b.firePairingWatchdogForTesting()

        #expect(b.snapshot.connection == .error, "an exhausted resume budget surfaces a terminal-but-retryable error")
        #expect(b.resumeRetryCountForTesting == 0, "the budget resets on exhaustion so the next reconnect gets a fresh budget")
        // The SAFETY-critical property: the derived secret is RETAINED even after exhaustion — NEVER auto-wiped.
        #expect(PairingStore.load() == Self.storedSecret, "the stored secret is retained even after the retry budget is exhausted")
        #expect(PairingStore.hasAnyPairing, "hasStoredPairing stays true after exhaustion — only forgetPairing() wipes it")
        // The error is presented as recoverable (retry / Forget Pairing), not a silent wipe-and-re-pair.
        #expect(b.snapshot.connectionDetail?.contains("Tap to retry") == true, "the exhausted error offers a retry")
        #expect(b.snapshot.connectionDetail?.contains("Forget Pairing") == true, "…and points at Forget Pairing, not an auto-wipe")
        // The transient auth key is dropped so the delivery gate fails closed, even though the durable secret stays.
        #expect(!b.isPairedForTesting, "the auth key is cleared (delivery gate fails closed) while the durable secret is retained")
    }

    /// 3 — Fresh full pair is UNCHANGED: with NO stored secret, `beginPairingForTesting(code: "123456")`
    /// drives a FRESH JPAKE pair (`onFirstPair != nil`), which arms the watchdog with
    /// `clearStoreOnTimeout: false`. Its timeout takes the pre-R2-07 straight-to-`.error` path — it NEVER
    /// enters the resume-retry budget (there is no stored secret to protect), so the retry count stays 0.
    @Test func freshFullPairFailureIsUnchangedAndNeverEntersTheResumeRetryPath() {
        // R2-07: the xctest host has no functional Keychain, so the quick-pair RESUME path (gated on
        // `PairingStore.load()`) is only drivable with the in-memory seam. Scoped per-test + reset in a
        // defer so it never leaks to other suites (e.g. PrivacyDataTests relies on the no-op Keychain).
        PairingStore.useInMemoryBackingForTests = true
        defer { PairingStore.useInMemoryBackingForTests = false }
        PairingStore.clear()
        defer { PairingStore.clear() }
        #expect(!PairingStore.hasAnyPairing, "precondition: no stored secret → a FRESH pair, not a resume")

        let b = resumingBackend()
        b.beginPairingForTesting(code: "123456")   // 6-digit → FRESH JPAKE pair (onFirstPair != nil)
        #expect(b.pairingCoordinatorIsLiveForTesting, "precondition: the fresh handshake is armed")
        #expect(b.resumeRetryCountForTesting == 0, "precondition: the resume budget is untouched")

        b.firePairingWatchdogForTesting()   // fresh-pair timeout → the unchanged straight-to-.error path

        #expect(b.snapshot.connection == .error, "a fresh full-pair timeout still fails closed straight to .error (unchanged)")
        #expect(b.resumeRetryCountForTesting == 0, "a fresh pair never enters the resume-retry budget — no stored secret to protect")
        #expect(!PairingStore.hasAnyPairing, "a fresh-pair failure has no stored secret — nothing to wipe or retain")
        // The fresh-pair detail is the pre-existing copy, distinct from the resume-exhausted "Forget Pairing" copy.
        #expect(b.snapshot.connectionDetail?.contains("t:connect") == true, "the fresh-pair failure keeps its unchanged copy")
        #expect(b.snapshot.connectionDetail?.contains("Forget Pairing") != true, "the fresh path must not show the resume-recovery copy")
    }

    /// C1-01 (owner-adopted 2026-08-25) — a unique durable-ledger URL so `AppModel` instances in these
    /// tests don't share the App Group ledger with other serialized suites. Mirrors
    /// `SafetyNotificationTests.tempLedgerURL()`.
    private func tempLedgerURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("resume-retry-ledger-\(UUID().uuidString).json")
    }

    /// 5 — C1-01 (Test 1 of the plan's 3): a transient resume-failure within the retry budget calls the
    /// RE-ESTABLISH path (`connectKnownPeripheral`), never `disconnect()` — the fix for the bug where
    /// `disconnect()` sets `intentionalDisconnect = true` and kills the kit's reconnect ladder, so the link
    /// never comes back in the background. `client` is a real, unconnected `PumpBLEClient` with no fake
    /// double for BLE calls (unlike `tx`), so this asserts via the dedicated `resumeRetryActionForTesting`
    /// intent-recording seam rather than depending on the real `CBCentralManager`'s (nondeterministic in a
    /// test host) power state.
    @Test func resumeFailureRetryReestablishesRatherThanKillingTheLadder() {
        PairingStore.useInMemoryBackingForTests = true
        defer { PairingStore.useInMemoryBackingForTests = false }
        PairingStore.clear()
        defer { PairingStore.clear() }
        PairingStore.save(Self.storedSecret)
        // C1-01: the retry branch re-adopts the KNOWN peripheral id, exactly like `connect()`'s cold-launch
        // fast path — seed it so the fix takes the `connectKnownPeripheral` branch, not the `startScan()`
        // fallback (mirrors `PumpPeripheralStoreTests`' save/restore idiom).
        let priorPeripheralId = PumpPeripheralStore.id()
        defer { if let priorPeripheralId { PumpPeripheralStore.set(priorPeripheralId) } else { PumpPeripheralStore.clear() } }
        PumpPeripheralStore.set(UUID())

        let b = resumingBackend()
        b.beginPairingForTesting(code: "")
        #expect(b.resumeRetryActionForTesting == nil, "precondition: no reconnect action recorded yet")

        b.firePairingWatchdogForTesting()   // transient resume failure, budget remaining

        #expect(b.resumeRetryActionForTesting == .reestablish,
                "the retry branch must re-establish (connectKnownPeripheral), never disconnect() (C1-01)")
    }

    /// 6 — C1-01/C1-04 (Test 2 of the plan's 3): the SAME transient resume-failure ALSO fires the typed
    /// `onReliabilityEvent(.resumeRetryFailed)`, which `AppModel` translates into a never-suppressible
    /// `.pumpDisconnect` post + the escalation ladder — even though this edge dies from `.connecting`, where
    /// `SafetyEdge.connection` never raises (it only fires on a direct `.connected/.bolusing → down` edge).
    /// Observed at the `AppModel` notification seam, exactly like `SafetyNotificationTests`/
    /// `PumpBackgroundDisconnectNotificationTests` do — never by reaching into `NotificationCoordinator`
    /// (the backend must not reference it at all).
    @Test func transientResumeFailureAlarmsViaTypedEventDespiteDyingFromConnecting() {
        PairingStore.useInMemoryBackingForTests = true
        defer { PairingStore.useInMemoryBackingForTests = false }
        PairingStore.clear()
        defer { PairingStore.clear() }
        PairingStore.save(Self.storedSecret)

        let b = resumingBackend()
        let model = AppModel(source: b, ledgerStoreURL: tempLedgerURL())
        var posted: [NotificationBroker.Message] = []
        var scheduled: [DisconnectEscalation.Step] = []
        model.notificationSink = { msg, _, _ in posted.append(msg) }
        model.notificationScheduleSink = { scheduled = $0 }

        b.beginPairingForTesting(code: "")
        b.firePairingWatchdogForTesting()   // transient resume failure, budget remaining

        let disc = posted.filter { $0.category == .pumpDisconnect }
        #expect(disc.count == 1,
                "a transient resume-failure that dies from .connecting must still alarm, via the typed event")
        #expect(disc.first?.dedupeKey == "safety.pumpDisconnect",
                "reuses the SafetyEdge pump-disconnect dedupe key so a later reconnect withdraws it too")
        #expect(!scheduled.isEmpty, "the escalation ladder must be scheduled alongside the immediate T0 post")
        #expect(scheduled.map(\.id) == DisconnectEscalation.stepIds)
    }

    /// 7 — No regression: the EXHAUSTED branch (budget fully consumed) still alarms — it always has, via
    /// the pre-existing `SafetyEdge.connection` `.raise` on a direct transition to `.error` — this plan must
    /// not weaken or duplicate that path. Confirms the typed-event seam is additive, not a replacement.
    @Test func exhaustedBranchStillAlarmsViaTheExistingSafetyEdgeNoRegression() {
        PairingStore.useInMemoryBackingForTests = true
        defer { PairingStore.useInMemoryBackingForTests = false }
        PairingStore.clear()
        defer { PairingStore.clear() }
        PairingStore.save(Self.storedSecret)

        let b = resumingBackend()
        let model = AppModel(source: b, ledgerStoreURL: tempLedgerURL())
        var posted: [NotificationBroker.Message] = []
        model.notificationSink = { msg, _, _ in posted.append(msg) }
        model.notificationScheduleSink = { _ in }

        b.beginPairingForTesting(code: "")
        b.firePairingWatchdogForTesting()   // retry 1/2
        b.firePairingWatchdogForTesting()   // retry 2/2
        b.firePairingWatchdogForTesting()   // budget exhausted → straight to .error

        #expect(b.snapshot.connection == .error, "precondition: the budget is exhausted")
        #expect(posted.filter { $0.category == .pumpDisconnect }.count >= 1,
                "the exhausted branch must still alarm — no regression from the typed-event addition")
    }

    /// 8 — `forgetPairing()` (R2-06) remains the ONLY thing that wipes `PairingStore`. Together with tests 1
    /// and 2 (resume failures NEVER wipe), this pins the R2-07 boundary: the stored secret is durable across
    /// every automatic resume-failure path and is removed ONLY by an explicit user "Forget pairing".
    @Test func forgetPairingRemainsTheOnlyThingThatWipesTheStoredSecret() {
        // R2-07: the xctest host has no functional Keychain, so the quick-pair RESUME path (gated on
        // `PairingStore.load()`) is only drivable with the in-memory seam. Scoped per-test + reset in a
        // defer so it never leaks to other suites (e.g. PrivacyDataTests relies on the no-op Keychain).
        PairingStore.useInMemoryBackingForTests = true
        defer { PairingStore.useInMemoryBackingForTests = false }
        PairingStore.clear()
        defer { PairingStore.clear() }
        PairingStore.save(Self.storedSecret)
        #expect(PairingStore.hasAnyPairing, "precondition: a stored secret is present")

        let b = TandemBackend(testTransport: FakePumpTransport())   // default double: connected + paired
        b.forgetPairing()   // R2-06 explicit teardown-and-wipe

        #expect(PairingStore.load() == nil, "forgetPairing() is the ONLY thing that wipes the stored secret")
        #expect(!PairingStore.hasAnyPairing, "no pairing material survives an explicit forget")
        #expect(!b.isPairedForTesting, "the auth key is cleared on forget")
    }
}
