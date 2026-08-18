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
        GlucoseSample(mgdl: mgdl, date: Date(), trend: .flat, sourceID: "stub")
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
}
