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

    /// Looking for a new pump closes the link to the paired one; leaving without pairing, or the scan
    /// finding nothing, goes back to it.
    @Test func aPairingScanThatEndsWithoutPairingReconnectsThePairedPump() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.start()
        await rig.settle()
        #expect(await rig.session.state.link == .connected)
        await rig.session.scanForPairing()
        await rig.settle()
        #expect(await rig.session.state.link != .connected)
        await rig.session.endPairingScan()
        await rig.settle()
        #expect(await rig.session.state.link == .connected)

        await rig.session.scanForPairing()
        await rig.settle()
        await rig.run(for: 40, step: 1)
        #expect(await rig.session.state.link == .connected)

        // Leaving while a pairing is under way abandons it: the stored pairing is the one kept.
        let before = rig.store.load()?.pairing
        await rig.session.scanForPairing()
        await rig.settle()
        // A 6-digit code: the scripted pump only knows the long one, so this pairing stays under way.
        try? await rig.session.pair(
            peripheralID: ScriptedPump.peripheralID, advertisedName: "tslim X2 ***693", code: "123456")
        await rig.session.endPairingScan()
        await rig.settle()
        #expect(rig.store.load()?.pairing == before)
        #expect(await rig.session.state.link == .connected)
        await rig.stop()
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
        await rig.startHeld()
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

    /// A clear asked for before the pump is reachable (a notification's Clear that launched the app) waits
    /// for it, then goes the same way as from the app: sent, answered, the alert gone.
    @Test func aClearBeforeTheLinkIsUpWaitsForItThenClears() async throws {
        let configure: (ScriptedPump) -> Void = {
            $0.unsupportedReads = []
            $0.alertBitmap = 1 << 7
        }
        let first = Rig(configure: configure)
        await first.startHeld()
        let alert = try #require(await first.session.state.alerts?.value.first)
        await first.stop()

        let relaunched = Rig(record: first.store.load(), configure: configure)
        let session = relaunched.session
        let dismiss = Task { await session.dismiss(alert, waitingForLinkUpTo: 20) }
        await relaunched.start()
        await relaunched.run(for: 12, step: 1)
        #expect(await dismiss.value == .cleared)
        #expect(relaunched.pump.arrivals(of: DismissNotificationRequest.self).count == 1)
        await relaunched.stop()
    }

    /// A pump that doesn't become reachable in time: nothing is sent, and the clear says so.
    @Test func aClearWhoseLinkNeverComesIsUnconfirmedAfterTheWait() async throws {
        let rig = Rig(paired: false)
        await rig.start()
        let session = rig.session
        let alert = PumpAlert(id: 7, kind: .alert, title: "Low insulin", remoteClear: .tryable)
        let clock = rig.clock
        let asked = clock.date
        let dismiss = Task { (await session.dismiss(alert, waitingForLinkUpTo: 20), clock.date) }
        await rig.run(for: 25, step: 1)
        let (outcome, answeredAt) = await dismiss.value
        #expect(outcome == .unconfirmed)
        #expect(answeredAt.timeIntervalSince(asked) >= 20, "it waited for the pump first")
        #expect(rig.pump.arrivals(of: DismissNotificationRequest.self).isEmpty)
        await rig.stop()
    }

    /// A new pairing is stored without waiting on a history sync: "Sync history now" asked for again and
    /// again while the new pump is being identified never holds the pairing up (a sync needs a trusted
    /// pump, and the pump is trusted only once the pairing is in place).
    @Test func aSyncAskedForDuringANewPairingDoesntHoldItUp() async throws {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        let before = try #require(rig.store.load()?.pairing)
        let session = rig.session
        await session.scanForPairing()
        await rig.settle()
        try await session.pair(
            peripheralID: ScriptedPump.peripheralID, advertisedName: "tslim X2 ***693", code: ScriptedPump.code)
        let start = rig.clock.date
        var stored: StoredPairing?
        for _ in 0..<200 {
            Task { await session.syncHistory() }
            await rig.run(for: 0.1, step: 0.1)
            if let p = rig.store.load()?.pairing, p.pairedAt != before.pairedAt {
                stored = p
                break
            }
        }
        let pairing = try #require(stored, "the new pairing was stored")
        #expect(pairing.pairedAt.timeIntervalSince(start) < 2, "stored without waiting on a sync")
        await rig.stop()
    }

    private static let tslimAPI25 = PumpClass(model: .tslim, apiVersion: ApiVersion(major: 2, minor: 5))

    private static func classKnown(_ answer: RemoteClearEvidence) -> PumpSession.Configuration {
        var c = PumpSession.Configuration()
        c.remoteClearClasses = [tslimAPI25: answer]
        return c
    }

    /// A class known to clear: the alert can be cleared remotely, a clear just clears, and no trial is
    /// recorded. These hold once the trial is gone.
    @Test func aClassKnownToClearIsAvailableWithNothingRecorded() async throws {
        let rig = Rig(
            configure: {
                $0.unsupportedReads = []
                $0.alertBitmap = 1 << 7
            }, configuration: Self.classKnown(.clears))
        await rig.startHeld()
        let alert = try #require(await rig.session.state.alerts?.value.first)
        #expect(alert.remoteClear == .available)
        let session = rig.session
        let dismiss = Task { await session.dismiss(alert) }
        await rig.run(for: 2)
        #expect(await dismiss.value == .cleared)
        #expect(rig.store.load()?.remoteClearTrials.isEmpty == true)
    }

    /// A class known not to clear: clear it on the pump, and nothing is sent.
    @Test func aClassKnownNotToClearIsUnavailableAndNothingIsSent() async throws {
        let rig = Rig(
            configure: {
                $0.unsupportedReads = []
                $0.alertBitmap = 1 << 7
            }, configuration: Self.classKnown(.doesNotClear))
        await rig.startHeld()
        let alert = try #require(await rig.session.state.alerts?.value.first)
        #expect(alert.remoteClear == .unavailable)
        #expect(await rig.session.dismiss(alert) == .unsupported)
        #expect(rig.pump.arrivals(of: DismissNotificationRequest.self).isEmpty)
    }

    /// The trial: with nothing known for the class, the phone may try. The reads after its clear decide it
    /// for the unit: an alert still showing after "cleared" is reported as not cleared at once, and once a
    /// routine read after the settle still shows it, the pump's alerts can't be cleared remotely; one that
    /// went makes them clearable.
    @Test func theTrialDecidesFromTheReadsAfterTheClear() async throws {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.alertBitmap = 1 << 7
            $0.dismissLeavesAlert = true
        })
        await rig.startHeld()
        let session = rig.session
        let alert = try #require(await session.state.alerts?.value.first)
        #expect(alert.remoteClear == .tryable)
        #expect(await session.remoteClearTrialResult == nil)
        let dismiss = Task { await session.dismiss(alert) }
        await rig.run(for: 2)
        #expect(await dismiss.value == .notCleared)
        #expect(await session.remoteClearTrialResult == nil)
        await rig.run(for: 30, step: 5)
        #expect(await session.remoteClearTrialResult == .doesNotClear)
        #expect(await session.state.alerts?.value.map(\.remoteClear) == [.unavailable])
        #expect(await rig.events.contains(.alertDismissed(alert, .notCleared)))

        let clears = Rig(configure: {
            $0.unsupportedReads = []
            $0.alertBitmap = 1 << 7 | 1 << 8
        })
        await clears.startHeld()
        let first = try #require(await clears.session.state.alerts?.value.first)
        let other = clears.session
        let cleared = Task { await other.dismiss(first) }
        await clears.run(for: 2)
        #expect(await cleared.value == .cleared)
        #expect(await other.remoteClearTrialResult == .clears)
        #expect(await other.state.alerts?.value.map(\.remoteClear) == [.available])
    }

    /// A pump that drops the alert a moment after answering hasn't shown that it ignores a clear: nothing is
    /// recorded, and the phone may try again.
    @Test func anAlertThatGoesLateRecordsNothing() async throws {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.alertBitmap = 1 << 7
            $0.dismissLeavesAlert = true
        })
        await rig.startHeld()
        let session = rig.session
        let alert = try #require(await session.state.alerts?.value.first)
        let dismiss = Task { await session.dismiss(alert) }
        await rig.run(for: 2)
        #expect(await dismiss.value == .notCleared)
        rig.pump.alertBitmap = 0
        await rig.run(for: 30, step: 5)
        #expect(await session.state.alerts?.value.isEmpty == true)
        #expect(await session.remoteClearTrialResult == nil)
        #expect(rig.store.load()?.remoteClearTrials.isEmpty == true)
    }

    /// A clear of an alert the session no longer holds, as from a list read before it was cleared on the
    /// pump, isn't a trial: its absence afterwards says nothing.
    @Test func aClearOfAnAlertNoLongerHeldIsNotATrial() async throws {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.alertBitmap = 1 << 7
        })
        await rig.startHeld()
        let session = rig.session
        let alert = try #require(await session.state.alerts?.value.first)
        rig.pump.alertBitmap = 0
        await rig.run(for: 30, step: 5)
        #expect(await session.state.alerts?.value.isEmpty == true)
        let dismiss = Task { await session.dismiss(alert) }
        await rig.run(for: 2)
        #expect(await dismiss.value == .cleared)
        #expect(await session.remoteClearTrialResult == nil)
        #expect(rig.store.load()?.remoteClearTrials.isEmpty == true)
    }

    /// The trial's result is kept for the unit and firmware: a relaunch keeps it, a firmware update starts
    /// over, and forgetting the pairing clears it.
    @Test func theTrialIsKeptPerUnitAndFirmware() async throws {
        let first = Rig(configure: {
            $0.unsupportedReads = []
            $0.alertBitmap = 1 << 7
        })
        await first.startHeld()
        let alert = try #require(await first.session.state.alerts?.value.first)
        let session = first.session
        let dismiss = Task { await session.dismiss(alert) }
        await first.run(for: 2)
        #expect(await dismiss.value == .cleared)
        let saved = try #require(first.store.load())

        let relaunched = Rig(
            record: saved,
            configure: {
                $0.unsupportedReads = []
                $0.alertBitmap = 1 << 9
            })
        await relaunched.startHeld()
        #expect(await relaunched.session.remoteClearTrialResult == .clears)
        #expect(await relaunched.session.state.alerts?.value.map(\.remoteClear) == [.available])

        let updated = Rig(
            record: saved,
            configure: {
                $0.unsupportedReads = []
                $0.softwareVersion = 8
                $0.alertBitmap = 1 << 9
            })
        await updated.startHeld()
        #expect(await updated.session.remoteClearTrialResult == nil)
        #expect(await updated.session.state.alerts?.value.map(\.remoteClear) == [.tryable])

        await relaunched.session.forgetPairing()
        #expect(relaunched.store.load()?.remoteClearTrials.isEmpty != false)
        #expect(await relaunched.session.remoteClearTrialResult == nil)
    }

    /// An alert cleared on the pump itself, seen by a routine read, says nothing about a remote clear.
    @Test func anAlertClearedOnThePumpDoesntCount() async throws {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.alertBitmap = 1 << 7
        })
        await rig.startHeld()
        #expect(await rig.session.state.alerts?.value.count == 1)
        rig.pump.alertBitmap = 0
        await rig.run(for: 70, step: 5)
        #expect(await rig.session.state.alerts?.value.isEmpty == true)
        #expect(await rig.session.remoteClearTrialResult == nil)
        #expect(rig.store.load()?.remoteClearTrials.isEmpty == true)
    }

    /// A new pairing starts with no trial, and its alerts are decided from that, not from the record it
    /// replaced.
    @Test func aNewPairingDecidesAlertsFromItsOwnRecord() async throws {
        let unit = PumpUnit(serialNumber: 1693, armSoftwareVersion: 7, mspSoftwareVersion: 7)
        let rig = Rig(
            paired: false, record: PumpSessionRecord(remoteClearTrials: [unit: .clears]),
            configure: {
                $0.unsupportedReads = []
                $0.alertBitmap = 1 << 7
            })
        await rig.start()
        await rig.session.scanForPairing()
        await rig.settle()
        try await rig.session.pair(
            peripheralID: ScriptedPump.peripheralID, advertisedName: rig.pump.name, code: "ABCD-EFGH-IJKL-MNOP")
        await rig.run(for: 30, step: 5)
        #expect(rig.store.load()?.remoteClearTrials.isEmpty == true)
        #expect(await rig.session.state.alerts?.value.map(\.remoteClear) == [.tryable])
    }

    /// A new pairing starts with nothing read from the pump paired before: its calculator settings and IOB
    /// aren't carried over, even when the new pump can't be read for them.
    @Test func aNewPairingDropsTheLastPumpsCalculatorInputs() async throws {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        #expect(await rig.session.state.bolusCalculator != nil)
        #expect(await rig.session.state.insulinOnBoard != nil)
        // Another pump, which doesn't answer the calculator or IOB reads.
        rig.pump.serialNumber = 2001
        rig.pump.answers[MessageKey(BolusCalcDataSnapshotRequest.self)] = .error(code: 6, drops: false)
        rig.pump.answers[MessageKey(ControlIQIOBRequest.self)] = .error(code: 6, drops: false)
        await rig.session.scanForPairing()
        await rig.settle()
        try await rig.session.pair(
            peripheralID: ScriptedPump.peripheralID, advertisedName: rig.pump.name, code: ScriptedPump.code)
        await rig.run(for: 30, step: 5)
        #expect(rig.store.load()?.pairing?.trustedSerial == 2001)
        let state = await rig.session.state
        #expect(state.link == .connected)
        #expect(state.reservoirUnits != nil)
        #expect(state.bolusCalculator == nil)
        #expect(state.insulinOnBoard == nil)
    }

    /// A record saved before this field existed reads as unknown for every unit.
    @Test func anOlderRecordReadsAsUnknown() throws {
        let unit = PumpUnit(serialNumber: 1693, armSoftwareVersion: 7, mspSoftwareVersion: 7)
        let record = PumpSessionRecord(
            pairing: Rig.pairing, lastHistorySync: Date(timeIntervalSince1970: 1_800_000_000),
            remoteClearTrials: [unit: .doesNotClear])
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(PumpSessionRecord.self, from: data) == record)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["remoteClearTrials"] = nil
        let old = try JSONDecoder().decode(PumpSessionRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.remoteClearTrials.isEmpty)
        #expect(old.pairing == record.pairing)
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

    /// The pump answers the clear with a non-zero status: refused, and the alert stays shown.
    @Test func aNonZeroStatusIsRefusedAndTheAlertStays() async throws {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.alertBitmap = 1 << 7
            // A pump that refuses leaves the alert, and answers status 1.
            $0.dismissLeavesAlert = true
            $0.answers[MessageKey(DismissNotificationRequest.self)] = .cargo([1])
        })
        await rig.startHeld()
        let alert = try #require(await rig.session.state.alerts?.value.first)
        let session = rig.session
        let dismiss = Task { await session.dismiss(alert) }
        await rig.run(for: 2)
        #expect(await dismiss.value == .refused)
        #expect(await rig.session.state.alerts?.value.count == 1)
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
