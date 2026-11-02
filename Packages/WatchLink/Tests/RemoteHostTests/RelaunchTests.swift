import Alerts
import Foundation
import PumpScript
import RemoteProtocol
import TandemBLE
import TandemLink
import TandemMessages
import Testing
import WatchLink

@testable import PumpSession
@testable import RemoteHost
@testable import faBolusCore

/// What a phone keeps on disk across a relaunch: the ledger, the session's record and the watch's dismiss
/// results.
final class PhoneDisk: @unchecked Sendable {
    // @unchecked Sendable: every access goes through `lock`.
    private let lock = NSLock()
    private var ledger: RemoteBolusLedger?
    private var record: PumpSessionRecord?
    private var files: [String: Data] = [:]

    init(record: PumpSessionRecord?) { self.record = record }

    func loadLedger() -> RemoteBolusLedger? { lock.withLock { ledger } }
    func saveLedger(_ value: RemoteBolusLedger) { lock.withLock { ledger = value } }
    func loadRecord() -> PumpSessionRecord? { lock.withLock { record } }
    func saveRecord(_ value: PumpSessionRecord) { lock.withLock { record = value } }
    func data(_ name: String) -> Data? { lock.withLock { files[name] } }
    func setData(_ value: Data?, _ name: String) { lock.withLock { files[name] = value } }
}

/// Whether a process is still running. Its stores write to the disk only while it is, so a dead one's
/// late work (its link's timers still fire on the shared clock) never lands.
final class ProcessLife: @unchecked Sendable {
    // @unchecked Sendable: guarded by `lock`.
    private let lock = NSLock()
    private var alive = true
    func end() { lock.withLock { alive = false } }
    func write(_ body: () throws -> Void) throws {
        try lock.withLock {
            guard alive else { throw CocoaError(.fileWriteUnknown) }
            try body()
        }
    }
}

/// One process's handle on the ledger file.
final class ProcessLedgerStore: RemoteBolusLedgerPersisting, @unchecked Sendable {
    // @unchecked Sendable: its own state is immutable; the disk and the life lock themselves.
    let disk: PhoneDisk
    let life: ProcessLife
    init(disk: PhoneDisk, life: ProcessLife) {
        self.disk = disk
        self.life = life
    }
    func loadOutcome() -> RemoteBolusLedgerStore.LoadOutcome {
        .init(ledger: disk.loadLedger() ?? RemoteBolusLedger(), failedClosed: false)
    }
    func save(_ ledger: RemoteBolusLedger) throws { try life.write { disk.saveLedger(ledger) } }
}

/// One process's handle on the session's record.
struct ProcessSessionStore: PumpSessionPersisting {
    let disk: PhoneDisk
    let life: ProcessLife
    func load() -> PumpSessionRecord? { disk.loadRecord() }
    func save(_ record: PumpSessionRecord) throws { try life.write { disk.saveRecord(record) } }
}

/// One process's handle on the dismiss results file, through the real file format.
final class ProcessDismissStore: DismissResultPersisting, @unchecked Sendable {
    // @unchecked Sendable: its own state is immutable; the file is written only inside `life.write`.
    let disk: PhoneDisk
    let life: ProcessLife
    let file = FileDismissResultStore(
        url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dismiss-\(UUID()).json"))
    init(disk: PhoneDisk, life: ProcessLife) {
        self.disk = disk
        self.life = life
    }
    deinit { try? FileManager.default.removeItem(at: file.url) }
    func load() -> [DismissResultPayload] {
        guard let data = disk.data("dismiss") else { return [] }
        try? data.write(to: file.url)
        return file.load()
    }
    func save(_ results: [DismissResultPayload]) throws {
        try life.write {
            try file.save(results)
            disk.setData(try Data(contentsOf: file.url), "dismiss")
        }
    }
}

final class PhoneSecrets: SecretStore, @unchecked Sendable {
    // @unchecked Sendable: guarded by `lock`.
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func secret(for account: String) -> String? { lock.withLock { values[account] } }
    func setSecret(_ value: String?, for account: String) throws { lock.withLock { values[account] = value } }
}

actor SilentNotifications: NotificationScheduling {
    func add(_ request: AlertRequest, now: Date) async throws {}
    func remove(identifiers: [String]) async {}
    func removeAll() async {}
    func permission() async -> NotificationPermission {
        NotificationPermission(authorization: .authorized, alerts: .enabled, timeSensitive: .enabled)
    }
}

/// A phone running the app's real parts for the watch, over the scripted pump: the pump session, the
/// ledger, the alert pipeline, `SessionRemoteServices`, the host and the watch link. The pump and the
/// disk outlive the phone's process: `kill()` ends one as iOS would, mid-whatever, and `launch()` starts
/// the next from what's on disk.
@MainActor
final class RelaunchingPhone {
    struct Process {
        let transport: ScriptedTransport
        let life: ProcessLife
        let ledger: DurableBolusLedger
        let session: PumpSession
        let alerts: AlertCoordinator
        let watch: Transport
        let host: RemoteHost
        let tasks: [Task<Void, Never>]
    }

