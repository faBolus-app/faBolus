import Foundation
import PumpScript
import TandemLink
import TandemMessages
import Testing

@testable import PumpSession
@testable import faBolusCore

@MainActor
@Suite struct PairingTests {
    @Test func pairsAndStoresThePairingOnceThePumpIdentifiesItself() async throws {
        let rig = Rig(paired: false, configure: { $0.unsupportedReads = [] })
        await rig.start()
        await rig.session.scanForPairing()
        await rig.settle()
        let found = await rig.events.compactMap { e -> (UUID, String?)? in
            if case .pumpFound(let id, let name, .tslimX2) = e { return (id, name) }
            return nil
        }
        let pump = try #require(found.first)
        #expect(rig.store.load()?.pairing == nil)
        try await rig.session.pair(peripheralID: pump.0, advertisedName: pump.1, code: "ABCD-EFGH-IJKL-MNOP")
        await rig.settle()
        let pairing = try #require(rig.store.load()?.pairing)
        #expect(pairing.peripheralID == ScriptedPump.peripheralID)
        #expect(pairing.model == .tslimX2)
        #expect(pairing.scheme == .legacy)
        #expect(pairing.trustedSerial == 1693)
        #expect(PairingSecrets(store: rig.secrets).credentials(for: .legacy) == .legacy(code: ScriptedPump.code))
        #expect(await rig.session.state.link == .connected)
    }

    /// This release doesn't pair with a Mobi: refused before anything is sent.
    @Test func aMobiIsRefusedAtPairing() async {
        let rig = Rig(paired: false)
        await rig.start()
        await #expect(throws: PumpSession.PairingRefusal.mobiNotSupported) {
            try await rig.session.pair(
                peripheralID: ScriptedPump.peripheralID, advertisedName: "Tandem Mobi 1234", code: "123456")
        }
        #expect(!rig.transport.commands.contains(.connect(ScriptedPump.peripheralID)))
        #expect(rig.store.load()?.pairing == nil)
    }

    @Test func aPumpThatDoesntNameItsModelIsRefused() async {
        let rig = Rig(paired: false)
        await rig.start()
        await #expect(throws: PumpSession.PairingRefusal.unknownModel) {
            try await rig.session.pair(peripheralID: ScriptedPump.peripheralID, advertisedName: "pump", code: "123456")
        }
    }

    @Test func aRejectedCodeStoresNothing() async {
        let rig = Rig(paired: false, configure: { $0.rejectsPairing = true })
        await rig.start()
        try? await rig.session.pair(
            peripheralID: ScriptedPump.peripheralID, advertisedName: "tslim X2 ***693", code: ScriptedPump.code)
        await rig.settle()
        #expect(await rig.events.contains(.linkFailed(.pairingRejected)))
        #expect(rig.store.load()?.pairing == nil)
        #expect(rig.secrets.secret(for: PairingSecrets.account) == nil)
    }

    @Test func forgettingThePumpClosesTheLinkAndRemovesThePairing() async {
        var saved = RemoteBolusLedger()
        _ = saved.begin(DoseRequest(id: "a", origin: .phone, shape: .now(units: 1)))
        saved.markAccepted(.init(peerId: "phone", requestId: "a"), bolusId: 5, pumpKey: "tandem|1693")
        let rig = Rig(ledger: saved, configure: { $0.unsupportedReads = [] })
        await rig.start()
        await rig.session.forgetPairing()
        await rig.settle()
        #expect(rig.connection.state.phase == .idle)
        #expect(rig.store.load()?.pairing == nil)
        #expect(rig.secrets.secret(for: PairingSecrets.account) == nil)
        #expect(await rig.session.state.link == .disconnected)
        // The unknown outcome stays: the forgotten pump's history can no longer settle it.
        #expect(await rig.ledger.ledger.unknownOutcomes.count == 1)
    }

    @Test func pairingCodesOfEitherKindAreRecognized() {
        for code in ["123456", "123-456", "123 456"] {
            #expect(PumpPairingCode.scheme(code) == .jpake, "\(code)")
        }
        for code in ["abcd1234ijkl5678", "abcd-1234-ijkl-5678", "1234567890abcdef"] {
            #expect(PumpPairingCode.scheme(code) == .legacy, "\(code)")
        }
        for code in ["", "123", "12345", "1234567", "abcd1234ijkl567"] {
            #expect(!PumpPairingCode.isValid(code), "\(code)")
        }
    }

    /// One account holds the secret, so a new pairing of either kind replaces the old one; a stored secret
    /// of the other kind is never used.
    @Test func theStoredSecretIsOneKindAndOnlyThatKindIsUsed() throws {
        let store = MemorySecrets()
        let secrets = PairingSecrets(store: store)
        try secrets.store(.legacy(code: "ABCDEFGHIJKLMNOP"))
        #expect(secrets.credentials(for: .legacy) == .legacy(code: "ABCDEFGHIJKLMNOP"))
        #expect(secrets.credentials(for: .jpake) == nil)
        try secrets.store(.jpakeResume(derivedSecret: [1, 2, 3]))
        #expect(secrets.credentials(for: .jpake) == .jpakeResume(derivedSecret: [1, 2, 3]))
        #expect(secrets.credentials(for: .legacy) == nil)
        try secrets.store(.jpake(code: "123456"))  // a first JPAKE code isn't kept
        #expect(secrets.credentials(for: .jpake) == .jpakeResume(derivedSecret: [1, 2, 3]))
        try secrets.clear()
        #expect(store.secret(for: PairingSecrets.account) == nil)
    }
}

