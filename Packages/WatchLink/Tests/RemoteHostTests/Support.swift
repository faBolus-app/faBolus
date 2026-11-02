import Alerts
import Foundation
import PumpSession
import RemoteProtocol
import Testing
import WatchLink
@testable import faBolusCore

@testable import RemoteHost

/// The host's services, scripted. Records every call.
actor FakeServices: RemoteHostServices {
    /// Refusals go to a real ledger, so a relaunch can read them back from its store.
    let refusalLedger: DurableBolusLedger
    init(ledgerStore: sending (any RemoteBolusLedgerPersisting)? = nil) {
        refusalLedger = DurableBolusLedger(store: ledgerStore, now: HostRig.now)
    }

    var state = PumpState()
    var block: BolusBlock?
    var entries: [RemoteBolusLedger.Key: RemoteBolusLedger.Entry] = [:]
    var decision: RemoteDoseDecision = .refused(.noDoseSpecified)
    var delivery: DeliveryResult?
    var dismissOutcome: DismissOutcome = .cleared
    var composeDelay: Duration = .zero
    var history: [faBolusCore.GlucoseReading] = []
    var autoCorrection: Date?
    /// Delays for successive `pump()` calls, then the states they return, so overlapping refreshes can be
    /// made to finish out of order.
    var pumpScript: [(delay: Duration, state: PumpState)] = []

    var composed: [RemoteDoseRequest] = []
    var delivered: [ComposedDose] = []
    var cancels = 0
    var dismissed: [PumpAlert] = []
    var refusals: [String] = []
    var glucoseRefreshes = 0

    func set(state: PumpState) { self.state = state }
    func set(decision: RemoteDoseDecision, delivery: DeliveryResult? = nil, delay: Duration = .zero) {
        self.decision = decision
        self.delivery = delivery
        composeDelay = delay
    }
    func set(entry: RemoteBolusLedger.Entry) { entries[entry.key] = entry }
    func set(dismissOutcome: DismissOutcome) { self.dismissOutcome = dismissOutcome }
    func set(block: BolusBlock?) { self.block = block }
    func set(history: [faBolusCore.GlucoseReading]) { self.history = history }

    func set(pumpScript: [(delay: Duration, state: PumpState)]) { self.pumpScript = pumpScript }
    func pump() async -> (PumpState, GlucoseProvenance) {
        guard !pumpScript.isEmpty else { return (state, .pump) }
        let next = pumpScript.removeFirst()
        try? await Task.sleep(for: next.delay)
        return (next.state, .pump)
    }
    func bolusBlock() async -> BolusBlock? { block }
    func ledgerEntry(_ key: RemoteBolusLedger.Key) async -> RemoteBolusLedger.Entry? { entries[key] }
    func compose(
        _ request: RemoteDoseRequest, access: AccessPolicy.AccessContext, remoteSizeLimitUnits: Double?
    ) async -> RemoteDoseDecision {
        composed.append(request)
        if composeDelay != .zero { try? await Task.sleep(for: composeDelay) }
        return decision
    }
    func deliver(_ dose: ComposedDose) async -> DeliveryResult {
        delivered.append(dose)
        return delivery ?? .notStarted(.notConnected)
    }
    var cancelDelay: Duration = .zero
    func set(cancelDelay: Duration) { self.cancelDelay = cancelDelay }
    /// What successive cancels answer; `.cancelled` once it runs out.
    var cancelResults: [CancelResult] = []
    func set(cancelResults: [CancelResult]) { self.cancelResults = cancelResults }
    func cancelBolus() async -> CancelResult {
        cancels += 1
        if cancelDelay != .zero { try? await Task.sleep(for: cancelDelay) }
        return cancelResults.isEmpty ? .cancelled : cancelResults.removeFirst()
    }
    func dismiss(_ alert: PumpAlert) async -> DismissOutcome {
        dismissed.append(alert)
        return dismissOutcome
    }
    func refreshGlucose() async { glucoseRefreshes += 1 }
    func glucoseHistory(since: Date) async -> [faBolusCore.GlucoseReading] { history.filter { $0.date >= since } }
    func set(autoCorrection: Date?) { self.autoCorrection = autoCorrection }
    func lastAutoCorrection() async -> Date? { autoCorrection }
    func remoteBolusRefused(requestId: String, reason: String) async { refusals.append(requestId) }
    func ledgerRefusal(_ key: RemoteBolusLedger.Key) async -> RemoteBolusLedger.RemoteRefusal? {
        await refusalLedger.ledger.remoteRefusal(key)
    }
    func recordRefusal(_ key: RemoteBolusLedger.Key, reason: String) async {
        _ = try? await refusalLedger.recordRemoteRefusal(key, reason: reason, now: HostRig.now)
    }
}