    static let unit = TandemMessages.PumpUnit(serialNumber: 1693, armSoftwareVersion: 7, mspSoftwareVersion: 7)
    let clock = ScriptClock()
    let pump: ScriptedPump
    let disk: PhoneDisk
    let secrets = PhoneSecrets()
    let alertDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("relaunch-\(UUID())")
    private(set) var process: Process!

    init(configure: (ScriptedPump) -> Void = { _ in }) {
        pump = ScriptedPump(clock: clock)
        pump.unsupportedReads = []
        configure(pump)
        // This unit is known to act on a clear, so the watch may clear its alerts.
        disk = PhoneDisk(
            record: PumpSessionRecord(
                pairing: StoredPairing(
                    peripheralID: ScriptedPump.peripheralID, model: .tslimX2, scheme: .legacy,
                    advertisedName: pump.name, trustedSerial: 1693, pairedAt: Date(timeIntervalSince1970: 1_700_000_000)
                ),
                remoteClearTrials: [Self.unit: .clears]))
        try? PairingSecrets(store: secrets).store(.legacy(code: ScriptedPump.code))
        try? FileManager.default.createDirectory(at: alertDirectory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: alertDirectory) }

    var watch: Transport { process.watch }
    var session: PumpSession { process.session }
    var ledger: DurableBolusLedger { process.ledger }
    var now: Int { Int(clock.date.timeIntervalSince1970) }

    /// Launches the app: everything is built again from the disk, and the pump connects once its link has
    /// held.
    func launch() async {
        let clock = clock
        let transport = ScriptedTransport(pump: pump)
        let connection = PumpConnection(transport: transport, clock: clock)
        let life = ProcessLife()
        let ledger = DurableBolusLedger(store: ProcessLedgerStore(disk: disk, life: life), now: clock.date)
        let session = PumpSession(
            connection: connection, ledger: ledger, store: ProcessSessionStore(disk: disk, life: life),
            secrets: PairingSecrets(store: secrets),
            historySink: nil, clock: { clock.date })
        let alerts = AlertCoordinator(
            store: FileAlertStore(directory: alertDirectory), scheduler: SilentNotifications(), ledger: ledger,
            tickInterval: nil, clock: { clock.date })
        let watch = Transport()
        let link = WatchLink(transport: watch, clock: TestClock(), jitter: { 0 })
        let services = SessionRemoteServices(
            session: session, ledger: ledger, alerts: alerts, backupGlucose: { nil }, history: { _ in [] },
            clock: { clock.date })
        let host = RemoteHost(
            link: link, services: services, settings: HostRig.settings(),
            dismissResults: ProcessDismissStore(disk: disk, life: life),
            clock: { clock.date })
        // Every consumer subscribes before the session starts, as the app does.
        let alertEvents = await session.events()
        let hostEvents = await session.events()
        await alerts.start(events: alertEvents, pumpPaired: true)
        let snapshots = await alerts.snapshots()
        let tasks = [
            Task { for await e in hostEvents { await host.pumpEvent(e) } },
            Task { for await s in snapshots { await host.alertsChanged(s.active) } }
        ]
        connection.setAppActive(true)
        transport.start()
        await session.start(runTicker: false)
        link.start()
        watch.handler?(.paired(true))
        watch.handler?(.deviceStatus(.connected))
        watch.handler?(.characteristicsDiscovered)
        await host.start()
        process = Process(
            transport: transport, life: life, ledger: ledger,
            session: session, alerts: alerts,
            watch: watch, host: host, tasks: tasks)
        await run(for: 12, step: 1)
    }

