import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// Pins that a pump-declared comms-suspension holds new routine reads until resume, and that remote-dismiss
/// hides an alert only after an authenticated status-zero from the pump. Delivery, cancel, and time-sync must never be paused by the same gate.
@Suite(.serialized) @MainActor
struct PumpCommsSuspendTests {

    // MARK: - New routine sends are held while suspended, released on resume

    @Test func routineSendsAreHeldWhileSuspendedAndReleasedOnResume() {
        let fake = FakePumpTransport()
        let b = TandemBackend(testTransport: fake)
        b.startPollingForTesting()
        let baseline = fake.sent.count
        #expect(baseline > 0, "sanity: the post-pair burst must have sent something before any suspension")

        b.injectQualifyingEventBitsForTesting(TandemBackend.pumpCommunicationsSuspendedBitForTesting)
        #expect(b.isCommsSuspendedForTesting, "the comms-suspension bit must arm the pause")

        b.simulateRecurringFastAndStaticReadTickForTesting()  // a full fastRead()+staticRead() re-issue attempt
        #expect(
            fake.sent.count == baseline,
            "no NEW routine read must reach the wire while a pump comms-suspension is active")

        b.resumeCommsForTesting()
        #expect(!b.isCommsSuspendedForTesting, "resume must clear the pause")
        b.simulateRecurringFastAndStaticReadTickForTesting()
        #expect(
            fake.sent.count > baseline,
            "routine reads must resume reaching the wire once comms resume — released, not dropped forever")
    }

    /// The poll cadence itself (the 15s/60s watchdog) is never disabled by the pause — `PumpReadScheduler`
    /// still owns/ticks its own timer; only the injected send closure declines to forward to the wire.
    @Test func pausingNeverInvalidatesThePollTimerWatchdog() {
        let fake = FakePumpTransport()
        let b = TandemBackend(testTransport: fake)
        b.startPollingLeavingPollTimerRunningForTesting()
        #expect(b.pollTimerIsActiveForTesting)
        b.injectQualifyingEventBitsForTesting(TandemBackend.pumpCommunicationsSuspendedBitForTesting)
        #expect(
            b.pollTimerIsActiveForTesting,
            "the pause must never invalidate/remove the poll timer — it stays the watchdog fallback")
    }

    // MARK: - Deduped targeted re-fetches

    @Test func heldRoutineSendsAreDedupedByOpcode() {
        let fake = FakePumpTransport()
        let b = TandemBackend(testTransport: fake)
        b.injectQualifyingEventBitsForTesting(TandemBackend.pumpCommunicationsSuspendedBitForTesting)

        b.simulateRecurringFastAndStaticReadTickForTesting()
        let firstCount = b.pendingRefetchOpcodesForTesting.count
        #expect(firstCount > 0, "at least one routine read must have been held and recorded")

        b.simulateRecurringFastAndStaticReadTickForTesting()  // the SAME opcodes held again
        #expect(
            b.pendingRefetchOpcodesForTesting.count == firstCount,
            "a repeat opcode held across multiple ticks must be deduped (Set), never double-recorded")

        // Resuming clears the record — a fresh pause starts a fresh one, never leaking a stale entry.
        b.resumeCommsForTesting()
        #expect(b.pendingRefetchOpcodesForTesting.isEmpty)
    }

    // MARK: - An unrecognized qualifying-event bit fails closed

    @Test func unrecognizedQualifyingEventBitFailsClosedNeverPauses() {
        let fake = FakePumpTransport()
        let b = TandemBackend(testTransport: fake)
        b.startPollingForTesting()
        let baseline = fake.sent.count

        // Bit 0 (QualifyingEvent.alert in the kit's real enum) — a REAL, named bit, but not the one
        // this app-side consumer recognizes. Must never dispatch to an unknown handler (do NOT copy
        // pumpX2's fail-open-on-unknown-API handler selection).
        b.injectQualifyingEventBitsForTesting(1)
        #expect(!b.isCommsSuspendedForTesting, "an unrecognized bit must never arm the pause")

        b.simulateRecurringFastAndStaticReadTickForTesting()
        #expect(
            fake.sent.count > baseline,
            "routine reads must proceed completely unaffected by an unrecognized qualifying-event bit")
    }

    @Test func zeroBitsIsANoOp() {
        let fake = FakePumpTransport()
        let b = TandemBackend(testTransport: fake)
        b.injectQualifyingEventBitsForTesting(0)
        #expect(!b.isCommsSuspendedForTesting)
    }

    // MARK: - Delivery / cancel / time-sync / auth are never held by the pause

    /// Mirrors `TandemDeliveryOutcomeTests.cancelOnFirstPoll` — fires the real `cancelBolus()` mid-poll,
    /// racing an in-flight bolus, while comms are ALREADY marked suspended for the entire flow. Every
    /// signed step (time-sync, permission, initiate, cancel) must still reach the wire — none of them
    /// route through the gated `readScheduler.send` closure at all.
    @Test func deliveryCancelAndTimeSyncAreNeverHeldByThePause() async throws {
        let bolusId = 4242
        let fake = FakePumpTransport()
        let b = TandemBackend(testTransport: fake)
        b.deliveryPollTimeoutOverride = 1.2
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        fake.script(BolusPermissionResponse.props.opCode, .frame(FakePumpTransport.permissionGranted(bolusId: bolusId)))
        fake.script(InitiateBolusResponse.props.opCode, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
        fake.script(
            CurrentBolusStatusResponse.props.opCode,
            .frame(FakePumpTransport.currentBolusStatus(statusId: 1, bolusId: bolusId)),  // active — cancel fires here
            .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: bolusId)))  // done
        fake.script(
            LastBolusStatusV2Response.props.opCode,
            .frame(FakePumpTransport.lastBolus(bolusId: bolusId, deliveredMilliunits: 1500)))

        // Pause BEFORE the bolus flow starts, and leave it paused for the WHOLE flow — proving the pause
        // never touches the signed delivery/cancel/time-sync path regardless of when it was armed.
        b.injectQualifyingEventBitsForTesting(TandemBackend.pumpCommunicationsSuspendedBitForTesting)
        #expect(b.isCommsSuspendedForTesting)

        fake.willAwait = { [weak b] op in
            if op == CurrentBolusStatusResponse.props.opCode { Task { @MainActor in await b?.cancelBolus() } }
        }

        let delivered = try await b.deliverBolus(units: 1.5, carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
        #expect(delivered == 1.5, "the delivery flow must complete normally — untouched by the routine-send pause")
        #expect(
            fake.lastSent(CancelBolusRequest.props.opCode) != nil,
            "cancelBolus must dispatch immediately even while comms are marked suspended — never held/queued")
        #expect(
            fake.awaited.contains(TimeSinceResetResponse.props.opCode),
            "the pre-bolus time-sync must proceed unheld even while comms are suspended")
        #expect(
            fake.awaited.contains(BolusPermissionResponse.props.opCode),
            "the signed permission request (auth-adjacent, signed) must proceed unheld while comms are suspended")
        #expect(
            fake.awaited.contains(InitiateBolusResponse.props.opCode),
            "the signed initiate must proceed unheld while comms are suspended")
        #expect(
            b.isCommsSuspendedForTesting,
            "the pause itself must be untouched by any of the above — it only ever gated routine reads")
    }

    // MARK: - Ack-driven remote-dismiss

    /// A backend identified as a Mobi (`supportsRemoteAlertDismiss == true`) with a real active alert
    /// (bit 5, "Auto-off" — an ordinary, non-safety-critical alert id) ready to dismiss.
    private func makeMobiBackendWithActiveAlert() -> (TandemBackend, FakePumpTransport, PumpAlert)? {
        let fake = FakePumpTransport()
        let b = TandemBackend(testTransport: fake)
        b.injectStatusFrameForTesting(FakePumpTransport.apiVersion(major: 3, minor: 5))  // → isMobi=true (a table Mobi)
        b.injectStatusFrameForTesting(FakePumpTransport.alertStatusBitmap(1 << 5))
        guard let alert = b.activeNotifications.first(where: { $0.id == 5 }) else { return nil }
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        return (b, fake, alert)
    }

    @Test func authenticatedStatusZeroHidesTheAlert() async throws {
        let setup = try #require(makeMobiBackendWithActiveAlert())
        let (b, fake, alert) = setup
        fake.script(
            DismissNotificationResponse.props.opCode, .frame(FakePumpTransport.dismissNotificationAck(status: 0)))
        await b.dismissNotification(alert)
        #expect(
            !b.activeNotifications.contains(where: { $0.id == 5 }),
            "an authenticated status-zero ack must hide the alert")
        #expect(b.alertDebug.contains("cleared"))
    }

    @Test func rejectedStatusKeepsTheAlertVisible() async throws {
        let setup = try #require(makeMobiBackendWithActiveAlert())
        let (b, fake, alert) = setup
        fake.script(
            DismissNotificationResponse.props.opCode, .frame(FakePumpTransport.dismissNotificationAck(status: 7)))
        await b.dismissNotification(alert)
        #expect(
            b.activeNotifications.contains(where: { $0.id == 5 }),
            "a rejected (non-zero status) dismiss must NOT hide the alert — no optimistic ack")
        #expect(b.alertDebug.contains("rejected"))
    }

    @Test func noPumpResponseKeepsTheAlertVisible() async throws {
        let setup = try #require(makeMobiBackendWithActiveAlert())
        let (b, _, alert) = setup
        // No DismissNotificationResponse scripted → FakePumpTransport's default is a dropped/timed-out
        // reply, matching a genuinely lost ack over the air.
        await b.dismissNotification(alert)
        #expect(
            b.activeNotifications.contains(where: { $0.id == 5 }),
            "a lost/never-arriving dismiss ack must NOT hide the alert")
        #expect(b.alertDebug.contains("unconfirmed"))
    }

    @Test func sendFailureKeepsTheAlertVisible() async throws {
        let setup = try #require(makeMobiBackendWithActiveAlert())
        let (b, fake, alert) = setup
        fake.preWriteError[DismissNotificationRequest.props.opCode] = BolusError.pumpRejected(
            "simulated pre-write failure")
        await b.dismissNotification(alert)
        #expect(
            b.activeNotifications.contains(where: { $0.id == 5 }),
            "a pre-write send failure must NOT hide the alert")
    }

    /// "Snooze locally" (a pump that can't honor a remote dismiss — the default t:slim X2 test backend)
    /// is a distinct, explicitly-local action: it still hides immediately (it never claims the pump-side
    /// alert is gone), and it must never even attempt a signed dismiss send.
    @Test func tSlimSnoozeLocallyStaysDistinctAndImmediate() async {
        let fake = FakePumpTransport()
        let b = TandemBackend(testTransport: fake)  // default: isMobi=false ⇒ supportsRemoteAlertDismiss=false
        b.injectStatusFrameForTesting(FakePumpTransport.alertStatusBitmap(1 << 5))
        guard let alert = b.activeNotifications.first(where: { $0.id == 5 }) else {
            Issue.record("setup: the alert must be active before dismissing it")
            return
        }
        await b.dismissNotification(alert)
        #expect(
            !b.activeNotifications.contains(where: { $0.id == 5 }),
            "a pure local snooze still hides immediately — it is a LOCAL action, never claiming the pump cleared it")
        #expect(b.alertDebug.contains("local-snoozed"))
        #expect(fake.sent.isEmpty, "a non-remote-dismissable pump must never attempt a signed dismiss send")
    }

    // MARK: - Typed dismiss outcome + op-184 wire proof

    /// The op-184 dismiss wire must stay byte-identical: one signed non-delivery write with the typed method's cargo.
    @Test func op184WireIsExactlyOneSignedNonDeliveryWriteWithExactCargo() async throws {
        let setup = try #require(makeMobiBackendWithActiveAlert())
        let (b, fake, alert) = setup
        fake.script(
            DismissNotificationResponse.props.opCode, .frame(FakePumpTransport.dismissNotificationAck(status: 0)))
        await b.dismissNotification(alert)

        let dismissWrites = fake.sent.filter { $0.opCode == DismissNotificationRequest.props.opCode }
        #expect(dismissWrites.count == 1, "exactly one op-184 write per dismiss")
        let expectedCargo = DismissNotificationRequest(
            kind: NotificationKind(rawValue: alert.kind.rawValue) ?? .alert,
            notificationId: alert.id
        ).cargo
        #expect(
            dismissWrites.first?.cargo == expectedCargo,
            "op-184 cargo must be byte-identical to the typed method's own encode")
        #expect(dismissWrites.first?.signed == true, "op-184 must be signed")
        #expect(dismissWrites.first?.allowDelivery == false, "a dismiss is never a delivery-authorizing write")
        #expect(fake.awaited.contains(DismissNotificationResponse.props.opCode), "op-185 must be awaited")
    }

    /// `.authenticatedCleared` only from the exact `status == 0` signed-response branch.
    @Test func typedOutcomeIsAuthenticatedClearedOnlyOnStatusZero() async throws {
        let setup = try #require(makeMobiBackendWithActiveAlert())
        let (b, fake, alert) = setup
        fake.script(
            DismissNotificationResponse.props.opCode, .frame(FakePumpTransport.dismissNotificationAck(status: 0)))
        let outcome = await b.dismissNotificationTyped(alert)
        #expect(outcome == .authenticatedCleared)
    }

    @Test func typedOutcomeIsRejectedOnNonZeroStatus() async throws {
        let setup = try #require(makeMobiBackendWithActiveAlert())
        let (b, fake, alert) = setup
        fake.script(
            DismissNotificationResponse.props.opCode, .frame(FakePumpTransport.dismissNotificationAck(status: 7)))
        let outcome = await b.dismissNotificationTyped(alert)
        #expect(outcome == .rejected)
    }

    @Test func typedOutcomeIsNoResponseOnLostAck() async throws {
        let setup = try #require(makeMobiBackendWithActiveAlert())
        let (b, _, alert) = setup
        // No DismissNotificationResponse scripted → dropped/timed-out, matching a genuinely lost ack.
        let outcome = await b.dismissNotificationTyped(alert)
        #expect(outcome == .noResponse)
    }

    @Test func typedOutcomeIsNoResponseOnPreWriteFailure() async throws {
        let setup = try #require(makeMobiBackendWithActiveAlert())
        let (b, fake, alert) = setup
        fake.preWriteError[DismissNotificationRequest.props.opCode] = BolusError.pumpRejected(
            "simulated pre-write failure")
        let outcome = await b.dismissNotificationTyped(alert)
        #expect(outcome == .noResponse)
    }

    /// A t:slim X2-like pump (no remote-dismiss capability) returns `.localSnoozeOnly` — never
    /// authenticated, and never sends the signed op-184 at all.
    @Test func typedOutcomeIsLocalSnoozeOnlyOnNonRemoteDismissablePump() async {
        let fake = FakePumpTransport()
        let b = TandemBackend(testTransport: fake)
        b.injectStatusFrameForTesting(FakePumpTransport.alertStatusBitmap(1 << 5))
        guard let alert = b.activeNotifications.first(where: { $0.id == 5 }) else {
            Issue.record("setup: the alert must be active before dismissing it")
            return
        }
        let outcome = await b.dismissNotificationTyped(alert)
        #expect(outcome == .localSnoozeOnly)
        #expect(fake.sent.isEmpty)
    }

    /// MEDIUM-D: the single op-184 call graph holds through BOTH entry points — the LEGACY void
    /// `dismissNotification(_:)` calls the typed method exactly once and discards its outcome; no
    /// double-send, no recursion.
    @Test func legacyVoidDismissCallsTypedMethodExactlyOnceNoDoubleSend() async throws {
        let setup = try #require(makeMobiBackendWithActiveAlert())
        let (b, fake, alert) = setup
        fake.script(
            DismissNotificationResponse.props.opCode, .frame(FakePumpTransport.dismissNotificationAck(status: 0)))
        await b.dismissNotification(alert)  // the legacy void entry point
        let dismissWrites = fake.sent.filter { $0.opCode == DismissNotificationRequest.props.opCode }
        #expect(
            dismissWrites.count == 1, "the legacy void wrapper must call the typed method exactly once — no double-send"
        )
    }
}