@MainActor
final class Transport: WatchTransport {
    var handler: (@MainActor (WatchTransportEvent) -> Void)?
    var sent: [WireValue] = []
    func start(_ handler: @escaping @MainActor (WatchTransportEvent) -> Void) { self.handler = handler }
    func transmit(_ message: WireValue, send: Int) {
        sent.append(message)
        // A watch that takes everything at once.
        let handler = handler
        Task { @MainActor in handler?(.sendCompleted(send: send, .delivered)) }
    }
    func probeAppStatus(probe: Int) {}
    func reregister() {}

    var messages: [RemoteMessage] {
        sent.compactMap { if case .message(let m) = RemoteMessage.receive($0) { return m } else { return nil } }
    }
    var outcomes: [BolusOutcomePayload] {
        messages.compactMap { if case .bolusOutcome(let p) = $0 { return p } else { return nil } }
    }
    var dismissResults: [DismissResultPayload] {
        messages.compactMap { if case .dismissResult(let p) = $0 { return p } else { return nil } }
    }
    var statuses: [StatusPayload] {
        messages.compactMap { if case .status(let p) = $0 { return p } else { return nil } }
    }
    var configs: [WatchConfig] {
        messages.compactMap { if case .config(let p) = $0 { return p } else { return nil } }
    }
}

final class TestClock: WatchLinkClock {
    var now: LinkSeconds = 0
    var epoch: Int?
    func schedule(after seconds: LinkSeconds, _ action: @escaping @MainActor () -> Void) -> any WatchLinkTimer {
        Never()
    }
    final class Never: WatchLinkTimer { func cancel() {} }
}

/// A host over a real link and a watch that receives everything.
@MainActor
struct HostRig {
    let services: FakeServices
    let transport = Transport()
    let link: WatchLink
    let host: RemoteHost
    nonisolated static let now = Date(timeIntervalSince1970: TimeInterval(GoldenFixtures.now))

    init(
        settings: RemoteSettings = HostRig.settings(), services: FakeServices = FakeServices(),
        dismissResults: (any DismissResultPersisting)? = nil
    ) {
        self.services = services
        link = WatchLink(transport: transport, clock: TestClock(), jitter: { 0 })
        host = RemoteHost(
            link: link, services: services, settings: settings, dismissResults: dismissResults, clock: { HostRig.now })
    }

    static func settings(readOnly: Bool = false, enabled: Bool = true) -> RemoteSettings {
        let prefs = WatchPreferences()
        return RemoteSettings(
            access: .init(
                phoneReadOnly: false, remotesReadOnly: readOnly, capabilities: .tslimX2, garminBolusEnabled: enabled),
            remoteSizeLimitUnits: nil, preferences: prefs)
    }

    func start() async {
        link.start()
        transport.handler?(.paired(true))
        transport.handler?(.deviceStatus(.connected))
        transport.handler?(.characteristicsDiscovered)
        await host.start()
        await settle()
    }

    func receive(_ message: RemoteMessage) async {
        transport.handler?(.received(message.wire))
        await settle()
    }

    func receive(fixture name: String) async {
        transport.handler?(.received(GoldenFixtures.fixtures.first { $0.name == name }!.wire))
        await settle()
    }

    /// Lets the host's tasks and the link's completions run.
    func settle() async {
        for _ in 0..<200 { await Task.yield() }
    }
}

func bolus(_ id: String, units mU: Int = 2000, sentAt: Int = GoldenFixtures.now - 5) -> RemoteMessage {
    .bolus(
        BolusRequestPayload(
            requestId: id, sentAt: sentAt, amount: .units(milliunits: mU), glucoseMgdl: nil, includeStaleGlucose: false)
    )
}

/// A ledger entry that has reached `delivered` or `failed`, through the ledger's own moves.
func entry(_ id: String, delivered: Double?, units: Double = 2) -> RemoteBolusLedger.Entry {
    var ledger = RemoteBolusLedger()
    let request = DoseRequest(
        id: id, origin: .remote(peerId: "garmin", sentAt: HostRig.now), shape: .now(units: units), carbsGrams: nil,
        bgMgdl: nil)
    _ = ledger.begin(request, usedIncludedStaleBG: false, now: HostRig.now)
    if let delivered {
        _ = ledger.markAccepted(request.ledgerKey, bolusId: 7, pumpKey: "p", pumpClock: nil, now: HostRig.now)
        _ = ledger.markDelivered(request.ledgerKey, units: delivered, now: HostRig.now)
    } else {
        _ = ledger.markFailed(request.ledgerKey, reason: "Pump not connected.", now: HostRig.now)
    }
    return ledger.entry(request.ledgerKey)!
}

func composed(_ id: String, units: Double = 2) -> ComposedDose {
    ComposedDose(
        request: DoseRequest(
            id: id, origin: .remote(peerId: "garmin", sentAt: HostRig.now), shape: .now(units: units), carbsGrams: nil,
            bgMgdl: nil), calculatorIOBUnits: nil, correctionGlucoseMgdl: nil, calculatorCarbUnits: nil,
        usedIncludedStaleGlucose: false, notices: [])
}
