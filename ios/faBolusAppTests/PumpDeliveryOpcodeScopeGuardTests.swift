import Testing
import Foundation
import TandemMessages
import TandemBLE
@testable import faBolus

/// `badOpcodes` may suppress currentStatus reads only — never a delivery/control write — even when
/// the same raw opcode is reused across characteristics (op164/op144).
@Suite(.serialized) @MainActor
struct PumpDeliveryOpcodeScopeGuardTests {

    private func scheduler() -> PumpReadScheduler { PumpReadScheduler() }

    // MARK: - The exclusion set is well-formed and disjoint from the read set (by construction)

    /// The exclusion set covers the bolus lifecycle + the insulin-affecting control writes that DON'T
    /// collide with a read opcode.
    @Test func exclusionSetCoversTheCoreDeliveryAndControlWrites() {
        let excl = PumpReadCatalog.deliveryControlWriteOpcodes
        #expect(excl.contains(InitiateBolusRequest.props.opCode))  // op-158
        #expect(excl.contains(BolusPermissionRequest.props.opCode))  // op-162
        #expect(excl.contains(BolusPermissionReleaseRequest.props.opCode))  // op-240
        #expect(excl.contains(CancelBolusRequest.props.opCode))  // op-160
        #expect(excl.contains(SuspendPumpingRequest.props.opCode))  // op-156
        #expect(excl.contains(ResumePumpingRequest.props.opCode))  // op-154
        #expect(excl.contains(StopTempRateRequest.props.opCode))  // op-166
        #expect(excl.contains(SetModesRequest.props.opCode))  // op-204
        #expect(excl.contains(EnterFillTubingModeRequest.props.opCode))  // op-148
        #expect(excl.contains(FillCannulaRequest.props.opCode))  // op-152
        #expect(!excl.isEmpty)
    }

