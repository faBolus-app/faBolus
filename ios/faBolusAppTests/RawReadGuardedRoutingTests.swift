import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// tslim-reconnect-loop (Phase B, item 4). The raw-send reads — HistoryLog (op60), the IDP cascade
/// (IDPSettings op64 / IDPSegment op66), ProfileStatus, and the auto-on-connect HistoryLogStatus (op58) —
/// used to go out via raw `tx.send`/`client.send`, bypassing the `badOpcodes` never-resend backstop and
/// the op-77 correlation the tiered poll reads get. They now route through the GUARDED read path
/// (`sendOnDemandRead` → `sendStatusRead`), so a pump that rejects one of them self-heals (learn-and-stop)
/// instead of the app hammering it every connection/page — while a pump that supports them (e.g. the
/// owner's, where HistoryLog streams fine) is unaffected: the guard only ever SKIPS an opcode the pump has
/// actually rejected. HISTORY stays GRACEFUL by design (guarded path + dynamic self-heal, never
/// hard-disabled).
///
/// Two proofs per read family:
///  (a) ROUTING: injecting the response frame that triggers the send now fires `onReadDispatchedForTesting`
///      (that seam fires ONLY from `sendStatusRead`). Pre-item-4 these sites went through raw `tx`/`client`
///      and NEVER fired it (see `ReadCascadeChainingGuardTests`' B3 doc) — so this observation is itself the
///      routing change.
///  (b) GUARD: with the read's opcode seeded into `badOpcodes`, the send is SKIPPED — captured neither in
///      the fake transport's `sent` nor re-dispatched. This is the whole point of item 4 and was impossible
///      before the reroute (a raw `tx.send` ignores `badOpcodes` entirely).
///
/// Byte-identity: the scheduler's `send` closure forwards the SAME `tx.send(authenticationKey:[],
/// pumpTimeSinceReset:0, allowInsulinDelivery:false)` defaults these sites used, so no wire bytes change
/// (and the signed dose/delivery path is untouched — every read here is unsigned).
@Suite(.serialized) @MainActor
struct RawReadGuardedRoutingTests {

    private func makeBackend() -> (TandemBackend, FakePumpTransport) {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        return (backend, fake)
    }

    /// op-63 `ProfileStatusResponse` (8 bytes) — mirrors `ReadCascadeChainingGuardTests.profileStatusFrame`.
    private static func profileStatusFrame(numberOfProfiles: Int, slotIds: [Int]) -> [UInt8] {
        precondition(slotIds.count == 6)
        var c = [UInt8](repeating: 0, count: 8)
        c[0] = UInt8(bitPattern: Int8(numberOfProfiles))
        for i in 0..<6 { c[1 + i] = UInt8(bitPattern: Int8(slotIds[i])) }
        return FakePumpTransport.frame(opCode: ProfileStatusResponse.props.opCode, cargo: c, signed: false)
    }

