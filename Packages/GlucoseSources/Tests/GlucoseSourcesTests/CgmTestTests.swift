import Foundation
import Testing
import faBolusCore

@testable import GlucoseSources

/// The CGM test from settings: a determinate wait on the running source.
@MainActor
@Suite("CGM test")
struct CgmTestTests {
    func sample(_ mgdl: Int = 120) -> GlucoseSample {
        GlucoseSample(mgdl: mgdl, date: t0, trend: .flat, sourceID: "stub")!
    }

    @Test("a held reading succeeds at once, even past the timeout")
    func heldReadingSucceeds() {
        #expect(
            CgmTestOutcome.testOutcome(latest: sample(), status: .connected, elapsed: 0, timeout: 300)
                == .success(sample()))
        #expect(
            CgmTestOutcome.testOutcome(latest: sample(140), status: .connected, elapsed: 999, timeout: 300)
                == .success(sample(140)))
    }

    @Test("nothing yet within the window waits; at or past it, times out")
    func waitingThenTimeout() {
        #expect(CgmTestOutcome.testOutcome(latest: nil, status: .searching, elapsed: 0, timeout: 300) == .waiting)
        #expect(CgmTestOutcome.testOutcome(latest: nil, status: .searching, elapsed: 60, timeout: 300) == .waiting)
        #expect(
            CgmTestOutcome.testOutcome(latest: nil, status: .searching, elapsed: 300, timeout: 300)
                == .timeout(detail: nil))
        #expect(
            CgmTestOutcome.testOutcome(latest: nil, status: .searching, elapsed: 301, timeout: 300)
                == .timeout(detail: nil))
    }

    @Test("a source that says why it can't read ends the test with that reason")
    func problemEndsAtOnce() {
        #expect(
            CgmTestOutcome.testOutcome(latest: nil, status: .unavailable(.bluetoothOff), elapsed: 5, timeout: 300)
                == .timeout(detail: "Bluetooth is off."))
        #expect(
            CgmTestOutcome.testOutcome(latest: nil, status: .needsSetup, elapsed: 0, timeout: 20)
                == .timeout(detail: "Not set up yet."))
    }

    @Test("the window depends on how the source connects")
    func windows() {
        #expect(CgmTestCoordinator.timeout(for: .localBLE) == 6 * 60)
        #expect(CgmTestCoordinator.timeout(for: .cloudPoll) <= 30)
        #expect(CgmTestCoordinator.timeout(for: .cloudPoll) > 0)
        #expect(CgmTestCoordinator.timeout(for: .localOnDevice) < CgmTestCoordinator.timeout(for: .localBLE))
    }

    @Test("Bluetooth copy names the Dexcom app and its cycle; cloud and on-device copy never do")
    func copy() {
        let ble = CgmTestCoordinator.waitingHeadline(kind: .localBLE, sourceName: "Dexcom G7")
        #expect(ble.contains("Dexcom app"))
        #expect(ble.contains("5 min"))
        #expect(
            CgmTestCoordinator.timeoutHeadline(kind: .localBLE, sourceName: "Dexcom G7", elapsedSeconds: 360)
                .contains("Dexcom app"))
        let cloud = CgmTestCoordinator.waitingHeadline(kind: .cloudPoll, sourceName: "Dexcom Share")
        #expect(cloud.contains("Dexcom Share"))
        #expect(!cloud.contains("Dexcom app"))
        #expect(!cloud.lowercased().contains("sensor"))
        let cloudTimeout = CgmTestCoordinator.timeoutHeadline(
            kind: .cloudPoll, sourceName: "Dexcom Share", elapsedSeconds: 20)
        #expect(cloudTimeout.lowercased().contains("password"))
        let local = CgmTestCoordinator.timeoutHeadline(kind: .localOnDevice, sourceName: "xDrip", elapsedSeconds: 10)
        #expect(local.lowercased().contains("syncing"))
        #expect(!local.contains("Dexcom app"))
    }

    @Test("the test stops if the running source changes or is cleared")
    func abort() {
        #expect(CgmTestCoordinator.shouldAbort(startedSourceID: "dexcom-g7", currentProbeID: "dexcom-share"))
        #expect(CgmTestCoordinator.shouldAbort(startedSourceID: "dexcom-g7", currentProbeID: nil))
        #expect(!CgmTestCoordinator.shouldAbort(startedSourceID: "dexcom-g7", currentProbeID: "dexcom-g7"))
    }

    func probe(_ id: String = "dexcom-g7", latest: GlucoseSample?, status: GlucoseSourceStatus)
        -> CgmTestCoordinator.Probe
    {
        CgmTestCoordinator.Probe(
            id: id, connectionKind: .cloudPoll, state: GlucoseSourceState(latest: latest, status: status))
    }

    @Test("ticks move from waiting to success against the same source")
    func tickWaitingToSuccess() async {
        let coordinator = CgmTestCoordinator()
        var current = probe(latest: nil, status: .searching)
        coordinator.probe = { current }
        coordinator.now = { t0 }
        #expect(!(await coordinator.performTick(startedSourceID: "dexcom-g7", startedAt: t0, timeout: 300)))
        #expect(coordinator.state.outcome == .waiting)
        current = probe(latest: sample(150), status: .connected)
        #expect(await coordinator.performTick(startedSourceID: "dexcom-g7", startedAt: t0, timeout: 300))
        #expect(coordinator.state.outcome == .success(sample(150)))
        #expect(!coordinator.state.inProgress)
    }

    @Test("past the window on the injected clock: timeout")
    func tickTimeout() async {
        let coordinator = CgmTestCoordinator()
        coordinator.probe = { self.probe(latest: nil, status: .searching) }
        coordinator.now = { t0.addingTimeInterval(301) }
        #expect(await coordinator.performTick(startedSourceID: "dexcom-g7", startedAt: t0, timeout: 300))
        #expect(coordinator.state.outcome == .timeout(detail: nil))
    }

    @Test("a source change mid-test returns to idle, leaving no frozen waiting state")
    func tickAbort() async {
        let coordinator = CgmTestCoordinator()
        coordinator.probe = { self.probe("dexcom-share", latest: nil, status: .searching) }
        coordinator.now = { t0 }
        _ = await coordinator.performTick(startedSourceID: "dexcom-share", startedAt: t0, timeout: 300)
        #expect(await coordinator.performTick(startedSourceID: "dexcom-g7", startedAt: t0, timeout: 300))
        #expect(!coordinator.state.inProgress)
        #expect(coordinator.state.outcome == nil)
    }

    @Test("start: a reading the running source already has resolves on the first tick")
    func startWithHeldReading() async {
        let coordinator = CgmTestCoordinator()
        let held = sample(140)
        coordinator.probe = { self.probe(latest: held, status: .connected) }
        await coordinator.start()
        await coordinator.waitForPollTask()
        #expect(coordinator.state.outcome == .success(held))
        #expect(!coordinator.state.inProgress)
    }

    @Test("start with no source selected ends at once and says so")
    func startWithoutSource() async {
        let coordinator = CgmTestCoordinator()
        await coordinator.start()
        #expect(coordinator.state.outcome == .timeout(detail: "No backup source is selected."))
        #expect(!coordinator.state.inProgress)
        coordinator.failoverAutoDisabled = { true }
        await coordinator.start()
        #expect(coordinator.state.outcome?.isPausedTimeout == true)
    }

    @Test("the test runs against a real source's state")
    func probeOfSource() async {
        let source = PollingGlucoseSource(
            id: "dexcom-share", priority: 20, poller: ScriptedPoller([]), clock: { t0 },
            sleep: RecordingSleep().function)
        await source.ingest(GlucosePoll(samples: [sample(118)]))
        let probe = await CgmTestCoordinator.Probe.of(source)
        #expect(probe.id == "dexcom-share")
        #expect(probe.connectionKind == .cloudPoll)
        #expect(probe.state.latest?.mgdl == 118)
    }
}

