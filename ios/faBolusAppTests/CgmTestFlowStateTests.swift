import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 09.20-04 (change 3, D-13 UX): pins the pure decision function behind the "Test" flow's
/// DETERMINATE waiting state. The Test action OBSERVES the selected source's already-running
/// production instance (`AppModel.glucoseSourceProbe`) rather than building a second ephemeral
/// central — so a reading already buffered when Test is tapped resolves `.success` INSTANTLY
/// (elapsed 0), sidestepping the dup-restore-id SIGABRT D-06 (Plan 03) fixed. Kept pure and
/// unit-testable, like `CgmCredentialsView.sourcesToTest` (`CgmSourceValidationTests`).
@MainActor
struct CgmTestFlowStateTests {

    /// A stand-in `GlucoseSource` for these tests — mirrors `GlucoseArbiterTests.MockGlucoseSource`
    /// (faBolusCoreTests).
    private final class StubGlucoseSource: GlucoseSource {
        let id = "stub"
        let priority = 100
        let connectionKind: GlucoseConnectionKind = .localBLE   // D-06: conformers must classify
        var latest: GlucoseSample?
        var history: [GlucoseReading] = []
        var status: GlucoseSourceStatus
        var onChange: (@MainActor () -> Void)?
        init(latest: GlucoseSample? = nil, status: GlucoseSourceStatus = .searching) {
            self.latest = latest; self.status = status
        }
        func start() async {}
        func stop() {}
    }

    private func sample(_ mgdl: Int = 120) -> GlucoseSample {
        // The failable init (D-05) never fails here — the default mgdl (120) is in-range.
        GlucoseSample(mgdl: mgdl, date: Date(), trend: .flat, sourceID: "stub")!
    }

    // MARK: - .success — a reading is already buffered

    @Test func bufferedSampleReturnsSuccessImmediately() {
        let stub = StubGlucoseSource(latest: sample(), status: .connected)
        let outcome = CgmCredentialsView.testOutcome(latest: stub.latest, status: stub.status,
                                                      elapsed: 0, timeout: 300)
        #expect(outcome == .success(stub.latest!))
    }

    // MARK: - .waiting — nothing yet, still within the window

    @Test func emptySourceWithinWindowReturnsWaiting() {
        let stub = StubGlucoseSource(latest: nil, status: .searching)
        let outcome = CgmCredentialsView.testOutcome(latest: stub.latest, status: stub.status,
                                                      elapsed: 60, timeout: 300)
        #expect(outcome == .waiting)
    }

    @Test func emptySourceAtElapsedZeroReturnsWaiting() {
        let stub = StubGlucoseSource(latest: nil, status: .searching)
        let outcome = CgmCredentialsView.testOutcome(latest: stub.latest, status: stub.status,
                                                      elapsed: 0, timeout: 300)
        #expect(outcome == .waiting)
    }

    // MARK: - .timeout — nothing after the window elapses

    @Test func emptySourcePastTimeoutReturnsTimeout() {
        let stub = StubGlucoseSource(latest: nil, status: .searching)
        let outcome = CgmCredentialsView.testOutcome(latest: stub.latest, status: stub.status,
                                                      elapsed: 301, timeout: 300)
        #expect(outcome == .timeout(detail: nil))
    }

    @Test func emptySourceExactlyAtTimeoutReturnsTimeout() {
        let stub = StubGlucoseSource(latest: nil, status: .searching)
        let outcome = CgmCredentialsView.testOutcome(latest: stub.latest, status: stub.status,
                                                      elapsed: 300, timeout: 300)
        #expect(outcome == .timeout(detail: nil))
    }

    // MARK: - .timeout with the error surfaced — a hard .error status short-circuits immediately

    @Test func hardErrorReturnsTimeoutWithErrorSurfacedRegardlessOfElapsed() {
        let stub = StubGlucoseSource(latest: nil, status: .error("connection refused"))
        let outcome = CgmCredentialsView.testOutcome(latest: stub.latest, status: stub.status,
                                                      elapsed: 5, timeout: 300)
        #expect(outcome == .timeout(detail: "connection refused"))
    }

    // MARK: - a buffered reading always wins, even past the timeout window

    @Test func bufferedSamplePastTimeoutStillReturnsSuccess() {
        let stub = StubGlucoseSource(latest: sample(140), status: .connected)
        let outcome = CgmCredentialsView.testOutcome(latest: stub.latest, status: stub.status,
                                                      elapsed: 999, timeout: 300)
        #expect(outcome == .success(stub.latest!))
    }

    // MARK: - D-06/D-09: the timeout WINDOW is keyed on the typed connectionKind, not id-string literals

    @Test func timeoutWindowIsKeyedOnConnectionKind() {
        // .localBLE keeps the already-correct ~6-min Dexcom wake-cycle window (PRESERVED — G6 + G7).
        #expect(AppModel.cgmTestTimeout(for: .localBLE) == 6 * 60)
        // .cloudPoll waits only for an auth + one network round-trip (~15–20s), never a radio cycle.
        #expect(AppModel.cgmTestTimeout(for: .cloudPoll) <= 30)
        #expect(AppModel.cgmTestTimeout(for: .cloudPoll) > 0)
        // .localOnDevice reads a shared on-device store — near-instant, and shorter than the BLE window.
        #expect(AppModel.cgmTestTimeout(for: .localOnDevice) < AppModel.cgmTestTimeout(for: .localBLE))
        #expect(AppModel.cgmTestTimeout(for: .localOnDevice) > 0)
    }

    // MARK: - D-09: waiting/timeout COPY is source-appropriate per category, never reusing BLE copy

    @Test func bleCopyMentionsTheWakeCycleAndDexcomApp() {
        let waiting = CgmCredentialsView.waitingHeadline(kind: .localBLE, sourceName: "Dexcom G7")
        #expect(waiting.contains("Dexcom app"))
        #expect(waiting.contains("~5 min"))
        let timeout = CgmCredentialsView.timeoutHeadline(kind: .localBLE, sourceName: "Dexcom G7", elapsedSeconds: 360)
        #expect(timeout.contains("Dexcom app"))
    }

    @Test func cloudCopyIsAuthNetworkFramedNotBLE() {
        let waiting = CgmCredentialsView.waitingHeadline(kind: .cloudPoll, sourceName: "Nightscout")
        // auth/network framing, and NEVER the BLE "sensor wake cycle" / "Dexcom app" language (F-12).
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
        let timeout = CgmCredentialsView.timeoutHeadline(kind: .localOnDevice, sourceName: "xDrip App Group", elapsedSeconds: 10)
        #expect(!timeout.contains("Dexcom app"))
        #expect(timeout.lowercased().contains("syncing"))
    }

    // MARK: - W-03: a mid-Test source change aborts the poll loop (which clears BOTH in-progress + outcome)

    @Test func testAbortsWhenSourceChangesMidTest() {
        // Started against "dexcom-g7-ble"; the live probe now reports a DIFFERENT source → abort.
        #expect(AppModel.cgmTestShouldAbort(startedSourceId: "dexcom-g7-ble", currentProbeId: "nightscout"))
    }

    @Test func testAbortsWhenSourceClearedMidTest() {
        // Failover deselected mid-Test → the probe is nil → abort (no frozen stale .waiting screen).
        #expect(AppModel.cgmTestShouldAbort(startedSourceId: "dexcom-g7-ble", currentProbeId: nil))
    }

    @Test func testDoesNotAbortWhileSourceUnchanged() {
        #expect(!AppModel.cgmTestShouldAbort(startedSourceId: "dexcom-g7-ble", currentProbeId: "dexcom-g7-ble"))
    }
}
