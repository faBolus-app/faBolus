import Testing
import Foundation
import TandemBLE
import TandemMessages
import faBolusCore
@testable import faBolus

/// GO-2 Step 2 (16-09, REMED-16, CX-A-03) — scripted-lifecycle characterization, authored against CURRENT
/// (pre-move) `TandemBackend` behavior and committed GREEN as the wall `PumpConnectionLifecycle`'s
/// extraction (Task 2) must stay green against, byte-for-byte.
///
/// **Review concern #5 (the reason this suite exists):** `linkDroppedCleanup()` is a single, safety-
/// critical, ORDERED teardown sequence — waiter resume → `failPumpWaiters` → history → the three
/// TandemBackend-owned resets → scheduler stop/advance → `coordinator = nil` → `authenticationKey = []`
/// → `cancelPairingWatchdog()`. A reorder here (e.g. clearing the auth key BEFORE `failPumpWaiters` runs,
/// or cancelling the watchdog before the coordinator is cleared) could leave a signed continuation
/// resolved against a half-torn-down session. Final-state assertions alone (`isPairedForTesting == false`,
/// etc.) cannot catch a reorder that still lands on the same final values — so this suite adds an ORDERED
/// event recorder (`onLinkDroppedCleanupStepForTesting`, a new DEBUG-only diagnostic closure fired at each
/// step inside `linkDroppedCleanup()` — see the "Deviations" section of this plan's SUMMARY) and asserts
/// the exact sequence, not just the end state.
@Suite(.serialized) @MainActor
struct PumpConnectionLifecycleCharacterizationTests {
    private func backend() -> TandemBackend { TandemBackend(testTransport: FakePumpTransport()) }

    /// The exact teardown order `linkDroppedCleanup()` runs today (TandemBackend.swift, current
    /// numbering) — the wall Task 2's extraction must reproduce byte-for-byte.
    private static let expectedTeardownOrder = [
        "completeGlucoseRead", "completeCalcInputRead", "failPumpWaiters", "historyLinkDropped",
        "historyStatusReset", "detectedIsMobiReset", "pumpFeatureBitsReset", "stopAllTimers",
        "notePollCycleEnded", "coordinatorCleared", "authKeyCleared", "cancelPairingWatchdog",
    ]

    // MARK: - Call-order recorder (review concern #5)