    /// The process ends with no warning: nothing it held in memory survives, nothing more it does reaches
    /// the pump or the disk.
    func kill() async {
        process.transport.processEnded()
        process.life.end()
        await process.alerts.stop()
        for task in process.tasks { task.cancel() }
    }

    func receive(_ message: RemoteMessage) async {
        watch.handler?(.received(message.wire))
        await settle()
    }

    func bolus(_ id: String, milliunits: Int = 1000, sentAt: Int? = nil) -> RemoteMessage {
        .bolus(
            BolusRequestPayload(
                requestId: id, sentAt: sentAt ?? now - 1, amount: .units(milliunits: milliunits), glucoseMgdl: nil,
                includeStaleGlucose: false))
    }

    func poll(_ id: String) -> RemoteMessage {
        .poll(
            .init(configRevision: nil, awaitingRequestId: id, wantsHistory: false, freshGlucose: false, appVersion: "t")
        )
    }

    func outcomes(_ id: String) -> [OutcomeToken] { watch.outcomes.filter { $0.requestId == id }.map(\.outcome) }

    /// Lets the session, the alerts, the host and the link finish what they're doing.
    func settle() async {
        for _ in 0..<4 {
            for _ in 0..<200 { await Task.yield() }
            for _ in 0..<500 where await !session.isIdle { await Task.yield() }
        }
    }

    func run(for seconds: Double, step: Double = 0.5) async {
        var elapsed = 0.0
        while elapsed < seconds {
            clock.advance(by: step)
            elapsed += step
            await session.tick()
            await settle()
        }
    }
}

extension PumpSession {
    fileprivate var isIdle: Bool { !sending && nextJobIndex() == nil }
}

/// A phone relaunch, at each point of a watch's bolus. The ledger is written before every move, and the
/// host answers a poll or a resend from it, so the watch never gets a second delivery or a wrong outcome:
/// an outcome left unresolved shows as unknown, and blocks, until the pump's history settles it.
@MainActor
@Suite struct BolusAcrossARelaunchTests {
    /// The pump accepted the bolus and is delivering it when the phone dies. The next launch reads the
    /// entry back as unknown: the watch's poll gets that, a new bolus is refused, and the pump's history
    /// settles it once the bolus is done. A resent copy is never delivered again.
    @Test func killedWhileThePumpDelivers() async {
        let phone = RelaunchingPhone()
        await phone.launch()
        // 5 U: 50 s at the scripted rate, so it's still going after the relaunch.
        await phone.receive(phone.bolus("w1", milliunits: 5000))
        await phone.run(for: 2)
        #expect(phone.outcomes("w1").contains(.delivering))
        #expect(phone.pump.activeBolus != nil)
        await phone.kill()

        await phone.launch()
        await phone.receive(phone.poll("w1"))
        #expect(phone.outcomes("w1").first == .unknown)
        #expect(phone.watch.statuses.last?.bolusBlock != nil)
        await phone.receive(phone.bolus("w2"))
        #expect(phone.outcomes("w2").last == .failed)
        await phone.receive(phone.bolus("w1", milliunits: 5000))
        await phone.run(for: 60, step: 1)
        await phone.receive(phone.poll("w1"))
        #expect(phone.outcomes("w1").last == .delivered)
        #expect(!phone.outcomes("w1").contains { $0 == .failed || $0 == .refused })
        #expect(phone.pump.arrivals(of: InitiateBolusRequest.self).count == 1)
        #expect(phone.watch.statuses.last?.bolusBlock == nil)
    }

