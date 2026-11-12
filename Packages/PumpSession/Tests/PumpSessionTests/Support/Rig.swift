import Foundation
import PumpScript
import TandemBLE
import TandemLink
import TandemMessages
@testable import faBolusCore

@testable import PumpSession

/// The ledger in memory, with saves that fail on demand.
final class MemoryLedgerStore: RemoteBolusLedgerPersisting, @unchecked Sendable {
    // @unchecked Sendable: tests touch it from the ledger actor and the test, never at once.
    var saved: RemoteBolusLedger?
    var saveCount = 0
    /// Fail every save from this one on (1-based); nil never fails.
    var failFromSave: Int?
    /// Fail only these saves (1-based).
    var failSaves: Set<Int> = []
    var corrupt = false

    init(_ ledger: RemoteBolusLedger? = nil) { saved = ledger }

    func loadOutcome() -> RemoteBolusLedgerStore.LoadOutcome {
        .init(ledger: saved ?? RemoteBolusLedger(), failedClosed: corrupt)
    }

    func save(_ ledger: RemoteBolusLedger) throws {
        saveCount += 1
        if failSaves.contains(saveCount) || failFromSave.map({ saveCount >= $0 }) == true {
            throw CocoaError(.fileWriteUnknown)
        }
        saved = ledger
    }
}

final class MemorySecrets: SecretStore, @unchecked Sendable {
    // @unchecked Sendable: guarded by `lock`.
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func secret(for account: String) -> String? { lock.withLock { values[account] } }
    func setSecret(_ value: String?, for account: String) throws { lock.withLock { values[account] = value } }
}

actor RecordingSink: PumpHistorySink {
    var batches: [PumpHistoryBatch] = []
    var fail = false
    var clears = 0
    func record(_ batch: PumpHistoryBatch) async throws {
        if fail { throw CocoaError(.fileWriteUnknown) }
        batches.append(batch)
    }
    func setFail(_ value: Bool) { fail = value }
    func loadEvents(limit: Int) async -> [HistoryEvent] {
        Array(batches.flatMap(\.events).sorted { $0.date > $1.date }.prefix(limit))
    }
    func clearEvents() async {
        clears += 1
        for i in batches.indices { batches[i].events = [] }
    }
}

actor EventLog {
    var events: [PumpEvent] = []
    func append(_ e: PumpEvent) { events.append(e) }
}

/// The real session and link over the scripted pump.
@MainActor
final class Rig {
    let clock: ScriptClock
    let pump: ScriptedPump
    let transport: ScriptedTransport
    let connection: PumpConnection
    let ledgerStore: MemoryLedgerStore
    let ledger: DurableBolusLedger
    let store: MemoryPumpSessionStore
    let secrets = MemorySecrets()
    let historySink: any PumpHistorySink
    /// The recording sink, when the rig wasn't given a sink of its own.
    var sink: RecordingSink {
        guard let sink = historySink as? RecordingSink else { preconditionFailure("this rig has its own sink") }
        return sink
    }
    let session: PumpSession
    let log = EventLog()
    private var listener: Task<Void, Never>?

    static let pairing = StoredPairing(
        peripheralID: ScriptedPump.peripheralID, model: .tslimX2, scheme: .legacy, advertisedName: "tslim X2 ***693",
        trustedSerial: 1693, pairedAt: Date(timeIntervalSince1970: 1_700_000_000))

    /// - Parameters:
    ///   - paired: start with the scripted pump's pairing stored.
    ///   - ledger: the ledger saved before this launch.
    init(
        paired: Bool = true, ledger saved: RemoteBolusLedger? = nil, ledgerStore: MemoryLedgerStore? = nil,
        record: PumpSessionRecord? = nil, sink: (any PumpHistorySink)? = nil,
        configure: (ScriptedPump) -> Void = { _ in },
        configuration: PumpSession.Configuration = PumpSession.Configuration()
    ) {
        historySink = sink ?? RecordingSink()
        clock = ScriptClock()
        pump = ScriptedPump(clock: clock)
        configure(pump)
        transport = ScriptedTransport(pump: pump)
        connection = PumpConnection(transport: transport, clock: clock)
        self.ledgerStore = ledgerStore ?? MemoryLedgerStore(saved)
        let clock = self.clock
        ledger = DurableBolusLedger(store: self.ledgerStore, now: clock.date)
        store = MemoryPumpSessionStore(record ?? (paired ? PumpSessionRecord(pairing: Self.pairing) : nil))
        let pairingSecrets = PairingSecrets(store: secrets)
        if paired { try? pairingSecrets.store(.legacy(code: ScriptedPump.code)) }
        session = PumpSession(
            connection: connection, ledger: ledger, store: store, secrets: pairingSecrets, historySink: historySink,
            configuration: configuration, clock: { clock.date })
    }