    /// The CR-02 "unintended drop surfaces as `.connecting`" path: `applyClientState(.connecting)` from a
    /// live link must run the FULL teardown, in the exact documented order.
    @Test func dropToConnectingFromLiveRunsTeardownInExactOrder() {
        let b = backend()
        b.setConnectionForTesting(.connected)
        var recorded: [String] = []
        b.onLinkDroppedCleanupStepForTesting = { recorded.append($0) }

        b.applyClientState(.connecting)

        #expect(recorded == Self.expectedTeardownOrder,
                "the teardown call order must be byte-identical to the pre-move sequence")
        #expect(b.snapshot.connection == .connecting)
    }

    /// A plain terminal disconnect (`.disconnected`/radio-down states) must run the SAME exact order.
    @Test func plainDisconnectRunsTeardownInExactOrder() {
        let b = backend()
        b.setConnectionForTesting(.connected)
        var recorded: [String] = []
        b.onLinkDroppedCleanupStepForTesting = { recorded.append($0) }

        b.applyClientState(.disconnected)

        #expect(recorded == Self.expectedTeardownOrder)
        #expect(b.snapshot.connection == .disconnected)
    }

    /// `.reconnectExhausted` (the ladder gave up) must run the SAME exact order too — `.error` is a
    /// distinct DISPLAY state, but the underlying teardown sequence is identical.
    @Test func reconnectExhaustedRunsTeardownInExactOrder() {
        let b = backend()
        b.setConnectionForTesting(.connected)
        var recorded: [String] = []
        b.onLinkDroppedCleanupStepForTesting = { recorded.append($0) }

        b.applyClientState(.reconnectExhausted)

        #expect(recorded == Self.expectedTeardownOrder)
        #expect(b.snapshot.connection == .error)
    }

    /// Radio-down fail-closed states (`.poweredOff`/`.unauthorized`/`.unsupported`/`.resetting`) route
    /// through the exact same teardown order as a plain disconnect — pinned once, representatively, for
    /// `.poweredOff`.
    @Test func radioDownStateRunsTeardownInExactOrder() {
        let b = backend()
        b.setConnectionForTesting(.connected)
        var recorded: [String] = []
        b.onLinkDroppedCleanupStepForTesting = { recorded.append($0) }

        b.applyClientState(.poweredOff)

        #expect(recorded == Self.expectedTeardownOrder)
        #expect(b.snapshot.connection == .disconnected)
        #expect(b.snapshot.connectionDetail == "Bluetooth is off")
    }

    // MARK: - Reentrancy: duplicate/late callbacks after teardown

    /// A stray `.connecting` from a NOT-live state (right after a real teardown already ran) must NOT
    /// re-run `linkDroppedCleanup()` — the wasLive guard must stay a no-op here, both pre- and post-move.
    @Test func strayConnectingAfterDisconnectedDoesNotReRunTeardown() {
        let b = backend()
        b.setConnectionForTesting(.connected)
        var recorded: [String] = []
        b.onLinkDroppedCleanupStepForTesting = { recorded.append($0) }

        b.applyClientState(.disconnected)              // real teardown #1
        #expect(recorded == Self.expectedTeardownOrder, "precondition: the first drop ran the full teardown")
        recorded.removeAll()

        b.applyClientState(.connecting)                // NOT live (we are already .disconnected) — must be a no-op
        #expect(recorded.isEmpty, "a not-live climb into .connecting must not re-run the teardown a second time")
        #expect(b.snapshot.connection == .connecting)
    }

    /// A late AUTHORIZATION frame that arrives AFTER `linkDroppedCleanup()` has cleared the coordinator
    /// must be a fail-closed no-op — it cannot advance a torn-down handshake. Mirrors
    /// `ForgetPairingTeardownTests.aLateAuthorizationFrameCannotAdvanceTheTornDownCoordinator`, but via a
    /// REAL link-drop teardown (not an explicit `forgetPairing()`).
    @Test func lateAuthorizationFrameAfterLinkDropCannotAdvanceATornDownCoordinator() {
        let b = backend()
        b.setConnectionForTesting(.connected)
        var sends: [(typeName: String, opcode: UInt8, cargoBytes: Int)] = []
        b.onPairingSendForTesting = { typeName, opcode, cargoBytes in sends.append((typeName, opcode, cargoBytes)) }
        b.beginPairingForTesting(code: "abcd1234ijkl5678")   // valid 16-char → legacy V1 handshake
        #expect(sends.count == 1, "precondition: the handshake sent its first message")
        #expect(b.pairingCoordinatorIsLiveForTesting, "precondition: the coordinator is live")

        b.applyClientState(.disconnected)               // the real link-drop teardown
        #expect(b.pairingCoordinatorIsLiveForTesting == false, "the coordinator must be torn down by the drop")
        sends.removeAll()

        // The pump's would-be-next AUTHORIZATION reply in the V1 handshake — fully framed + CRC-16'd, so
        // it PASSES the CRC gate and reaches `coordinator?.handle(frame:)`; the ONLY thing stopping it
        // from advancing is that the coordinator is nil.
        let lateChallengeResponse = FakePumpTransport.frame(
            opCode: 17, cargo: [UInt8](repeating: 0, count: 30), signed: false)
        b.injectAuthorizationFrameForTesting(lateChallengeResponse)

        #expect(sends.isEmpty, "a torn-down coordinator must not emit a further pairing send")
        #expect(b.isPairedForTesting == false, "no stray pairing progress after the drop")
    }

    // MARK: - Watchdog arm/fire/cancel (reuses the existing pairingTimeoutSecForTesting/
    // firePairingWatchdogForTesting seams — PairingWatchdogTests/ResumeRetryTests already pin the full
    // behavior; this is the scripted-lifecycle harness's own representative pin so a Task 2 regression
    // shows up in THIS suite too, not only the pre-existing ones).

    @Test func watchdogTimeoutFailsClosedAndCancelIsIdempotent() {
        let b = TandemBackend(testTransport: FakePumpTransport(), authKey: [])
        b.pairingTimeoutSecForTesting = 0.05
        b.beginPairingForTesting(code: "123456")   // fresh JPAKE
        #expect(b.pairingCoordinatorIsLiveForTesting)

        b.firePairingWatchdogForTesting()
        #expect(b.snapshot.connection == .error)
        #expect(!b.isPairedForTesting)
        #expect(!b.pairingCoordinatorIsLiveForTesting)

        // A second, late fire (defensive no-op — mirrors `firePairingWatchdog`'s own `guard !isPaired`,
        // and cancel-then-cancel-again must never crash).
        b.firePairingWatchdogForTesting()
        #expect(b.snapshot.connection == .error, "a stray second watchdog fire must not change the outcome")
    }

    // MARK: - Mid-delivery drop still routes to indeterminate + holds the lock (delivery-lock preservation)

    private let bolusId = 5678
    private func capture(_ op: () async throws -> Double) async -> Error? {
        do { _ = try await op(); return nil } catch { return error }
    }
    private func isIndeterminate(_ e: Error?) -> Bool { (e as? BolusError)?.isIndeterminate ?? false }

    @Test func midDeliveryLinkDropStillRoutesToIndeterminateAndHoldsTheLock() async {
        let fake = FakePumpTransport()
        let b = TandemBackend(testTransport: fake)
        b.deliveryPollTimeoutOverride = 1.2
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        fake.script(BolusPermissionResponse.props.opCode, .frame(FakePumpTransport.permissionGranted(bolusId: bolusId)))
        fake.script(InitiateBolusResponse.props.opCode, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
        fake.script(CurrentBolusStatusResponse.props.opCode,
                    .frame(FakePumpTransport.currentBolusStatus(statusId: 1, bolusId: bolusId)))

        var recorded: [String] = []
        b.onLinkDroppedCleanupStepForTesting = { recorded.append($0) }
        fake.willAwait = { [weak b] op in
            if op == CurrentBolusStatusResponse.props.opCode { b?.applyClientState(.disconnected) }
        }

        let e = await capture { try await b.deliverBolus(units: 1.5, carbsGrams: nil, bgMgdl: nil, iobUnits: nil) }

        #expect(isIndeterminate(e), "a mid-delivery link drop is an indeterminate outcome")
        #expect(b.deliveryOutcomeUnknown, "the indeterminate delivery holds the global block")
        #expect(recorded == Self.expectedTeardownOrder,
                "the mid-delivery drop must run the same teardown order as any other link drop")
    }

    // MARK: - CRC gate + ResponseParser.parse + HMAC handoff MUST STAY in TandemBackend

    /// Static source scan: `didReceiveFrame`'s `.authorization` CRC gate + `ResponseParser.parse` + HMAC
    /// handoff (the parse-authentication seam) must remain physically inside `TandemBackend.swift` — this
    /// plan moves the connection/pairing-lifecycle ORCHESTRATION out, never this seam.
    @Test func crcGateAndResponseParserStayPhysicallyInTandemBackend() throws {
        let source = try Self.readSource(relativeTo: "ios/faBolus/Data/TandemBackend.swift")
        let body = try Self.balancedFunctionBody(
            signaturePrefix: "public func pumpClient(_ c: PumpBLEClient, didReceiveFrame frame: [UInt8], on ch: Characteristic) {",
            in: source)
        #expect(body.contains("calculateCRC16"), "the CRC-16 gate must still live in TandemBackend.swift's didReceiveFrame")
        #expect(body.contains("ResponseParser.parse"), "ResponseParser.parse must still live in TandemBackend.swift's didReceiveFrame")
    }

    // MARK: - setDeviceContext(model:apiVersion: nil) preserved byte-for-byte (VA-06 stays deferred)

    /// Tolerant of the model detection body's location (`TandemBackend.swift` pre-move,
    /// `PumpConnectionLifecycle.swift` post-move — GO-2 Step 2 moves `didDiscover`'s model detection) —
    /// asserts the exact literal call form appears in at least one of the two, so this single test file
    /// needs no edit across Task 1 → Task 2.
    ///
    /// CC-06/C1 (REMED-15.5, 15.5-02): the needle was updated to include the now-REQUIRED `trusted:`
    /// parameter (`PumpBLEClient.setDeviceContext` gained it in 15.5-01) — `apiVersion: nil` itself is
    /// still the byte-for-byte-preserved fact this test pins (CX-T-04 stays deferred); `trusted: true` is
    /// correct here because `didDiscover`'s BLE-name detection is the authoritative, TRUSTED source.
    @Test func setDeviceContextApiVersionStaysNilByteForByte() throws {
        let needle = "c.setDeviceContext(model: isMobi ? .mobi : .tslim, apiVersion: nil, trusted: true)"
        let backendSource = try Self.readSource(relativeTo: "ios/faBolus/Data/TandemBackend.swift")
        let lifecycleSource = try? Self.readSource(relativeTo: "ios/faBolus/Data/App/PumpConnectionLifecycle.swift")
        let found = backendSource.contains(needle) || (lifecycleSource?.contains(needle) ?? false)
        #expect(found, "setDeviceContext(model:apiVersion: nil, trusted:) must keep apiVersion nil — VA-06/CX-T-04 stays deferred")
    }

    // MARK: - Source-scan helpers (mirrors HistoryLogSyncDeliveryBoundaryTests' established pattern)

    private static func readSource(relativeTo path: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()   // drop the filename → .../ios/faBolusAppTests
            .deletingLastPathComponent()   // → .../ios
            .deletingLastPathComponent()   // → repo root
        return try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private static func balancedFunctionBody(signaturePrefix: String, in source: String) throws -> String {
        let lines = source.components(separatedBy: "\n")
        guard let startIdx = lines.firstIndex(where: { $0.contains(signaturePrefix) }) else {
            throw SliceError.signatureNotFound(signaturePrefix)
        }
        var depth = 0
        var opened = false
        var collected: [String] = []
        for line in lines[startIdx...] {
            collected.append(line)
            for ch in line {
                if ch == "{" { depth += 1; opened = true }
                else if ch == "}" { depth -= 1 }
            }
            if opened && depth <= 0 { break }
        }
        guard opened else { throw SliceError.unbalancedBraces(signaturePrefix) }
        return collected.joined(separator: "\n")
    }

    private enum SliceError: Error, CustomStringConvertible {
        case signatureNotFound(String)
        case unbalancedBraces(String)
        var description: String {
            switch self {
            case .signatureNotFound(let sig): return "Function signature not found while scanning: \(sig)"
            case .unbalancedBraces(let sig): return "Could not find a balanced closing brace for: \(sig)"
            }
        }
    }
}
