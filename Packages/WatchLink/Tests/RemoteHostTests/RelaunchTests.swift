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

/// What a phone keeps on disk across a relaunch, as bytes: the ledger, the session's record and the watch's
/// dismiss results, each in its real file format.
final class PhoneDisk: @unchecked Sendable {
    // @unchecked Sendable: every access goes through `lock`.
    private let lock = NSLock()
    private var files: [String: Data] = [:]

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

/// One process's handle on a file on the phone's disk, for a real store that reads and writes a file of
/// its own: the bytes are copied in before a load, and out after a save while the process lives.
final class ProcessFile: @unchecked Sendable {
    // @unchecked Sendable: its own state is immutable; the disk and the life lock themselves.
    let disk: PhoneDisk
    let life: ProcessLife
    let name: String
    let url: URL
    init(disk: PhoneDisk, life: ProcessLife, name: String) {
        self.disk = disk
        self.life = life
        self.name = name
        url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name)-\(UUID()).json")
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func load<T>(_ read: () -> T) -> T {
        if let data = disk.data(name) { try? data.write(to: url) } else { try? FileManager.default.removeItem(at: url) }
        return read()
    }
    func save(_ write: () throws -> Void) throws {
        try life.write {
            try write()
            disk.setData(try Data(contentsOf: url), name)
        }
    }
}

final class ProcessLedgerStore: RemoteBolusLedgerPersisting, @unchecked Sendable {
    // @unchecked Sendable: the store is used only through `file`, whose writes are serialized.
    let file: ProcessFile
    let store: RemoteBolusLedgerStore
    init(disk: PhoneDisk, life: ProcessLife) {
        file = ProcessFile(disk: disk, life: life, name: "ledger")
        store = RemoteBolusLedgerStore(url: file.url)
    }
    func loadOutcome() -> RemoteBolusLedgerStore.LoadOutcome { file.load { store.loadOutcome() } }
    func save(_ ledger: RemoteBolusLedger) throws { try file.save { try store.save(ledger) } }
}

struct ProcessSessionStore: PumpSessionPersisting {
    let file: ProcessFile
    let store: FilePumpSessionStore
    init(disk: PhoneDisk, life: ProcessLife) {
        file = ProcessFile(disk: disk, life: life, name: "session")
        store = FilePumpSessionStore(url: file.url)
    }
    func load() -> PumpSessionRecord? { file.load { store.load() } }
    func save(_ record: PumpSessionRecord) throws { try file.save { try store.save(record) } }
}

struct ProcessDismissStore: DismissResultPersisting {
    let file: ProcessFile
    let store: FileDismissResultStore
    init(disk: PhoneDisk, life: ProcessLife) {
        file = ProcessFile(disk: disk, life: life, name: "dismiss")
        store = FileDismissResultStore(url: file.url)
    }
    func load() -> [DismissResultPayload] { file.load { store.load() } }
    func save(_ results: [DismissResultPayload]) throws { try file.save { try store.save(results) } }
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
        let services: SessionRemoteServices
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
    /// The app's backup CGM source and glucose history, as the next launch sees them.
    var backupGlucose: @Sendable () async -> GlucoseSourceState? = { nil }
    var glucoseHistory: @Sendable (Date) async -> [faBolusCore.GlucoseReading] = { _ in [] }

