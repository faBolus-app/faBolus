import Testing
import Foundation
@testable import faBolus

/// Pins that a failed Garmin terminal-echo send re-enqueues to the front of the durable outbox and is
/// never dropped. Dropping it strands the watch at "delivering…" with the outcome lost.
struct GarminSendOutboxTests {

    // MARK: success ⇒ ack (drop-from-outbox), regardless of payload class

    @Test func successAcksAnEcho() {
        #expect(garminSendDisposition(success: true, isEcho: true) == .ack)
    }

    @Test func successAcksAStatusSnapshot() {
        #expect(garminSendDisposition(success: true, isEcho: false) == .ack)
    }

    // MARK: explicit failure — the durable-outbox invariant

    /// The key invariant: an explicit send-failure of a terminal echo must durable-park, never drop.
    @Test func echoFailureReenqueuesFrontNeverDrops() {
        let d = garminSendDisposition(success: false, isEcho: true)
        #expect(d == .reenqueueFront)
        #expect(d != .drop, "a terminal echo must survive an explicit send-failure — dropping it strands the watch")
    }

    /// A coalesced status snapshot is safe to drop on failure (a newer status supersedes it).
    @Test func nonEchoFailureDrops() {
        #expect(garminSendDisposition(success: false, isEcho: false) == .drop)
    }

    // MARK: watchdog `maxSendAttempts` exhaustion routes through the SAME helper

    /// The send-watchdog's exhaustion path classifies with the same helper as the completion closure, so an
    /// exhausted echo parks (`.reenqueueFront`) exactly like an explicit completion failure — never dropped.
    @Test func watchdogExhaustionOfAnEchoParks() {
        #expect(garminSendDisposition(success: false, isEcho: true) == .reenqueueFront)
    }

    /// A watchdog-exhausted non-echo status snapshot is coalescing-safe to drop (mirror of the completion path).
    @Test func watchdogExhaustionOfAStatusDrops() {
        #expect(garminSendDisposition(success: false, isEcho: false) == .drop)
    }

    // MARK: I-M3 — permanent-vs-transient granularity (the ConnectIQ-free `GarminSendResult` overload)
    //
    // `garminSendDisposition(result:isEcho:)` is a NEW overload alongside the boolean one above (never
    // replacing it — every test above still exercises the original boolean seam unchanged). A PERMANENT
    // echo failure (AppNotFound/UnsupportedType/InsufficientMemory, IQConstants.h:34-48) is unrecoverable:
    // retrying it forever busy-loops for nothing, so it surfaces to diagnostics and drops from the
    // in-memory outbox — the durable RemoteBolusLedger launch re-seed remains the terminal-outcome
    // backstop. A TRANSIENT echo failure is UNCHANGED from the boolean seam: never dropped, re-enqueued
    // to the front. Any non-echo (coalescing-safe status) failure drops regardless of permanent/transient.

    @Test func successResultAcksAnEcho() {
        #expect(garminSendDisposition(result: .success, isEcho: true) == .ack)
    }

    @Test func successResultAcksAStatusSnapshot() {
        #expect(garminSendDisposition(result: .success, isEcho: false) == .ack)
    }

    /// LOAD-BEARING: a TRANSIENT echo failure must NEVER be dropped — unchanged from the boolean seam.
    @Test func transientEchoFailureReenqueuesFrontNeverDrops() {
        let d = garminSendDisposition(result: .transientFailure, isEcho: true)
        #expect(d == .reenqueueFront)
        #expect(d != .drop && d != .surfaceAndDrop,
                "a TRANSIENT echo failure must survive — only a PERMANENT failure may surface+drop")
    }

    /// The other half of the LOAD-BEARING invariant: only PERMANENT surfaces+drops; TRANSIENT never does.
    @Test func permanentEchoFailureSurfacesAndDrops() {
        #expect(garminSendDisposition(result: .permanentFailure, isEcho: true) == .surfaceAndDrop)
    }

    @Test func transientNonEchoFailureDrops() {
        #expect(garminSendDisposition(result: .transientFailure, isEcho: false) == .drop)
    }

    @Test func permanentNonEchoFailureDrops() {
        #expect(garminSendDisposition(result: .permanentFailure, isEcho: false) == .drop)
    }
}