extension CgmTestOutcome {
    fileprivate var isPausedTimeout: Bool {
        if case .timeout(let detail?) = self { return detail.contains("paused") }
        return false
    }
}

/// The badge shown while a backup source's reading is live.
@Suite("Failover badge")
struct FailoverBadgePresenterTests {
    let names = GlucoseSourceRegistry(settings: isolatedSettings(), secrets: InMemorySecretStore())

    func name(_ id: String) -> String? { names.descriptor(id: id)?.name }

    @Test func pumpHasNoBadge() {
        #expect(FailoverBadgePresenter.failoverBadge(provenance: .pump, name: name) == nil)
    }

    @Test func registeredSourceReasons() {
        let missing = FailoverBadgePresenter.failoverBadge(
            provenance: .failover(sourceID: "dexcom-share", reason: .pumpMissing), name: name)
        #expect(missing?.name == "Dexcom Share")
        #expect(missing?.reason == "Showing Dexcom Share (cloud) — the pump has no CGM reading.")
        let stale = FailoverBadgePresenter.failoverBadge(
            provenance: .failover(sourceID: "dexcom-g6", reason: .pumpStale), name: name)
        #expect(stale?.name == "Dexcom G6")
        #expect(stale?.reason == "Showing Dexcom G6 (direct Bluetooth) — the pump's CGM reading went stale.")
    }

    @Test func unknownSourceShowsItsID() {
        let badge = FailoverBadgePresenter.failoverBadge(
            provenance: .failover(sourceID: "mystery", reason: .pumpStale), name: name)
        #expect(badge?.name == "mystery")
        #expect(badge?.reason == "Showing mystery — the pump's CGM reading went stale.")
    }

    @Test func shortNames() {
        #expect(FailoverBadgePresenter.shortSourceName("Dexcom Share (cloud)") == "Dexcom Share")
        #expect(FailoverBadgePresenter.shortSourceName("Dexcom G7 / ONE+ (direct BLE)") == "Dexcom G7")
        #expect(FailoverBadgePresenter.shortSourceName("Nightscout — self-hosted") == "Nightscout")
        #expect(FailoverBadgePresenter.shortSourceName("LibreLinkUp") == "LibreLinkUp")
    }
}
