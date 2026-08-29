import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// Pins response-driven IDP, history, and predictive-burst chains through the injectable transport
/// so a pump rejection fail-closes instead of hammering, and an untrusted EGV timestamp stays
/// stale-CGM (never stamped now onto the dose path).
@Suite(.serialized) @MainActor
struct ReadCascadeChainingGuardTests {

    private func makeBackend() -> (TandemBackend, FakePumpTransport) {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        return (backend, fake)
    }

    /// Save + restore `AppSettings.shared.historyCoverage` around a test, mirroring
    /// `HistoryLogSyncTests.withCleanCoverage`'s idiom for the same shared-singleton hazard.
    private func withCleanCoverage(_ body: () throws -> Void) rethrows {
        let saved = AppSettings.shared.historyCoverage
        defer { AppSettings.shared.historyCoverage = saved }
        AppSettings.shared.historyCoverage = HistoryCoverageMap()
        try body()
    }

    // MARK: - Fixture frame builders (B3, B5 — not already provided by `FakePumpTransport`)

    /// op-63 `ProfileStatusResponse` (8 bytes): numberOfProfiles (signed byte @0), 6 raw idp slot ids
    /// (signed bytes @1...6, -1 = empty), activeSegmentIndex (signed byte @7). `presentIdpIds` is the
    /// first `numberOfProfiles` slot ids.
    private static func profileStatusFrame(numberOfProfiles: Int, slotIds: [Int]) -> [UInt8] {
        precondition(slotIds.count == 6)
        var c = [UInt8](repeating: 0, count: 8)
        c[0] = UInt8(bitPattern: Int8(numberOfProfiles))
        for i in 0..<6 { c[1 + i] = UInt8(bitPattern: Int8(slotIds[i])) }
        c[7] = 0
        return FakePumpTransport.frame(opCode: ProfileStatusResponse.props.opCode, cargo: c, signed: false)
    }

