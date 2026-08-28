import Testing
import Foundation
import TandemMessages
import TandemBLE
@testable import faBolus

/// codex C3 (15.5-03, REMED-15.5): app-side pre-identity contract test off the REAL scheduler seam.
///
/// A comment-only cross-reference between the kit's (currently empty) `SendGateBootstrapAllowlist`
/// (`TandemKit/Sources/TandemMessages/Core/SupportedDevices.swift`) and the app's actual pre-identity read
/// schedule cannot fail CI when a future scheduler change adds a model-restricted read — this test closes
/// that gap by DYNAMICALLY capturing the REAL send set `PumpReadScheduler`
/// (`ios/faBolus/Data/Tandem/PumpReadScheduler.swift`) issues, via its own injectable `send` closure, and
/// evaluating every one of those messages — plus the enumerated out-of-scheduler pairing/response-triggered/
/// reconciliation paths — through the REAL, kit-owned `PumpBLEClient.identityGateError(for:)` on a fresh,
/// untrusted client. If ANY of them is ever refused, reconnection deadlocks (the very read needed to reach
/// op33 identity would itself be gated by the identity it is trying to establish) — this test fails CI
/// instead of the field.
///
/// Capture is bound to `PumpReadScheduler.startPollingForTesting()` (`:846-849`, `#if DEBUG`) + a direct
/// `alertRead()` call: `startPollingForTesting()`'s `stopAllTimers()` invalidates the `Timer`-based
/// `pollTimer`/`predictivePollTimer`, but `scheduleAlertRead()` (`:802-808`) arms its deferred burst via
/// `DispatchQueue.main.asyncAfter`, which `stopAllTimers()` cannot cancel — so `alertRead()`'s 5 messages
/// are captured by calling it directly (it is non-`private`), not by waiting out the real delay.
@Suite @MainActor
struct PreIdentitySendContractTests {

    @Test func noPreIdentitySendIsEverModelRestricted() {
        let scheduler = PumpReadScheduler()
        var captured: [any Message] = []
        scheduler.send = { msg in
            captured.append(msg)
            return 0
        }
        scheduler.isConnected = { true }
        scheduler.startPollingForTesting()  // bootstrap trio + fastRead(includingIdentityGatedReads:false) + staticRead()
        scheduler.alertRead()  // the deferred burst — captured directly (see class doc, asyncAfter nuance)

        // Paths PumpReadScheduler does NOT own, enumerated from source (RE-DERIVE if these sources change —
        // Phase 16 moved the app's Data/ tree; anchors re-confirmed against live source 2026-08-26):
        //  - Pairing (kit-owned message types, TandemMessages/Requests/Authentication/*.swift — the signing/
        //    handshake LOGIC lives in the separate TandemAuth module, but the WIRE MESSAGE TYPES the app
        //    actually sends live here): Jpake1a/1b/2/3SessionKey/4KeyConfirmationRequest + CentralChallengeRequest
        //    + PumpChallengeRequest — zero `supportedDevices` hits (re-confirmed this session).
        //  - Response-triggered history status: `PumpResponseApplier.swift:359`'s `HistoryLogStatusRequest`
        //    send, fired from an unsolicited `TimeSinceResetResponse` (gated on `AppSettings.historySyncEnabled`,
        //    but the send itself carries no model restriction either way).
        //  - Post-pairing reconciliation: `TandemBackend.swift`'s `findBolusInHistory` (`:1548-1598`, reached
        //    from `reconcileIndeterminateDelivery()` `:1509-1521` and `reconcile(bolusId:)` `:1530-1532`) —
        //    `lastBolusStatus()` [`LastBolusStatusV2Request`] fast path, then on a miss `HistoryLogStatusRequest`
        //    to learn the range, then bounded `HistoryLogRequest(startLog:numberOfLogs:)` pages.
        let outOfSchedulerPaths: [any Message] = [
            Jpake1aRequest(), Jpake1bRequest(), Jpake2Request(), Jpake3SessionKeyRequest(),
            Jpake4KeyConfirmationRequest(),
            CentralChallengeRequest(), PumpChallengeRequest(),
            HistoryLogStatusRequest(), HistoryLogRequest(startLog: 0, numberOfLogs: 1), LastBolusStatusV2Request()
        ]

        #expect(
            !captured.isEmpty,
            "the dynamic capture must have actually captured something from the real scheduler — an empty capture would make this test vacuously true"
        )

        let client = PumpBLEClient()  // fresh, unidentified: connectedPumpModel == nil, identityTrusted == false
        for message in captured + outOfSchedulerPaths {
            #expect(
                client.identityGateError(for: message) == nil,
                "\(type(of: message)) (opcode \(message.opCode)) must never be refused pre-identity — reconnection would deadlock"
            )
        }
    }
}