    /// Bluetooth on, the app in the foreground, the session started: with a stored pairing the link comes
    /// up at once.
    func start(restoring: Bool = false) async {
        let stream = await session.events()
        let log = self.log
        listener = Task { for await e in stream { await log.append(e) } }
        if !restoring { connection.setAppActive(true) }
        transport.start(restoring: restoring)
        await session.start(runTicker: false)
        await settle()
    }

    /// `start`, then 11 s so the connection has held: the link sends untested commands (InitiateBolus on
    /// P1 is one) only after the hold.
    func startHeld() async {
        await start()
        await run(for: 11, step: 1)
    }

    /// Lets the session and the link finish what they're doing: link events handled, the queue drained.
    ///
    /// Bounded by quiet rounds, then by a little real time (about 0.2 s), so a loaded machine that gives
    /// the actors fewer turns waits longer instead of asserting too early. Work waiting on the clock (a
    /// request held for the hold window, a silent pump) never goes quiet, and costs that bound.
    func settle() async {
        var quietRounds = 0
        for round in 0..<2200 {
            if round < 2000 { await Task.yield() } else { try? await Task.sleep(nanoseconds: 1_000_000) }
            if await session.isQuiet {
                quietRounds += 1
                if quietRounds > 20 { return }
            } else {
                quietRounds = 0
            }
        }
    }

    /// Moves time on in steps, ticking the session at each, as the app's timer would.
    func run(for seconds: Double, step: Double = 0.5) async {
        var elapsed = 0.0
        while elapsed < seconds {
            let s = min(step, seconds - elapsed)
            clock.advance(by: s)
            elapsed += s
            await session.tick()
            await settle()
        }
    }

    /// Moves time on, as `run` does, until `work` returns or `limit` seconds have passed, and returns its
    /// result: nil if it hadn't returned by then. For work that waits on deadlines: how much clock it needs
    /// depends on how many turns the actors get between steps, and a fixed `run` followed by an unbounded
    /// wait would hang on a loaded machine instead of failing.
    func run<T: Sendable>(
        upTo limit: Double, step: Double = 0.5, finishing work: @escaping @Sendable () async -> T
    ) async -> T? {
        let result = Finished<T>()
        Task { @MainActor in result.value = await work() }
        var elapsed = 0.0
        while result.value == nil, elapsed < limit {
            let s = min(step, limit - elapsed)
            clock.advance(by: s)
            elapsed += s
            await session.tick()
            await settle()
        }
        return result.value
    }

    /// Waits for `condition`, settling between checks.
    func until(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<500 {
            if await condition() { return true }
            await settle()
        }
        return await condition()
    }

    var events: [PumpEvent] { get async { await log.events } }

    func outcomes(_ key: RemoteBolusLedger.Key) async -> [BolusOutcome] {
        await events.compactMap {
            if case .bolusOutcome(let k, let o) = $0, k == key { return o }
            return nil
        }
    }

    func stop() async {
        await session.stop()
        listener?.cancel()
    }
}

extension PumpSession {
    /// Nothing can happen until time moves: nothing in flight, and nothing queued that may be sent (an
    /// untested command waits for the hold; a history page waits for its frames or its quiet timeout).
    var isQuiet: Bool { !sending && nextJobIndex() == nil }
}

/// A dose as the composer would produce it.
func composed(
    _ units: Double, id: String = "phone-1", origin: DoseRequest.Origin = .phone, carbs: Double? = nil,
    bg: Int? = nil, iob: Double? = nil, carbUnits: Double? = nil
) -> ComposedDose {
    ComposedDose(
        request: DoseRequest(id: id, origin: origin, shape: .now(units: units), carbsGrams: carbs, bgMgdl: bg),
        calculatorIOBUnits: iob, correctionGlucoseMgdl: bg, calculatorCarbUnits: carbUnits,
        usedIncludedStaleGlucose: false, notices: [])
}

extension RemoteDoseDecision {
    var dose: ComposedDose? {
        if case .deliver(let dose) = self { return dose }
        return nil
    }
    var refusal: DoseRefusal? {
        if case .refused(let refusal) = self { return refusal }
        return nil
    }
}

/// What a `Rig.run(upTo:finishing:)` task returned, once it has.
@MainActor
private final class Finished<T> {
    var value: T?
}
