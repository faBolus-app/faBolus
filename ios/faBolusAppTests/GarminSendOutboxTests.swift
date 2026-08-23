import Testing
import Foundation
@testable import faBolus

/// **CR / R2-12.** Pins `garminSendDisposition` — the ConnectIQ-free classifier for a Garmin outbound
/// `sendMessage` result that backs the bridge's durable terminal-echo outbox. It lives OUTSIDE `#if GARMIN`
/// (next to `GarminMessageReadiness`) precisely so it compiles and is unit-testable in the default
/// (non-GARMIN) test target, where the ConnectIQ-typed bridge is not.
///
/// LOAD-BEARING INVARIANT: a terminal command echo (`isEcho == true`) must NEVER be dropped on an EXPLICIT
/// send-failure — it re-enqueues to the FRONT of the durable `echoQueue`, which WR-07's readiness-gated
/// reconnect/discovery drain replays. Dropping a terminal `bolusStatus` echo permanently loses the outcome
/// and strands the watch at "delivering…" forever (it makes the watch-side R2-02 stuck-terminal permanent).
/// A coalesced status snapshot (`isEcho == false`) is coalescing-safe and MAY be dropped on failure — a
/// newer status supersedes it. The `#if GARMIN` completion closure AND the send-watchdog's
/// `maxSendAttempts`-exhaustion path route their keep/drop decision through this one helper.
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
}