    /// The outcome is known and saved, but the phone dies before the watch hears it. The next launch
    /// answers the watch's poll, and a resent copy, from the ledger.
    @Test func killedAfterTheOutcomeBeforeTheWatchHearsIt() async {
        let phone = RelaunchingPhone()
        await phone.launch()
        await phone.receive(phone.bolus("w1"))
        await phone.run(for: 14, step: 1)
        #expect(await phone.ledger.ledger.outcome(.init(peerId: "garmin", requestId: "w1")) == .delivered(units: 1))
        await phone.kill()

        await phone.launch()
        await phone.receive(phone.poll("w1"))
        await phone.receive(phone.bolus("w1"))
        #expect(!phone.outcomes("w1").isEmpty)
        #expect(Set(phone.outcomes("w1")).isSubset(of: [.received, .delivered]))
        #expect(phone.watch.outcomes.last { $0.requestId == "w1" }?.deliveredMilliunits == 1000)
        #expect(phone.pump.arrivals(of: InitiateBolusRequest.self).count == 1)
    }

    /// The watch heard the outcome; after a relaunch a stray copy of the request arrives (a transport that
    /// delivers a message twice). It gets the recorded outcome, never a second delivery.
    @Test func aStrayCopyAfterTheWatchHeardTheOutcome() async {
        let phone = RelaunchingPhone()
        await phone.launch()
        await phone.receive(phone.bolus("w1"))
        await phone.run(for: 14, step: 1)
        #expect(phone.outcomes("w1").last == .delivered)
        await phone.kill()

        await phone.launch()
        await phone.receive(phone.bolus("w1"))
        #expect(phone.outcomes("w1").last == .delivered)
        #expect(phone.pump.arrivals(of: BolusPermissionRequest.self).count == 1)
        #expect(phone.pump.arrivals(of: InitiateBolusRequest.self).count == 1)
    }

    /// The phone dies after telling the watch it has the request, before recording it. Nothing was sent to
    /// the pump, so the next launch has nothing to answer the poll with; the copy that arrives later, still
    /// fresh, is delivered once.
    @Test func killedBeforeTheRequestWasRecorded() async {
        let phone = RelaunchingPhone()
        await phone.launch()
        phone.pump.answers[MessageKey(BolusCalcDataSnapshotRequest.self)] = .silent
        await phone.receive(phone.bolus("w1"))
        #expect(phone.outcomes("w1") == [.received])
        await phone.kill()
        phone.pump.answers = [:]

        await phone.launch()
        await phone.receive(phone.poll("w1"))
        #expect(phone.outcomes("w1").isEmpty)
        #expect(phone.pump.arrivals(of: BolusPermissionRequest.self).isEmpty)
        await phone.receive(phone.bolus("w1", sentAt: phone.now - 20))
        await phone.run(for: 14, step: 1)
        #expect(phone.outcomes("w1").last == .delivered)
        #expect(phone.pump.arrivals(of: InitiateBolusRequest.self).count == 1)
    }

    /// The user cancels on the watch while the phone is still composing the request, and the phone dies.
    /// A copy of the request that arrives after the relaunch is refused as cancelled, never delivered,
    /// whether the cancel named it or not.
    @Test(arguments: [true, false])
    func aRequestCancelledWhileComposingStaysCancelledAfterARelaunch(named: Bool) async {
        let phone = RelaunchingPhone()
        await phone.launch()
        phone.pump.answers[MessageKey(BolusCalcDataSnapshotRequest.self)] = .silent
        await phone.receive(phone.bolus("w1"))
        await phone.receive(.cancel(CancelPayload(requestId: "c1", bolusRequestId: named ? "w1" : nil)))
        await phone.kill()
        phone.pump.answers = [:]

        await phone.launch()
        await phone.receive(phone.bolus("w1", sentAt: phone.now - 20))
        await phone.run(for: 14, step: 1)
        #expect(phone.pump.arrivals(of: BolusPermissionRequest.self).isEmpty)
        #expect(phone.outcomes("w1").last == .failed)
        #expect(phone.watch.outcomes.last { $0.requestId == "w1" }?.message == RemoteHost.cancelledMessage)
    }
}

/// A phone relaunch around a watch's alert clear. A copy of the clear that arrives after the relaunch
/// never clears a different alert, and never reports cleared for one the pump didn't clear.
@MainActor
@Suite struct DismissAcrossARelaunchTests {
    func dismiss(_ requestId: String, _ alertId: String) -> RemoteMessage {
        .dismiss(.init(requestId: requestId, alertId: alertId))
    }