    /// op-65 `IDPSettingsResponse` (23 bytes) — mirrors `ReadCascadeChainingGuardTests.idpSettingsFrame`.
    private static func idpSettingsFrame(idpId: Int, numberOfProfileSegments: Int) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 23)
        c[0] = UInt8(idpId)
        c[17] = UInt8(numberOfProfileSegments)
        return FakePumpTransport.frame(opCode: IDPSettingsResponse.props.opCode, cargo: c, signed: false)
    }

    private var idpSettingsOpcode: UInt8 { IDPSettingsRequest.props.opCode }
    private var idpSegmentOpcode: UInt8 { IDPSegmentRequest.props.opCode }
    private var historyStatusOpcode: UInt8 { HistoryLogStatusRequest.props.opCode }

    // MARK: - (a) ROUTING: the IDP cascade now fires the guarded-path dispatch seam

    /// The `ProfileStatusResponse` → `IDPSettingsRequest` cascade now runs through `sendStatusRead`, so it
    /// fires `onReadDispatchedForTesting` (which ONLY `sendStatusRead` fires). This is the routing change:
    /// pre-item-4 the cascade went out via raw `tx` and never reached this seam.
    @Test func idpCascadeNowRoutesThroughTheGuardedDispatchSeam() {
        let (backend, _) = makeBackend()
        var dispatched: [UInt8] = []
        backend.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        backend.injectStatusFrameForTesting(Self.profileStatusFrame(numberOfProfiles: 2, slotIds: [2, 5, -1, -1, -1, -1]))
        #expect(dispatched.filter { $0 == idpSettingsOpcode }.count == 2,
                "each IDPSettingsRequest must now dispatch through the guarded sendStatusRead path (fires onReadDispatchedForTesting)")
    }

    /// `IDPSettingsResponse` → `IDPSegmentRequest` segment cascade likewise routes through the guarded path.
    @Test func idpSegmentCascadeNowRoutesThroughTheGuardedDispatchSeam() {
        let (backend, _) = makeBackend()
        backend.setViewedProfileIdForTesting(5)
        var dispatched: [UInt8] = []
        backend.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        backend.injectStatusFrameForTesting(Self.idpSettingsFrame(idpId: 5, numberOfProfileSegments: 3))
        #expect(dispatched.filter { $0 == idpSegmentOpcode }.count == 3,
                "each IDPSegmentRequest for the viewed profile must dispatch through the guarded path")
    }

    /// The auto-on-connect history-status read (op58, off an unsolicited `TimeSinceResetResponse`) now
    /// routes through the guarded path too.
    @Test func autoHistoryStatusReadNowRoutesThroughTheGuardedDispatchSeam() {
        let saved = AppSettings.shared.historySyncEnabled
        defer { AppSettings.shared.historySyncEnabled = saved }
        AppSettings.shared.historySyncEnabled = true
        let (backend, _) = makeBackend()
        var dispatched: [UInt8] = []
        backend.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
        #expect(dispatched.contains(historyStatusOpcode),
                "the once-per-connection history-status read must dispatch through the guarded path")
    }

    // MARK: - (b) GUARD: a seeded badOpcode now SKIPS these reads (impossible pre-item-4)

    /// With IDPSettings (op64) seeded into `badOpcodes`, the `ProfileStatusResponse` cascade SKIPS the
    /// IDP-settings sends — they reach neither the wire (`fake.sent`) nor a re-dispatch. A raw `tx.send`
    /// ignored `badOpcodes` entirely, so this suppression is only possible via the item-4 reroute.
    @Test func seededBadOpcodeNowSuppressesTheIdpRead_notPossibleBeforeReroute() {
        let (backend, fake) = makeBackend()
        backend.insertBadOpcodeForTesting(idpSettingsOpcode)
        var skipped: [UInt8] = []
        backend.onReadSkippedForTesting = { _, op in skipped.append(op) }

        backend.injectStatusFrameForTesting(Self.profileStatusFrame(numberOfProfiles: 2, slotIds: [2, 5, -1, -1, -1, -1]))

        #expect(!fake.sent.contains { $0.opCode == idpSettingsOpcode },
                "a badOpcode-guarded IDPSettings read must NOT reach the wire — the item-4 reroute now honors badOpcodes")
        #expect(skipped.filter { $0 == idpSettingsOpcode }.count == 2,
                "both IDPSettings sends must be SKIPPED by the never-resend guard (graceful self-heal)")
    }

    /// GRACEFUL: when the read is NOT in `badOpcodes` (the owner's supported pump), the guarded path sends
    /// it exactly as before — proving item 4 never hard-disables a read that works.
    @Test func unseededIdpReadStillReachesTheWire_gracefulWhenSupported() {
        let (backend, fake) = makeBackend()
        backend.injectStatusFrameForTesting(Self.profileStatusFrame(numberOfProfiles: 1, slotIds: [3, -1, -1, -1, -1, -1]))
        #expect(fake.sent.contains { $0.opCode == idpSettingsOpcode && Int($0.cargo[0]) == 3 },
                "an unrejected IDP read still goes out on the wire — the guard only skips a rejected opcode")
    }
}