/// Nothing that could deliver goes to a pump that hasn't identified itself as the paired t:slim X2.
@MainActor
@Suite struct PreIdentitySendContractTests {
    /// No read the session sends is restricted to a model, so none is ever held up or refused for an
    /// identity the pump hasn't reported yet.
    @Test func noReadTheSessionSendsIsModelRestricted() {
        var reads = ReadGroup.allCases.flatMap(\.reads)
        reads += [
            TimeSinceResetRequest(), HistoryLogStatusRequest(), HistoryLogRequest(startLog: 0, numberOfLogs: 1),
            LastBolusStatusV2Request(), CurrentBolusStatusRequest()
        ]
        #expect(!reads.isEmpty)
        for read in reads {
            #expect(type(of: read).props.supportedDevices == nil, "\(type(of: read))")
            #expect(!read.signed, "\(type(of: read))")
        }
    }

    @Test func nothingIsDeliveredBeforeThePumpIsConnected() async {
        let rig = Rig(paired: false)
        await rig.start()
        #expect(await rig.session.deliver(composed(1.0)) == .notStarted(.notConnected))
        #expect(await rig.ledger.ledger.allEntries.isEmpty)
    }

    /// A different pump answering for the pairing (another serial) is never read or dosed: the link is
    /// closed.
    @Test func aDifferentSerialUnderThePairingClosesTheLink() async {
        let rig = Rig(configure: { $0.serialNumber = 9999 })
        await rig.start()
        #expect(await rig.events.contains(.linkFailed(.identityMismatch)))
        #expect(rig.connection.state.phase == .idle)
        #expect(await rig.session.deliver(composed(1.0)) == .notStarted(.notConnected))
        #expect(rig.pump.arrivals.filter { $0.characteristic == .control }.isEmpty)
    }

    /// A pairing stored before the serial was known trusts the first serial it sees.
    @Test func aPairingWithoutASerialTrustsTheFirstOneSeen() async {
        var pairing = Rig.pairing
        pairing.trustedSerial = nil
        let rig = Rig(record: PumpSessionRecord(pairing: pairing), configure: { $0.unsupportedReads = [] })
        await rig.start()
        #expect(rig.store.load()?.pairing?.trustedSerial == 1693)
        #expect(await rig.session.identityTrusted)
    }
}

