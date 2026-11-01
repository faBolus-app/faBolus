import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Pins the pure decision function behind the "Test" flow's DETERMINATE waiting state. The Test action
/// OBSERVES the selected source's already-running production instance (`AppModel.glucoseSourceProbe`)
/// rather than building a second ephemeral central — so a reading already buffered when Test is tapped
/// resolves `.success` INSTANTLY (elapsed 0), sidestepping the duplicate-restore-id SIGABRT a second
/// central caused. Kept pure and unit-testable, like `CgmCredentialsView.sourcesToTest`
/// (`CgmSourceValidationTests`).
@MainActor
struct CgmTestFlowStateTests {

    /// A stand-in `GlucoseSource` for these tests — mirrors `GlucoseArbiterTests.MockGlucoseSource`
    /// (faBolusCoreTests).
    private final class StubGlucoseSource: GlucoseSource {
        let id = "stub"
        let priority = 100
        let connectionKind: GlucoseConnectionKind = .localBLE  // conformers must classify
        var latest: GlucoseSample?
        var history: [GlucoseReading] = []
        var status: GlucoseSourceStatus
        var onChange: (@MainActor () -> Void)?
        init(latest: GlucoseSample? = nil, status: GlucoseSourceStatus = .searching) {
            self.latest = latest
            self.status = status
        }
        func start() async {}
        func stop() {}
    }

    private func sample(_ mgdl: Int = 120) -> GlucoseSample {
        // The failable init never fails here — the default mgdl (120) is in-range.
        GlucoseSample(mgdl: mgdl, date: Date(), trend: .flat, sourceID: "stub")!
    }

    // MARK: - .success — a reading is already buffered

    @Test func bufferedSampleReturnsSuccessImmediately() {
        let stub = StubGlucoseSource(latest: sample(), status: .connected)
        let outcome = CgmTestOutcome.testOutcome(
            latest: stub.latest, status: stub.status,
            elapsed: 0, timeout: 300)
        #expect(outcome == .success(stub.latest!))
    }

    // MARK: - .waiting — nothing yet, still within the window

    @Test func emptySourceWithinWindowReturnsWaiting() {
        let stub = StubGlucoseSource(latest: nil, status: .searching)
        let outcome = CgmTestOutcome.testOutcome(
            latest: stub.latest, status: stub.status,
            elapsed: 60, timeout: 300)
        #expect(outcome == .waiting)
    }

    @Test func emptySourceAtElapsedZeroReturnsWaiting() {
        let stub = StubGlucoseSource(latest: nil, status: .searching)
        let outcome = CgmTestOutcome.testOutcome(
            latest: stub.latest, status: stub.status,
            elapsed: 0, timeout: 300)
        #expect(outcome == .waiting)
    }

    // MARK: - .timeout — nothing after the window elapses

    @Test func emptySourcePastTimeoutReturnsTimeout() {
        let stub = StubGlucoseSource(latest: nil, status: .searching)
        let outcome = CgmTestOutcome.testOutcome(
            latest: stub.latest, status: stub.status,
            elapsed: 301, timeout: 300)
        #expect(outcome == .timeout(detail: nil))
    }

    @Test func emptySourceExactlyAtTimeoutReturnsTimeout() {
        let stub = StubGlucoseSource(latest: nil, status: .searching)
        let outcome = CgmTestOutcome.testOutcome(
            latest: stub.latest, status: stub.status,
            elapsed: 300, timeout: 300)
        #expect(outcome == .timeout(detail: nil))
    }

    // MARK: - .timeout with the error surfaced — a hard .error status short-circuits immediately

    @Test func hardErrorReturnsTimeoutWithErrorSurfacedRegardlessOfElapsed() {
        let stub = StubGlucoseSource(latest: nil, status: .error("connection refused"))
        let outcome = CgmTestOutcome.testOutcome(
            latest: stub.latest, status: stub.status,
            elapsed: 5, timeout: 300)
        #expect(outcome == .timeout(detail: "connection refused"))
    }

    // MARK: - a buffered reading always wins, even past the timeout window

    @Test func bufferedSamplePastTimeoutStillReturnsSuccess() {
        let stub = StubGlucoseSource(latest: sample(140), status: .connected)
        let outcome = CgmTestOutcome.testOutcome(
            latest: stub.latest, status: stub.status,
            elapsed: 999, timeout: 300)
        #expect(outcome == .success(stub.latest!))
    }

    // MARK: - The timeout WINDOW is keyed on the typed connectionKind, not id-string literals

