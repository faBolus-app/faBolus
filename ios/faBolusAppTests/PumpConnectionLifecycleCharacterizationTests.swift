import Testing
import Foundation
import TandemBLE
import TandemMessages
import faBolusCore
@testable import faBolus

/// Pins the ordered `linkDroppedCleanup()` teardown: waiters, history, backend resets, then auth-key
/// clear. Clearing the key or cancelling the watchdog early can resolve a signed continuation against a half-torn-down session even when the final state looks identical.
@Suite(.serialized) @MainActor
struct PumpConnectionLifecycleCharacterizationTests {
    private func backend() -> TandemBackend { TandemBackend(testTransport: FakePumpTransport()) }

    /// The exact teardown order `linkDroppedCleanup()` must keep. A reorder can look identical in the final state.
    private static let expectedTeardownOrder = [
        "completeGlucoseRead", "completeCalcInputRead", "failPumpWaiters", "historyLinkDropped",
        "historyStatusReset", "detectedIsMobiReset", "pumpFeatureBitsReset", "stopAllTimers",
        "notePollCycleEnded", "coordinatorCleared", "authKeyCleared", "cancelPairingWatchdog"
    ]

    // MARK: - Call-order recorder

    /// An unintended drop that surfaces as `.connecting` from a live link must run the full teardown, in order.
    @Test func dropToConnectingFromLiveRunsTeardownInExactOrder() {
        let b = backend()
        b.setConnectionForTesting(.connected)
        var recorded: [String] = []
        b.onLinkDroppedCleanupStepForTesting = { recorded.append($0) }

        b.applyClientState(.connecting)

        #expect(
            recorded == Self.expectedTeardownOrder,
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

        b.applyClientState(.disconnected)  // real teardown #1
        #expect(recorded == Self.expectedTeardownOrder, "precondition: the first drop ran the full teardown")
        recorded.removeAll()

        b.applyClientState(.connecting)  // NOT live (we are already .disconnected) — must be a no-op
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
        b.beginPairingForTesting(code: "abcd1234ijkl5678")  // valid 16-char → legacy V1 handshake
        #expect(sends.count == 1, "precondition: the handshake sent its first message")
        #expect(b.pairingCoordinatorIsLiveForTesting, "precondition: the coordinator is live")

        b.applyClientState(.disconnected)  // the real link-drop teardown
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

    // MARK: - Watchdog arm/fire/cancel (so a teardown-order regression shows up in this suite too)

    @Test func watchdogTimeoutFailsClosedAndCancelIsIdempotent() {
        let b = TandemBackend(testTransport: FakePumpTransport(), authKey: [])
        b.pairingTimeoutSecForTesting = 0.05
        b.beginPairingForTesting(code: "123456")  // fresh JPAKE
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
        do {
            _ = try await op()
            return nil
        } catch { return error }
    }
    private func isIndeterminate(_ e: Error?) -> Bool { (e as? BolusError)?.isIndeterminate ?? false }

    @Test func midDeliveryLinkDropStillRoutesToIndeterminateAndHoldsTheLock() async {
        let fake = FakePumpTransport()
        let b = TandemBackend(testTransport: fake)
        b.deliveryPollTimeoutOverride = 1.2
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        fake.script(BolusPermissionResponse.props.opCode, .frame(FakePumpTransport.permissionGranted(bolusId: bolusId)))
        fake.script(InitiateBolusResponse.props.opCode, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
        fake.script(
            CurrentBolusStatusResponse.props.opCode,
            .frame(FakePumpTransport.currentBolusStatus(statusId: 1, bolusId: bolusId)))

        var recorded: [String] = []
        b.onLinkDroppedCleanupStepForTesting = { recorded.append($0) }
        fake.willAwait = { [weak b] op in
            if op == CurrentBolusStatusResponse.props.opCode { b?.applyClientState(.disconnected) }
        }

        let e = await capture { try await b.deliverBolus(units: 1.5, carbsGrams: nil, bgMgdl: nil, iobUnits: nil) }

        #expect(isIndeterminate(e), "a mid-delivery link drop is an indeterminate outcome")
        #expect(b.deliveryOutcomeUnknown, "the indeterminate delivery holds the global block")
        #expect(
            recorded == Self.expectedTeardownOrder,
            "the mid-delivery drop must run the same teardown order as any other link drop")
    }

    // MARK: - CRC gate + ResponseParser.parse + HMAC handoff MUST STAY in TandemBackend

    /// Static source scan: `didReceiveFrame`'s `.authorization` CRC gate + `ResponseParser.parse` + HMAC
    /// handoff (the parse-authentication seam) must remain physically inside `TandemBackend.swift` — the
    /// lifecycle extraction moves the connection/pairing-lifecycle ORCHESTRATION out, never this seam.
    @Test func crcGateAndResponseParserStayPhysicallyInTandemBackend() throws {
        let source = try Self.readSource(relativeTo: "ios/faBolus/Data/TandemBackend.swift")
        let body = try Self.balancedFunctionBody(
            signaturePrefix:
                "public func pumpClient(_ c: PumpBLEClient, didReceiveFrame frame: [UInt8], on ch: Characteristic) {",
            in: source)
        #expect(
            body.contains("calculateCRC16"), "the CRC-16 gate must still live in TandemBackend.swift's didReceiveFrame")
        #expect(
            body.contains("ResponseParser.parse"),
            "ResponseParser.parse must still live in TandemBackend.swift's didReceiveFrame")
    }

    // MARK: - op33 forwards the real negotiated apiVersion

    /// Passing `apiVersion: nil` after op33 would leave every kit `minApi` floor inert. The applier must
    /// build the real version from the frame, and TandemBackend must forward it into `setDeviceContext`.
    @Test func op33ForwardsRealNegotiatedApiVersionIntoTheSendGate_VA06() throws {
        let applierSource = try Self.readSource(relativeTo: "ios/faBolus/Data/Tandem/PumpResponseApplier.swift")
        #expect(
            applierSource.contains("ApiVersion(major: m.majorVersion, minor: m.minorVersion)"),
            "the op33 case must build the REAL negotiated ApiVersion from the frame's major.minor")

        let backendSource = try Self.readSource(relativeTo: "ios/faBolus/Data/TandemBackend.swift")
        #expect(
            backendSource.contains(
                "client.setDeviceContext(model: isMobi ? .mobi : .tslim, apiVersion: apiVersion, trusted: trusted)"),
            "the op33 device-context binding must forward the real apiVersion (NOT nil) into the send gate")
        #expect(
            !backendSource.contains("apiVersion: nil"),
            "the op33 device-context binding must no longer pass apiVersion: nil")
    }

    /// The pre-op33 identity BRIDGES in `PumpConnectionLifecycle` (a fresh `didDiscover`, and the C8
    /// silent-reconnect `reapplyTrustedIdentityIfKnown()` restore) legitimately still pass `apiVersion:
    /// nil` — op33 has not arrived yet at those points, and it re-wires with the real version later the
    /// SAME cycle (the authoritative per-cycle re-wire point). This pins that the MODEL-only bridge is
    /// intentional, so a future edit can't silently regress it into guessing an apiVersion pre-op33.
    @Test func preOp33IdentityBridgesStayModelOnly() throws {
        let lifecycleSource = try Self.readSource(relativeTo: "ios/faBolus/Data/App/PumpConnectionLifecycle.swift")
        #expect(
            lifecycleSource.contains(
                "setDeviceContext(model: isMobi ? .mobi : .tslim, apiVersion: nil, trusted: true)"),
            "the pre-op33 bridges (didDiscover + trusted-record reapply) stay MODEL-only (apiVersion nil) — op33 supplies the real version this cycle"
        )
    }

    // MARK: - Source-scan helpers (mirrors HistoryLogSyncDeliveryBoundaryTests' established pattern)

    private static func readSource(relativeTo path: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot =
            testFileURL
            .deletingLastPathComponent()  // drop the filename → .../ios/faBolusAppTests
            .deletingLastPathComponent()  // → .../ios
            .deletingLastPathComponent()  // → repo root
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
                if ch == "{" {
                    depth += 1
                    opened = true
                } else if ch == "}" {
                    depth -= 1
                }
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