@MainActor
@Suite struct AlertTests {
    @Test func thePumpsAlertsAreReadAndMapped() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.alertBitmap = 1 << 7
        })
        await rig.start()
        let alerts = await rig.session.state.alerts?.value ?? []
        #expect(alerts.count == 1)
        #expect(alerts.first?.id == 7)
        #expect(alerts.first?.kind == .alert)
        #expect(alerts.first?.title == "Power source")
        #expect(alerts.first?.isDismissable == true)
        #expect(
            await rig.events.contains {
                if case .alertsChanged(let a) = $0 { return a.count == 1 }
                return false
            })
    }

    /// An alarm and a malfunction on the same bit are two alerts; the malfunction can't be dismissed and
    /// nothing is sent for it.
    @Test func aMalfunctionIsItsOwnAlertAndIsNeverSentADismiss() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.alarmBitmap = 1 << 5
            $0.malfunctionBitmap = 1 << 5
        })
        await rig.startHeld()
        let alerts = await rig.session.state.alerts?.value ?? []
        #expect(alerts.count == 2)
        let malfunction = alerts.first { $0.isMalfunction }
        #expect(malfunction?.isDismissable == false)
        #expect(malfunction?.severity == .critical)
        if let malfunction { #expect(await rig.session.dismiss(malfunction) == .unsupported) }
        #expect(rig.pump.arrivals(of: DismissNotificationRequest.self).isEmpty)
    }

    @Test func dismissClearsOnTheAuthenticatedReplyAndTheAlertGoes() async throws {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.alertBitmap = 1 << 7
        })
        await rig.startHeld()
        let alert = try #require(await rig.session.state.alerts?.value.first)
        let session = rig.session
        let dismiss = Task { await session.dismiss(alert) }
        await rig.run(for: 2)
        #expect(await dismiss.value == .cleared)
        let sent = try #require(rig.pump.arrivals(of: DismissNotificationRequest.self).first)
        #expect(Array(sent.cargo.prefix(5)) == [7, 0, 0, 0, 1])
        #expect(await rig.session.state.alerts?.value.isEmpty == true)
        #expect(await rig.events.contains(.alertDismissed(alert, .cleared)))
    }

    @Test func aPumpThatRejectsTheOpcodeSaysUnsupported() async throws {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.alertBitmap = 1 << 7
            $0.answers[MessageKey(DismissNotificationRequest.self)] = .error(code: 6, drops: false)
        })
        await rig.startHeld()
        let alert = try #require(await rig.session.state.alerts?.value.first)
        let session = rig.session
        let dismiss = Task { await session.dismiss(alert) }
        await rig.run(for: 2)
        #expect(await dismiss.value == .unsupported)
    }

    /// No authenticated answer: unconfirmed, and the alert stays shown.
    @Test func noAnswerIsUnconfirmedAndTheAlertStays() async throws {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.alertBitmap = 1 << 7
            $0.answers[MessageKey(DismissNotificationRequest.self)] = .silent
        })
        await rig.startHeld()
        let alert = try #require(await rig.session.state.alerts?.value.first)
        let session = rig.session
        let dismiss = Task { await session.dismiss(alert) }
        await rig.run(for: 12)
        #expect(await dismiss.value == .unconfirmed)
        #expect(await rig.session.state.alerts?.value.count == 1)
    }
}

@MainActor
@Suite struct PairingRecoveryTests {
    /// A pairing that fails leaves the pump paired before as it was, and the session goes back to it.
    @Test func aFailedPairingReconnectsToTheStoredPump() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.start()
        // Pairing another pump; it rejects the code.
        try? await rig.session.pair(
            peripheralID: UUID(), advertisedName: "tslim X2 ***111", code: "ZZZZ-ZZZZ-ZZZZ-ZZZZ")
        await rig.session.handle(.phase(.failed(.authenticationRejected)))
        await rig.settle()
        #expect(await rig.events.contains(.linkFailed(.pairingRejected)))
        #expect(rig.connection.state.target?.credentials == .legacy(code: ScriptedPump.code))
        #expect(await rig.session.state.link == .connected)
        #expect(rig.store.load()?.pairing == Rig.pairing)
    }

    /// A JPAKE pairing stores the derived secret and the pairing it belongs to together, the moment the
    /// pump reports it; the next launch reconnects with the secret, and the serial is trusted when seen.
    @Test func aJpakePairingStoresTheSecretAndThePairingTogether() async throws {
        let rig = Rig(paired: false)
        await rig.start()
        try await rig.session.pair(
            peripheralID: ScriptedPump.peripheralID, advertisedName: "tslim X2 ***693", code: "123-456")
        await rig.session.handle(.paired(.jpakeResume(derivedSecret: [1, 2, 3])))
        let pairing = try #require(rig.store.load()?.pairing)
        #expect(pairing.scheme == .jpake)
        #expect(pairing.trustedSerial == nil)
        #expect(PairingSecrets(store: rig.secrets).credentials(for: .jpake) == .jpakeResume(derivedSecret: [1, 2, 3]))
        await rig.stop()

        let next = Rig(paired: false, record: rig.store.load())
        try PairingSecrets(store: next.secrets).store(.jpakeResume(derivedSecret: [1, 2, 3]))
        await next.start()
        #expect(next.connection.state.target?.credentials == .jpakeResume(derivedSecret: [1, 2, 3]))
    }
}