    /// THE core "can't intersect by construction" assertion: the exclusion set and the read opcode set — the
    /// only opcodes that may legitimately enter `badOpcodes` — are DISJOINT.
    @Test func exclusionSetIsDisjointFromEveryCurrentStatusRead() {
        #expect(
            PumpReadCatalog.deliveryControlWriteOpcodes
                .isDisjoint(with: PumpReadCatalog.currentStatusReadOpcodes),
            "the read-only never-resend set and the delivery/control-write set must be disjoint")
    }

    /// The dose-input READ allowlist (op108 IOB / op115 therapy) must be disjoint from the
    /// delivery/control-WRITE guard set and a subset of the currentStatus read set, so the write
    /// fail-closed guardrail and the dose-input re-probe allowlist cannot reclassify each other.
    @Test func doseInputReadSetIsDisjointFromDeliveryWritesAndIsASubsetOfReads() {
        #expect(!PumpReadCatalog.doseInputReadOpcodes.isEmpty)
        #expect(
            PumpReadCatalog.doseInputReadOpcodes
                .isDisjoint(with: PumpReadCatalog.deliveryControlWriteOpcodes),
            "the dose-input read allowlist and the delivery/control-write guard set must be DISJOINT")
        #expect(
            PumpReadCatalog.doseInputReadOpcodes
                .isSubset(of: PumpReadCatalog.currentStatusReadOpcodes),
            "dose-input reads are currentStatus reads — they live in the read space, not the write space")
    }

    /// The read-colliding opcodes (op164 SetTempRate ↔ LastBolusStatusV2, op144 EnterChangeCartridge ↔
    /// CurrentBatteryV2) are DELIBERATELY excluded from the guard set, and are `.control` writes vs
    /// `.currentStatus` reads — documenting why a raw-value denylist would be wrong and why the collision is
    /// safe (characteristic isolation).
    @Test func readCollidingWriteOpcodesAreNotInTheGuardSetAndAreControlCharacteristic() {
        let tempRate = SetTempRateRequest.props.opCode
        let enterCartridge = EnterChangeCartridgeModeRequest.props.opCode
        #expect(tempRate == LastBolusStatusV2Request.props.opCode)  // proven collision (op-164)
        #expect(enterCartridge == CurrentBatteryV2Request.props.opCode)  // proven collision (op-144)
        #expect(!PumpReadCatalog.deliveryControlWriteOpcodes.contains(tempRate))
        #expect(!PumpReadCatalog.deliveryControlWriteOpcodes.contains(enterCartridge))
        // The WRITE twins are on `.control`; the READ twins on `.currentStatus` (badOpcodes is a read gate).
        #expect(SetTempRateRequest.props.characteristic == .control)
        #expect(EnterChangeCartridgeModeRequest.props.characteristic == .control)
        #expect(LastBolusStatusV2Request.props.characteristic == .currentStatus)
        #expect(CurrentBatteryV2Request.props.characteristic == .currentStatus)
    }

    // MARK: - insertBadOpcode refuses every delivery/control-write opcode

    @Test func insertBadOpcodeRefusesEveryDeliveryControlWriteOpcode() {
        let s = scheduler()
        for op in PumpReadCatalog.deliveryControlWriteOpcodes { s.insertBadOpcode(op) }
        #expect(
            s.badOpcodesForTesting.isDisjoint(with: PumpReadCatalog.deliveryControlWriteOpcodes),
            "a delivery/control-write opcode must never be recorded in the read-only never-resend set")
        #expect(s.badOpcodesForTesting.isEmpty, "nothing but delivery opcodes was offered — none may stick")
    }

    /// A colliding opcode (op164) offered to insertBadOpcode is still recorded — because it is a legitimate
    /// READ (LastBolusStatusV2). The guardrail must not over-block reads.
    @Test func insertBadOpcodeStillLearnsAReadCollidingOpcodeAsABadRead() {
        let s = scheduler()
        s.insertBadOpcode(LastBolusStatusV2Request.props.opCode)  // op-164, a currentStatus read
        #expect(
            s.badOpcodesForTesting.contains(LastBolusStatusV2Request.props.opCode),
            "a read-colliding opcode must remain learnable as a bad READ — the guard is not over-broad")
    }

    // MARK: - resolveErrorResponse's insert path can't record a delivery opcode

    /// An op77 whose cargo NAMES a delivery opcode (`requestCodeId != 0`) must NOT poison `badOpcodes`:
    /// resolveErrorResponse returns it for the diagnostic log but never suppresses it.
    @Test func resolveErrorResponseNeverRecordsANamedDeliveryOpcode() {
        let s = scheduler()
        let initiate = InitiateBolusRequest.props.opCode  // op-158, pure delivery
        let resolved = s.resolveErrorResponse(requestCodeId: Int(initiate), txId: 0)
        #expect(resolved == initiate, "the named opcode is still returned for the standing diagnostic log")
        #expect(
            !s.badOpcodesForTesting.contains(initiate),
            "a delivery opcode named in an op77 cargo must never enter the never-resend set")
    }

    /// The FIFO/txId correlation path can only ever resolve to a READ (it consults `outstandingReads`, which
    /// only records reads sent via `sendStatusRead`) — a delivery write, sent on the coordinator path, is
    /// never in that map, so an opcode-less op77 can never correlate to a delivery command.
    @Test func fifoCorrelationOnlyEverResolvesToAnOutstandingRead() {
        let s = scheduler()
        // No outstanding reads recorded, opcode-less cargo → nothing to correlate → resolves to 0 (inert),
        // and definitely not to any delivery opcode.
        let resolved = s.resolveErrorResponse(requestCodeId: 0, txId: 9)
        #expect(resolved == 0)
        #expect(s.badOpcodesForTesting.isDisjoint(with: PumpReadCatalog.deliveryControlWriteOpcodes))
    }

    // MARK: - Durable hydration can't inject a delivery opcode into badOpcodes

    /// Even if the persistent store somehow held a delivery opcode (a foreign/legacy entry), the
    /// `startPolling` hydration union must filter it — the union bypasses `insertBadOpcode`, so the filter
    /// there is what keeps `badOpcodes` reads-only.
    @Test func startPollingHydrationFiltersDeliveryOpcodes() {
        let s = scheduler()
        let initiate = InitiateBolusRequest.props.opCode
        let cartridgeRead = LoadStatusRequest.props.opCode  // op-20, a legitimate read
        s.loadPersistedBadOpcodes = { [initiate, cartridgeRead] }
        s.startPollingForTesting()
        #expect(
            !s.badOpcodesForTesting.contains(initiate),
            "a persisted delivery opcode must be filtered out of the hydration union")
        #expect(
            s.badOpcodesForTesting.contains(cartridgeRead),
            "a legitimately persisted READ opcode must still hydrate into the never-resend set")
    }
}