    @Test func timeoutWindowIsKeyedOnConnectionKind() {
        // .localBLE keeps the already-correct ~6-min Dexcom wake-cycle window (PRESERVED — G6 + G7).
        #expect(CgmTestCoordinator.cgmTestTimeout(for: .localBLE) == 6 * 60)
        // .cloudPoll waits only for an auth + one network round-trip (~15–20s), never a radio cycle.
        #expect(CgmTestCoordinator.cgmTestTimeout(for: .cloudPoll) <= 30)
        #expect(CgmTestCoordinator.cgmTestTimeout(for: .cloudPoll) > 0)
        // .localOnDevice reads a shared on-device store — near-instant, and shorter than the BLE window.
        #expect(
            CgmTestCoordinator.cgmTestTimeout(for: .localOnDevice) < CgmTestCoordinator.cgmTestTimeout(for: .localBLE))
        #expect(CgmTestCoordinator.cgmTestTimeout(for: .localOnDevice) > 0)
    }

    // MARK: - waiting/timeout COPY is source-appropriate per category, never reusing BLE copy

    @Test func bleCopyMentionsTheWakeCycleAndDexcomApp() {
        let waiting = CgmCredentialsView.waitingHeadline(kind: .localBLE, sourceName: "Dexcom G7")
        #expect(waiting.contains("Dexcom app"))
        #expect(waiting.contains("~5 min"))
        let timeout = CgmCredentialsView.timeoutHeadline(kind: .localBLE, sourceName: "Dexcom G7", elapsedSeconds: 360)
        #expect(timeout.contains("Dexcom app"))
    }

    @Test func cloudCopyIsAuthNetworkFramedNotBLE() {
        let waiting = CgmCredentialsView.waitingHeadline(kind: .cloudPoll, sourceName: "Nightscout")
        // auth/network framing, and NEVER the BLE "sensor wake cycle" / "Dexcom app" language.
        #expect(waiting.contains("Nightscout"))
        #expect(!waiting.contains("Dexcom app"))
        #expect(!waiting.lowercased().contains("wake cycle"))
        #expect(!waiting.lowercased().contains("sensor"))
        let timeout = CgmCredentialsView.timeoutHeadline(kind: .cloudPoll, sourceName: "Nightscout", elapsedSeconds: 20)
        #expect(!timeout.contains("Dexcom app"))
        #expect(timeout.lowercased().contains("password") || timeout.lowercased().contains("connection"))
    }

    @Test func localOnDeviceCopyIsSyncFramedNotBLE() {
        let waiting = CgmCredentialsView.waitingHeadline(kind: .localOnDevice, sourceName: "xDrip App Group")
        #expect(waiting.contains("xDrip App Group"))
        #expect(!waiting.contains("Dexcom app"))
        #expect(!waiting.lowercased().contains("wake cycle"))
        let timeout = CgmCredentialsView.timeoutHeadline(
            kind: .localOnDevice, sourceName: "xDrip App Group", elapsedSeconds: 10)
        #expect(!timeout.contains("Dexcom app"))
        #expect(timeout.lowercased().contains("syncing"))
    }

    // MARK: - A mid-Test source change aborts the poll loop (which clears BOTH in-progress + outcome)

    @Test func testAbortsWhenSourceChangesMidTest() {
        // Started against "dexcom-g7-ble"; the live probe now reports a DIFFERENT source → abort.
        #expect(CgmTestCoordinator.cgmTestShouldAbort(startedSourceId: "dexcom-g7-ble", currentProbeId: "nightscout"))
    }

    @Test func testAbortsWhenSourceClearedMidTest() {
        // Failover deselected mid-Test → the probe is nil → abort (no frozen stale .waiting screen).
        #expect(CgmTestCoordinator.cgmTestShouldAbort(startedSourceId: "dexcom-g7-ble", currentProbeId: nil))
    }

    @Test func testDoesNotAbortWhileSourceUnchanged() {
        #expect(
            !CgmTestCoordinator.cgmTestShouldAbort(startedSourceId: "dexcom-g7-ble", currentProbeId: "dexcom-g7-ble"))
    }

    // MARK: - Drive CgmTestCoordinator directly (not the view), proving the extracted state machine
    // reproduces AppModel's pre-move transitions exactly, under an injected clock (no wall-clock
    // Date()/Task.sleep needed to make these deterministic).

    private func makeCoordinator(
        probeId: String = "dexcom-g7-ble",
        connectionKind: GlucoseConnectionKind = .cloudPoll,
        latest: GlucoseSample?,
        status: GlucoseSourceStatus
    ) -> CgmTestCoordinator {
        let coordinator = CgmTestCoordinator()
        coordinator.probe = { (id: probeId, connectionKind: connectionKind, latest: latest, status: status) }
        return coordinator
    }

    /// `startCgmTest -> .waiting -> .success`: `performTick` (the pure per-tick decision, extracted
    /// so this is testable without racing the async `Task` loop) transitions from `.waiting` (nothing
    /// buffered yet) to `.success` (a reading now buffered) across two ticks against the SAME started
    /// source/timeout, exactly mirroring pre-move `AppModel.startCgmTest`'s poll body.
    @Test func performTickTransitionsFromWaitingToSuccessOnScriptedProbe() {
        let coordinator = makeCoordinator(latest: nil, status: .searching)
        let startedAt = Date()
        coordinator.now = { startedAt }  // no elapsed time passes between ticks
        let firstDone = coordinator.performTick(startedSourceId: "dexcom-g7-ble", startedAt: startedAt, timeout: 300)
        #expect(!firstDone)
        #expect(coordinator.state.outcome == .waiting)
        #expect(coordinator.state.inProgress == false)  // performTick alone never flips inProgress on .waiting

        let sample = sample(150)
        coordinator.probe = { (id: "dexcom-g7-ble", connectionKind: .cloudPoll, latest: sample, status: .connected) }
        let secondDone = coordinator.performTick(startedSourceId: "dexcom-g7-ble", startedAt: startedAt, timeout: 300)
        #expect(secondDone)
        #expect(coordinator.state.outcome == .success(sample))
        #expect(coordinator.state.inProgress == false)
    }

    /// Force timeout via the injected clock: `now()` reports past the timeout window with
    /// nothing buffered -> `.timeout`, and `performTick` reports the run as terminal (`done == true`).
    @Test func performTickReturnsTimeoutOnceTheInjectedClockPassesTheWindow() {
        let coordinator = makeCoordinator(latest: nil, status: .searching)
        let startedAt = Date()
        coordinator.now = { startedAt.addingTimeInterval(301) }
        let done = coordinator.performTick(startedSourceId: "dexcom-g7-ble", startedAt: startedAt, timeout: 300)
        #expect(done)
        #expect(coordinator.state.outcome == .timeout(detail: nil))
        #expect(coordinator.state.inProgress == false)
    }

    /// The abort path returns to idle: a `performTick` whose live probe id no longer matches the
    /// started source clears BOTH `inProgress` and `outcome` and reports terminal — the same "no
    /// frozen stale .waiting screen" contract `AppModel.startCgmTest`'s poll body enforced inline.
    @Test func performTickAbortsToIdleWhenProbeSourceChangesMidRun() {
        let coordinator = makeCoordinator(probeId: "nightscout", latest: nil, status: .searching)
        let startedAt = Date()
        coordinator.now = { startedAt }
        // Seed a non-idle state first, so the abort is a genuine transition back to idle.
        _ = coordinator.performTick(startedSourceId: "nightscout", startedAt: startedAt, timeout: 300)
        let done = coordinator.performTick(startedSourceId: "dexcom-g7-ble", startedAt: startedAt, timeout: 300)
        #expect(done)
        #expect(coordinator.state.inProgress == false)
        #expect(coordinator.state.outcome == nil)
    }

    /// End-to-end wiring characterization: `start()` observing an ALREADY-buffered reading resolves
    /// `.success` on the very first real (async) poll tick — the exact "an already-buffered reading
    /// resolves instantly" contract `AppModel.startCgmTest`'s doc comment describes — proving the
    /// `Task` loop built on `performTick` behaves identically to driving `performTick` directly.
    @Test func startResolvesSuccessImmediatelyWhenAReadingIsAlreadyBuffered() async {
        let bufferedSample = sample(140)
        let coordinator = makeCoordinator(latest: bufferedSample, status: .connected)
        coordinator.start()
        await coordinator.waitForPollTaskToFinish()
        #expect(coordinator.state.outcome == .success(bufferedSample))
        #expect(coordinator.state.inProgress == false)
    }

    /// `start()` with no probe (no fallback source selected) reports `.timeout` synchronously, before
    /// any `Task` is even spawned — mirrors the pre-move guard clause in `AppModel.startCgmTest`.
    @Test func startWithNoProbeReportsTimeoutImmediately() {
        let coordinator = CgmTestCoordinator()  // default probe closure returns nil
        coordinator.start()
        #expect(coordinator.state.outcome == .timeout(detail: "No fallback source is selected."))
        #expect(coordinator.state.inProgress == false)
        #expect(coordinator.state.timeoutSeconds == 0)
    }
}