    init(configure: (ScriptedPump) -> Void = { _ in }) {
        pump = ScriptedPump(clock: clock)
        pump.unsupportedReads = []
        // These tests are about the ledger across a relaunch, not delivery timing: a fast pump (no pending
        // phase, 1 U in 10 s) keeps their windows short.
        pump.pendingSeconds = 0
        pump.deliveryMilliunitsPerSecond = 100
        configure(pump)
        // This unit is known to act on a clear, so the watch may clear its alerts.
        disk = PhoneDisk()
        try? ProcessSessionStore(disk: disk, life: ProcessLife()).save(
            PumpSessionRecord(
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
        let sessionClock = SessionClock(now: { clock.date }, uptime: { clock.elapsed })
        let ledger = DurableBolusLedger(
            store: ProcessLedgerStore(disk: disk, life: life), now: clock.date, clock: sessionClock)
        let session = PumpSession(
            connection: connection, ledger: ledger, store: ProcessSessionStore(disk: disk, life: life),
            secrets: PairingSecrets(store: secrets),
            historySink: nil, clock: sessionClock)
        let alerts = AlertCoordinator(
            store: FileAlertStore(directory: alertDirectory), scheduler: SilentNotifications(), ledger: ledger,
            tickInterval: nil, clock: { clock.date }, uptime: { clock.elapsed })
        let watch = Transport()
        let link = WatchLink(transport: watch, clock: TestClock(), jitter: { 0 })
        let services = SessionRemoteServices(
            session: session, ledger: ledger, alerts: alerts, backupGlucose: backupGlucose, history: glucoseHistory,
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
            session: session, alerts: alerts, services: services,
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

    /// The pump granted the bolus, the InitiateBolus went out and the pump started it, but its answer was
    /// lost and the phone died with the entry still accepted. The next launch reads it back as unknown: the
    /// poll gets that and a new bolus is refused. The pump's history settles it as delivered, and a resent
    /// copy never sends a second InitiateBolus.
    @Test func killedBeforeTheInitiatesAnswerThePumpActed() async {
        let phone = RelaunchingPhone()
        await phone.launch()
        phone.pump.nextAnswers[MessageKey(InitiateBolusRequest.self)] = [.actedWithoutReply]
        // 5 U: 50 s at the scripted rate, so it's still going after the relaunch.
        await phone.receive(phone.bolus("w1", milliunits: 5000))
        await phone.run(for: 2)
        #expect(phone.pump.activeBolus != nil)
        #expect(await phone.ledger.ledger.outcome(.init(peerId: "garmin", requestId: "w1")) == .accepted)
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
        #expect(phone.pump.arrivals(of: InitiateBolusRequest.self).count == 1)
        #expect(phone.watch.statuses.last?.bolusBlock == nil)
    }

    /// As above, but the pump never acted on the InitiateBolus. Its history reaches back past the grant
    /// with no record of the bolus, so the next launch settles it as failed; the watch's poll and a resent
    /// copy get that, and nothing more is sent.
    @Test func killedBeforeTheInitiatesAnswerThePumpDidntAct() async {
        let phone = RelaunchingPhone()
        // A glucose record an hour old, so a search can reach back past the grant.
        _ = phone.pump.appendHistory(
            typeId: 256, at: phone.pump.wallClockAtStart - 3600, body: [UInt8](repeating: 0, count: 6) + [100, 0])
        await phone.launch()
        phone.pump.nextAnswers[MessageKey(InitiateBolusRequest.self)] = [.silent]
        await phone.receive(phone.bolus("w1"))
        await phone.run(for: 2)
        #expect(phone.pump.arrivals(of: InitiateBolusRequest.self).count == 1)
        #expect(phone.pump.activeBolus == nil)
        #expect(await phone.ledger.ledger.outcome(.init(peerId: "garmin", requestId: "w1")) == .accepted)
        await phone.kill()

        await phone.launch()
        await phone.run(for: 10, step: 1)
        await phone.receive(phone.poll("w1"))
        await phone.receive(phone.bolus("w1"))
        await phone.run(for: 14, step: 1)
        #expect(!phone.outcomes("w1").isEmpty)
        #expect(phone.outcomes("w1").contains(.failed))
        #expect(Set(phone.outcomes("w1")).isSubset(of: [.received, .failed]))
        #expect(phone.pump.arrivals(of: BolusPermissionRequest.self).count == 1)
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
    /// After the relaunch the watch's poll, and a copy of the request, are answered as cancelled, never
    /// delivered, whether the cancel named it or not.
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
        // The watch had heard "received", so it polls rather than resends.
        await phone.receive(phone.poll("w1"))
        #expect(phone.outcomes("w1") == [.failed])
        #expect(phone.watch.outcomes.last { $0.requestId == "w1" }?.message == RemoteHost.cancelledMessage)
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
    /// same alert again; a copy of the old clear arriving after the relaunch gets the old answer, and the
    /// new alert stays raised on the pump and listed in the status. A watch acts only on the answer to its
    /// latest dismiss, once: one that never heard the first answer takes this one and hides the alert for
    /// the minute it hides any alert it was told was cleared, as it would had the pump raised it again just
    /// after an ordinary clear.
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
