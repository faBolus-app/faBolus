import Foundation
import PumpScript
import TandemLink
import TandemMessages
import Testing

@testable import PumpSession
@testable import faBolusCore

private let key = RemoteBolusLedger.Key(peerId: "phone", requestId: "phone-1")

/// The 6-digit (J-PAKE) pairing run over the wire against the scripted pump's J-PAKE side: the link's
/// pairing coordinator, the derived secret it stores, and the signing key it derives, used by a bolus.
@MainActor
@Suite struct JpakePairingTests {
    private func jpakePump(_ pump: ScriptedPump) {
        pump.unsupportedReads = []
        pump.jpakeCode = "123456"
        pump.apiVersion = (4, 0)
    }

    private func pair(_ rig: Rig, code: String) async throws {
        try await rig.session.pair(
            peripheralID: ScriptedPump.peripheralID, advertisedName: "tslim X2 ***693", code: code)
        await rig.run(for: 3, step: 0.5)
    }

    /// The code is right: the pairing completes on the wire, the pump and the app keep the same derived
    /// secret, the pairing is stored, and a signed bolus with the derived key is delivered.
    @Test func aJpakePairingCompletesAndItsKeySignsABolus() async throws {
        let rig = Rig(paired: false, configure: jpakePump)
        await rig.start()
        try await pair(rig, code: "123-456")
        let secret = try #require(rig.pump.jpakeSecret)
        #expect(secret.count == 32)
        #expect(PairingSecrets(store: rig.secrets).credentials(for: .jpake) == .jpakeResume(derivedSecret: secret))
        #expect(rig.store.load()?.pairing?.scheme == .jpake)
        #expect(await rig.session.state.link == .connected)

        await rig.run(for: 11, step: 1)
        #expect(await rig.session.deliver(composed(0.5)) == .started(key, .delivering))
        await rig.run(for: rig.pump.deliverySeconds(milliunits: 500) + 5)
        #expect(await rig.session.ledger.ledger.outcome(key) == .delivered(units: 0.5))
    }

    /// The wrong code: the key confirmation fails, nothing is stored, and the pump keeps no secret.
    @Test func aWrongCodeIsRejectedAndNothingIsKept() async throws {
        let rig = Rig(paired: false, configure: jpakePump)
        await rig.start()
        try await pair(rig, code: "654-321")
        #expect(rig.pump.jpakeSecret == nil)
        #expect(rig.store.load()?.pairing == nil)
        #expect(PairingSecrets(store: rig.secrets).credentials(for: .jpake) == nil)
        #expect(await rig.session.state.link != .connected)
        #expect(!rig.pump.arrivals(of: Jpake4KeyConfirmationRequest.self).isEmpty)
    }

    /// The next launch reconnects with only the stored secret (rounds 3 and 4), and its new key signs a
    /// bolus; a stored secret the pump doesn't have is refused.
    @Test func aReconnectConfirmsWithTheKeptSecretOnly() async throws {
        let first = Rig(paired: false, configure: jpakePump)
        await first.start()
        try await pair(first, code: "123456")
        let secret = try #require(first.pump.jpakeSecret)
        let record = try #require(first.store.load())
        await first.stop()

        let next = Rig(
            paired: false, record: record,
            configure: {
                jpakePump($0)
                $0.jpakeSecret = secret
            })
        try PairingSecrets(store: next.secrets).store(.jpakeResume(derivedSecret: secret))
        await next.start()
        await next.run(for: 12, step: 1)
        #expect(await next.session.state.link == .connected)
        #expect(next.pump.arrivals(of: Jpake1aRequest.self).isEmpty)
        #expect(!next.pump.arrivals(of: Jpake3SessionKeyRequest.self).isEmpty)
        #expect(await next.session.deliver(composed(0.5)) == .started(key, .delivering))

        let stranger = Rig(
            paired: false, record: record,
            configure: {
                jpakePump($0)
                $0.jpakeSecret = [UInt8](repeating: 9, count: 32)
            })
        try PairingSecrets(store: stranger.secrets).store(.jpakeResume(derivedSecret: secret))
        await stranger.start()
        await stranger.run(for: 5, step: 1)
        #expect(await stranger.session.state.link != .connected)
        #expect(!stranger.pump.arrivals(of: Jpake4KeyConfirmationRequest.self).isEmpty)
        #expect(stranger.pump.jpakeSecret == [UInt8](repeating: 9, count: 32))
        #expect(stranger.pump.arrivals(of: InitiateBolusRequest.self).isEmpty)
    }
}