    /// op-65 `IDPSettingsResponse` (23 bytes): idpId@0, name[16]@1, numberOfProfileSegments@17,
    /// insulinDuration short@18, maxBolus short@20, carbEntry@22.
    private static func idpSettingsFrame(idpId: Int, numberOfProfileSegments: Int) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 23)
        c[0] = UInt8(idpId)
        c[17] = UInt8(numberOfProfileSegments)
        return FakePumpTransport.frame(opCode: IDPSettingsResponse.props.opCode, cargo: c, signed: false)
    }

    /// op-35 `CurrentEGVGuiDataResponse` (V1, 8 bytes) with an explicit `pumpSec` (`bgReadingTimestampSeconds`,
    /// uint32@0) — `FakePumpTransport.currentEgvV1` always leaves this zero, so B5's "advancing timestamp"
    /// behavior needs its own builder.
    private static func currentEgvV1Frame(pumpSec: UInt32, mgdl: Int) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 8)
        let ts = Bytes.toUint32(pumpSec); for i in 0..<4 { c[i] = ts[i] }
        let bg = Bytes.firstTwoBytesLittleEndian(mgdl); c[4] = bg[0]; c[5] = bg[1]
        c[6] = 1   // egvStatusId = 1 → hasValidReading
        return FakePumpTransport.frame(opCode: CurrentEGVGuiDataResponse.props.opCode, cargo: c, signed: false)
    }

    // MARK: - B3: response-driven IDP cascade

    @Test func profileStatusResponseDispatchesOneIDPSettingsRequestPerPresentIdInOrder() {
        let (backend, fake) = makeBackend()
        backend.injectStatusFrameForTesting(Self.profileStatusFrame(numberOfProfiles: 3, slotIds: [2, 5, 9, -1, -1, -1]))
        let settingsSends = fake.sent.filter { $0.opCode == IDPSettingsRequest.props.opCode }
        #expect(settingsSends.count == 3, "one IDPSettingsRequest per present idp id")
        #expect(settingsSends.map { Int($0.cargo[0]) } == [2, 5, 9],
                "requested ids, in order, must match presentIdpIds exactly")
    }

    @Test func profileStatusResponseSkipsEmptySlots() {
        let (backend, fake) = makeBackend()
        // Only 2 of 6 slots present; the other 4 raw slot bytes are -1 sentinels the loop's `id >= 0`
        // guard must filter, and `numberOfProfiles` bounds `presentIdpIds` to the first 2 regardless.
        backend.injectStatusFrameForTesting(Self.profileStatusFrame(numberOfProfiles: 2, slotIds: [0, 1, -1, -1, -1, -1]))
        let settingsSends = fake.sent.filter { $0.opCode == IDPSettingsRequest.props.opCode }
        #expect(settingsSends.count == 2)
        #expect(settingsSends.map { Int($0.cargo[0]) } == [0, 1])
    }

    @Test func idpSettingsResponseDispatchesOneIDPSegmentRequestPerSegmentWhenProfileIsViewed() {
        let (backend, fake) = makeBackend()
        backend.setViewedProfileIdForTesting(5)
        backend.injectStatusFrameForTesting(Self.idpSettingsFrame(idpId: 5, numberOfProfileSegments: 4))
        let segmentSends = fake.sent.filter { $0.opCode == IDPSegmentRequest.props.opCode }
        #expect(segmentSends.count == 4, "one IDPSegmentRequest per segment of the viewed profile")
        #expect(segmentSends.map { Int($0.cargo[0]) } == [5, 5, 5, 5], "every segment request targets the viewed idpId")
        #expect(segmentSends.map { Int($0.cargo[1]) } == [0, 1, 2, 3], "segment indices in order, 0-based")
    }

    @Test func idpSettingsResponseDoesNotDispatchSegmentReadsWhenProfileIsNotViewed() {
        let (backend, fake) = makeBackend()
        backend.setViewedProfileIdForTesting(7)   // different from the responding profile's idpId (5)
        backend.injectStatusFrameForTesting(Self.idpSettingsFrame(idpId: 5, numberOfProfileSegments: 4))
        #expect(!fake.sent.contains { $0.opCode == IDPSegmentRequest.props.opCode },
                "segment reads must only fire for the profile currently being viewed")
    }

    // MARK: - B4: response-driven history-log cascade

    @Test func timeSinceResetResponseTriggersHistoryLogStatusRequestAtMostOncePerConnection() {
        withCleanCoverage {
            let (backend, fake) = makeBackend()
            backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
            backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())   // 2nd unsolicited time frame, same connection
            let historyStatusSends = fake.sent.filter { $0.opCode == HistoryLogStatusRequest.props.opCode }
            #expect(historyStatusSends.count == 1,
                    "the once-per-connection gate must suppress a second unsolicited TimeSinceResetResponse")
        }
    }

    @Test func historyLogStatusResponseWithEntriesBeginsGapSync() {
        withCleanCoverage {
            let (backend, _) = makeBackend()
            backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 50, firstSequenceNum: 1, lastSequenceNum: 50))
            #expect(backend.historySyncState == .syncing, "a status reply reporting entries must begin a gap sync")
        }
    }

    @Test func historyLogStatusResponseWithNoEntriesResolvesAnOptimisticSyncingStateToIdle() {
        withCleanCoverage {
            let (backend, _) = makeBackend()
            backend.setConnectionForTesting(.connected)
            backend.triggerManualHistorySync()   // sets historySyncState = .syncing optimistically, pre-reply
            #expect(backend.historySyncState == .syncing)
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 0, firstSequenceNum: 1, lastSequenceNum: 0))
            if case .idle = backend.historySyncState {
                // expected
            } else {
                Issue.record("expected .idle after a numEntries==0 reply, got \(backend.historySyncState)")
            }
        }
    }

    // MARK: - B5: predictive-burst lifecycle

    @Test func advancingEgvReadingSchedulesAPredictiveBurstDeadline() {
        let (backend, _) = makeBackend()
        #expect(backend.predictiveBurstDeadlineForTesting == nil, "no burst scheduled before any reading arrives")
        backend.injectStatusFrameForTesting(Self.currentEgvV1Frame(pumpSec: 1000, mgdl: 120))
        #expect(backend.predictiveBurstDeadlineForTesting != nil,
                "an EGV reading whose pump timestamp advances (0 → 1000) must schedule a predictive burst")
    }

    /// VA-01 (freshness fail-closed): an EGV reading whose pump timestamp CANNOT be trusted — here no
    /// pump↔phone clock anchor exists yet (bootstrap-early), so `cgmReadingDate` returns nil — must set the
    /// glucose VALUE but leave `glucoseDate` nil, so `GlucoseFreshness.isStale` reads it as stale/ineligible
    /// for dosing rather than stamping receive-time and letting a bootstrap-early reading masquerade as
    /// fresh. Predictive-poll cadence still fires (it falls back to `now`), which the test above covers.
    @Test func untrustworthyReadingTimeIsStaleNotStampedNow() {
        let (backend, _) = makeBackend()
        // No timeResponse injected → no anchor → the reading time is untrustworthy.
        backend.injectStatusFrameForTesting(Self.currentEgvV1Frame(pumpSec: 1000, mgdl: 120))
        #expect(backend.snapshot.glucose == 120, "the value still lands — only its timestamp is untrusted")
        #expect(backend.snapshot.glucoseDate == nil, "an untrusted reading time must be nil, never stamped as now")
        #expect(GlucoseFreshness.isStale(backend.snapshot.glucoseDate),
                "a nil reading time is stale — never presented as fresh to the dose path")
    }

    /// VA-01 happy path: with the pump↔phone clock anchor established, an EGV whose pump timestamp maps to a
    /// recent (trusted) `Date` DOES stamp `glucoseDate` (fresh) and IS promoted into the plot history —
    /// proving the fail-closed change did not break the normal, trusted-timestamp reading.
    @Test func trustedReadingTimeSetsGlucoseDateAndPromotesToHistory() {
        let (backend, _) = makeBackend()
        backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse(currentTime: 1000))
        backend.injectStatusFrameForTesting(Self.currentEgvV1Frame(pumpSec: 990, mgdl: 118))   // ~10 s before the anchor
        #expect(backend.snapshot.glucose == 118)
        #expect(backend.snapshot.glucoseDate != nil, "a trusted reading time IS stamped on the snapshot")
        #expect(!GlucoseFreshness.isStale(backend.snapshot.glucoseDate), "a just-taken reading is fresh")
        #expect(backend.glucoseHistory.last?.mgdl == 118, "a trusted reading is promoted into the plot history")
    }

    @Test func aLaterAdvancingReadingReschedulesTheBurstDeadlineForward() {
        let (backend, _) = makeBackend()
        // Anchor the pump↔phone clock close to "now" so each reading's `pumpSec` maps to a real, ordered
        // `Date` rather than being clamped by `cgmReadingDate`'s future-guard (candidates > now+60s clamp
        // to `now`, which would make both deadlines collapse to the same value and defeat this test).
        backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse(currentTime: 1000))
        backend.injectStatusFrameForTesting(Self.currentEgvV1Frame(pumpSec: 1010, mgdl: 120))   // +10s vs. anchor
        let firstDeadline = backend.predictiveBurstDeadlineForTesting
        backend.injectStatusFrameForTesting(Self.currentEgvV1Frame(pumpSec: 1020, mgdl: 121))   // +20s vs. anchor — advances
        let secondDeadline = backend.predictiveBurstDeadlineForTesting
        #expect(firstDeadline != nil && secondDeadline != nil)
        if let d1 = firstDeadline, let d2 = secondDeadline {
            #expect(d2 > d1, "a newer advancing reading must reschedule the burst deadline forward, not leave it in place")
        }
    }

    @Test func aNonAdvancingReadingDoesNotRescheduleTheBurstDeadline() {
        let (backend, _) = makeBackend()
        backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse(currentTime: 1000))
        backend.injectStatusFrameForTesting(Self.currentEgvV1Frame(pumpSec: 1010, mgdl: 120))
        let deadlineAfterFirst = backend.predictiveBurstDeadlineForTesting
        #expect(deadlineAfterFirst != nil)
        // Same pumpSec again — not an advance (`pumpSec > lastCgmPumpSec` is false) — must not reschedule.
        backend.injectStatusFrameForTesting(Self.currentEgvV1Frame(pumpSec: 1010, mgdl: 121))
        #expect(backend.predictiveBurstDeadlineForTesting == deadlineAfterFirst,
                "a reading whose pump timestamp does not advance must not reschedule the burst")
    }

    @Test func runPredictiveBurstDoesNotDispatchWhenNotConnected() {
        let (backend, _) = makeBackend()
        backend.setConnectionForTesting(.disconnected)
        var dispatched: [UInt8] = []
        backend.onReadDispatchedForTesting = { _, opcode in dispatched.append(opcode) }
        backend.simulatePredictiveBurstForTesting()
        #expect(dispatched.isEmpty,
                "runPredictiveBurst() must not dispatch its EGV kick while disconnected (one of its two documented stop conditions)")
    }
}