    func results(_ phone: RelaunchingPhone, _ requestId: String) -> [DismissResultToken] {
        phone.watch.dismissResults.filter { $0.requestId == requestId }.map(\.result)
    }

    /// A phone whose pump shows one alert the watch may clear, launched; and that alert's ID on the watch.
    func launched(configure: (ScriptedPump) -> Void = { _ in }) async throws -> (RelaunchingPhone, String) {
        let phone = RelaunchingPhone(configure: {
            $0.alertBitmap = 1 << 7
            configure($0)
        })
        await phone.launch()
        let alert = try #require(phone.watch.statuses.last?.alerts.first)
        #expect(alert.dismissable)
        return (phone, alert.id)
    }

    /// The phone dies before the pump got the clear: the alert is still showing, and the copy after the
    /// relaunch clears it.
    @Test func killedBeforeThePumpClearedIt() async throws {
        let (phone, alert) = try await launched()
        phone.pump.answers[MessageKey(DismissNotificationRequest.self)] = .silent
        await phone.receive(dismiss("d1", alert))
        await phone.kill()
        phone.pump.answers = [:]
        #expect(phone.pump.alertBitmap == 1 << 7)

        await phone.launch()
        await phone.receive(dismiss("d1", alert))
        await phone.run(for: 2)
        #expect(results(phone, "d1") == [.cleared])
        #expect(phone.pump.alertBitmap == 0)
    }

    /// The pump cleared the alert and the phone died, before or after the watch heard. The pump raises the
    /// same alert again; a copy of the old clear arriving after the relaunch gets the old answer and leaves
    /// the new alert showing.
    @Test func killedAfterThePumpClearedItThenTheAlertCameBack() async throws {
        let (phone, alert) = try await launched()
        await phone.receive(dismiss("d1", alert))
        await phone.run(for: 2)
        #expect(phone.pump.alertBitmap == 0)
        #expect(results(phone, "d1") == [.cleared])
        await phone.kill()

        phone.pump.alertBitmap = 1 << 7
        await phone.launch()
        await phone.run(for: 20, step: 5)
        #expect(phone.watch.statuses.last?.alerts.map(\.id) == [alert])
        await phone.receive(dismiss("d1", alert))
        await phone.run(for: 2)
        #expect(results(phone, "d1") == [.cleared])
        #expect(phone.pump.arrivals(of: DismissNotificationRequest.self).count == 1)
        #expect(phone.pump.alertBitmap == 1 << 7)
    }

    /// The pump cleared the alert and it stayed cleared: a copy after the relaunch is told cleared again,
    /// from what the phone kept, and nothing more is sent.
    @Test func killedAfterThePumpClearedIt() async throws {
        let (phone, alert) = try await launched()
        await phone.receive(dismiss("d1", alert))
        await phone.run(for: 2)
        await phone.kill()

        await phone.launch()
        await phone.receive(dismiss("d1", alert))
        #expect(results(phone, "d1") == [.cleared])
        #expect(phone.pump.arrivals(of: DismissNotificationRequest.self).count == 1)
    }

    /// The pump refused the clear; a copy after the relaunch is told refused again, never cleared.
    @Test func aRefusedClearStaysRefusedAfterARelaunch() async throws {
        let (phone, alert) = try await launched(configure: {
            $0.dismissLeavesAlert = true
            $0.answers[MessageKey(DismissNotificationRequest.self)] = .cargo([1])
        })
        await phone.receive(dismiss("d1", alert))
        await phone.run(for: 2)
        #expect(results(phone, "d1") == [.refused])
        await phone.kill()

        await phone.launch()
        await phone.receive(dismiss("d1", alert))
        await phone.run(for: 2)
        #expect(results(phone, "d1") == [.refused])
        #expect(phone.pump.arrivals(of: DismissNotificationRequest.self).count == 1)
        #expect(phone.pump.alertBitmap == 1 << 7)
    }
}
