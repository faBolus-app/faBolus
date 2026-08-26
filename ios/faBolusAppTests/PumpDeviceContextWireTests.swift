import Testing
import Foundation
import faBolusCore
import TandemMessages
@testable import faBolus

/// **VA-06 (op33 device-context re-wire).** Pins that `PumpResponseApplier` re-wires the kit's
/// device-support MODEL gate every connection cycle, off the op33 `ApiVersionResponse`.
///
/// WHY op33 is the re-wire point: the kit's `client.setDeviceContext(model:)` resets to nil on every link
/// change, and `didDiscover` does NOT re-fire on a silent reconnect — so a bare `.connected` after a
/// background disconnect would leave the model gate un-set, and a Mobi-only / t:slim-only write would be
/// mis-gated. op33 arrives on every connection cycle's bootstrap read, so routing the re-wire through it
/// makes the gate survive a silent reconnect.
///
/// The applier calls `applyDeviceContext(detectedIsMobi() ?? m.isMobi)` (PumpResponseApplier.swift): the
/// BLE-name detection (`detectedIsMobi`, set at discovery) is authoritative and WINS over the op33
/// API-version heuristic; the heuristic (`ApiVersionResponse.isMobi`, true at API 3.5+) is the fallback
/// used only when the name did not identify the model. Both closures are ConnectIQ/BLE-free injected
/// seams, so this drives the REAL applier dispatch (`apply(_:txId:characteristic:)`) directly — no
/// CoreBluetooth, no TandemBackend — mirroring the injected-hook test pattern the applier was built for.
@Suite(.serialized) @MainActor
struct PumpDeviceContextWireTests {

    /// op33 cargo is majorVersion short@0 + minorVersion short@2 (little-endian) — the same layout
    /// `FakePumpTransport.apiVersion(major:minor:)` frames. isMobi is derived: `major > 3 || (major == 3
    /// && minor >= 5)`. 3.5 ⇒ Mobi; 2.5 ⇒ t:slim X2.
    private func apiVersion(major: Int, minor: Int) -> ApiVersionResponse {
        ApiVersionResponse(cargo: Bytes.firstTwoBytesLittleEndian(major) + Bytes.firstTwoBytesLittleEndian(minor))
    }

    /// When the BLE name did NOT identify the model (`detectedIsMobi() == nil`), `applyDeviceContext`
    /// falls back to the op33 API-version heuristic — invoked with the message's own `isMobi`.
    @Test func fallsBackToApiHeuristicWhenNameUnknown() {
        // Mobi API version (3.5) with no name detection ⇒ heuristic says Mobi.
        do {
            let applier = PumpResponseApplier()
            var captured: Bool?
            var trusted: Bool?
            applier.detectedIsMobi = { nil }
            applier.applyDeviceContext = { captured = $0; trusted = $1 }
            let mobi = apiVersion(major: 3, minor: 5)
            #expect(mobi.isMobi, "3.5 is the Mobi threshold")
            applier.apply(mobi, txId: 0, characteristic: .currentStatus)
            #expect(captured == true, "name unknown ⇒ device context uses the op33 heuristic (Mobi)")
            #expect(trusted == false, "CC-06/C1: the op33 heuristic is NEVER forwarded as trusted")
        }
        // t:slim X2 API version (2.5) with no name detection ⇒ heuristic says NOT Mobi.
        do {
            let applier = PumpResponseApplier()
            var captured: Bool?
            var trusted: Bool?
            applier.detectedIsMobi = { nil }
            applier.applyDeviceContext = { captured = $0; trusted = $1 }
            let tslim = apiVersion(major: 2, minor: 5)
            #expect(!tslim.isMobi, "2.5 is t:slim X2, not Mobi")
            applier.apply(tslim, txId: 0, characteristic: .currentStatus)
            #expect(captured == false, "name unknown ⇒ device context uses the op33 heuristic (t:slim)")
            #expect(trusted == false, "CC-06/C1: the op33 heuristic is NEVER forwarded as trusted")
        }
    }

    /// The BLE-name detection WINS over the op33 API-version heuristic: when `detectedIsMobi()` returns a
    /// non-nil value, `applyDeviceContext` is called with THAT value even when the message's own `isMobi`
    /// disagrees.
    @Test func bleNameDetectionWinsOverApiHeuristic() {
        // Name says Mobi, but the op33 frame's heuristic says t:slim (2.5) — the name must win.
        do {
            let applier = PumpResponseApplier()
            var captured: Bool?
            var trusted: Bool?
            applier.detectedIsMobi = { true }
            applier.applyDeviceContext = { captured = $0; trusted = $1 }
            let tslimByApi = apiVersion(major: 2, minor: 5)
            #expect(!tslimByApi.isMobi, "the heuristic alone would say NOT Mobi")
            applier.apply(tslimByApi, txId: 0, characteristic: .currentStatus)
            #expect(captured == true, "name-detected Mobi must win over the op33 API heuristic")
            #expect(trusted == true, "CC-06/C1: a name-derived value (fresh or C8-reapplied) is trusted")
        }
        // Name says t:slim, but the op33 frame's heuristic says Mobi (3.5) — the name must win.
        do {
            let applier = PumpResponseApplier()
            var captured: Bool?
            var trusted: Bool?
            applier.detectedIsMobi = { false }
            applier.applyDeviceContext = { captured = $0; trusted = $1 }
            let mobiByApi = apiVersion(major: 3, minor: 5)
            #expect(mobiByApi.isMobi, "the heuristic alone would say Mobi")
            applier.apply(mobiByApi, txId: 0, characteristic: .currentStatus)
            #expect(captured == false, "name-detected t:slim must win over the op33 API heuristic")
            #expect(trusted == true, "CC-06/C1: a name-derived value (fresh or C8-reapplied) is trusted")
        }
    }
}
