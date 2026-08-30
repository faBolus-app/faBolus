import Testing
import faBolusCore
@testable import faBolus

/// Behavior pins for the `[Garmin CIQ]` diagnostics section — a fabricated
/// `GarminDiagnostics.BridgeState` plain value is injected directly (no live
/// `GarminRemoteBridge`/ConnectIQ instantiation required), mirroring `RemoteRoleDiagnostics`'s
/// "inject the already-tracked state as plain values" precedent. Any Garmin device name must never
/// appear verbatim in the rendered text.
@MainActor
struct GarminDiagnosticsTests {
    @Test func populatedConnectedStateRendersQueueSendWatchdogAndDevice() {
        let state = GarminDiagnostics.BridgeState(
            queueDepth: 3, lastSendOutcome: .delivered, watchdogFires: 1,
            deviceConnected: true, deviceName: nil)
        let block = GarminDiagnostics.section(state: state, enabled: true)
        let lines = block.components(separatedBy: "\n")

        #expect(lines.first == "")
        #expect(lines[1] == "[Garmin CIQ]")
        #expect(block.contains("Queue depth: 3"))
        #expect(block.contains("Last send: delivered"))
        #expect(block.contains("Watchdog fires: 1"))
        #expect(block.contains("Device: connected"))
    }

    @Test func pairedButDisconnectedDeviceRendersDeviceDisconnected() {
        let state = GarminDiagnostics.BridgeState(
            queueDepth: 0, lastSendOutcome: .failed, watchdogFires: 2,
            deviceConnected: false, deviceName: nil)
        let block = GarminDiagnostics.section(state: state, enabled: true)

        #expect(block.contains("Queue depth: 0"))
        #expect(block.contains("Last send: failed"))
        #expect(block.contains("Watchdog fires: 2"))
        #expect(block.contains("Device: disconnected"))
    }

    @Test func noDeviceEverPairedRendersUnreachableEmptyState() {
        let block = GarminDiagnostics.section(state: nil, enabled: true)

        #expect(block.contains("[Garmin CIQ]"))
        #expect(block.contains("— (not currently reachable)"))
        #expect(!block.contains("Queue depth"))
    }

    @Test func disabledRendersOnlyHeaderAndEmptyStatePrompt() {
        let state = GarminDiagnostics.BridgeState(
            queueDepth: 5, lastSendOutcome: .delivered, watchdogFires: 3,
            deviceConnected: true, deviceName: "Zev's venu3s")
        let block = GarminDiagnostics.section(state: state, enabled: false)

        #expect(block.contains("[Garmin CIQ]"))
        #expect(!block.contains("Queue depth"))
        #expect(!block.contains("Zev's venu3s"))
    }

    @Test func deviceNameNeverAppearsVerbatimAndTokenIsDeterministicAcrossCalls() {
        let state = GarminDiagnostics.BridgeState(
            queueDepth: 1, lastSendOutcome: .timedOut, watchdogFires: 4,
            deviceConnected: true, deviceName: "Zev's venu3s")
        let first = GarminDiagnostics.section(state: state, enabled: true)
        let second = GarminDiagnostics.section(state: state, enabled: true)

        #expect(!first.contains("Zev's venu3s"))
        #expect(first == second)
        #expect(first.contains("Device: connected"))
        #expect(first.contains("Last send: timed out"))
    }

    // MARK: - Stall discriminators (watch-cgm-status-lag / bug 2.2)
    //
    // The 2026-08-29 device export read `Queue depth: 2 / Last send: timed out / Watchdog fires: 10 /
    // Device: connected` — which could not distinguish "readiness latched false" from "channel wedged"
    // from "a re-parked echo starving status", because the section had no field for ANY of them. Worse,
    // `appInstallState` was declared `let appInstallState: AppInstallState = .installed`, which Swift
    // EXCLUDES from the synthesised memberwise initializer, so it was unsettable and the `App:` line was
    // unreachable dead code. These pins make the export the falsification instrument for the fix.

    /// The readiness gate is THE missing discriminator: a stall with `Message-ready: no` is the latch;
    /// a stall with `Message-ready: yes` is the transport.
    @Test func messageReadinessIsRendered() {
        var state = GarminDiagnostics.BridgeState(
            queueDepth: 2, lastSendOutcome: .timedOut, watchdogFires: 10,
            deviceConnected: true, deviceName: nil)
        state.messageReady = false
        #expect(GarminDiagnostics.section(state: state, enabled: true).contains("Message-ready: no"))
        state.messageReady = true
        #expect(GarminDiagnostics.section(state: state, enabled: true).contains("Message-ready: yes"))
    }

    /// `Queue depth: 2` is ambiguous — the breakdown proves or disproves echo head-of-line starvation.
    @Test func echoQueueAndPendingStatusAreRenderedSeparately() {
        var state = GarminDiagnostics.BridgeState(
            queueDepth: 2, lastSendOutcome: .timedOut, watchdogFires: 10,
            deviceConnected: true, deviceName: nil)
        state.echoQueueDepth = 1
        state.statusPending = true
        let block = GarminDiagnostics.section(state: state, enabled: true)
        #expect(block.contains("Echo queue: 1"))
        #expect(block.contains("Status pending: yes"))
    }

    /// A completion that arrives AFTER the watchdog superseded it proves the channel works and the
    /// deadline was too short — the single most decisive field for choosing between the two mechanisms.
    @Test func lateCompletionsAndLastSendProgressAreRendered() {
        var state = GarminDiagnostics.BridgeState(
            queueDepth: 1, lastSendOutcome: .timedOut, watchdogFires: 10,
            deviceConnected: true, deviceName: nil)
        state.lateCompletions = 4
        state.lastSendProgress = GarminDiagnostics.SendProgress(sentBytes: 1840, totalBytes: 2960)
        let block = GarminDiagnostics.section(state: state, enabled: true)
        #expect(block.contains("Late completions: 4"))
        #expect(block.contains("Last send progress: 1840/2960 bytes"))
    }

    /// No progress callback at all is the opposite verdict — the transfer never started.
    @Test func absentSendProgressRendersExplicitlyRatherThanBeingOmitted() {
        let state = GarminDiagnostics.BridgeState(
            queueDepth: 1, lastSendOutcome: .timedOut, watchdogFires: 10,
            deviceConnected: true, deviceName: nil)
        let block = GarminDiagnostics.section(state: state, enabled: true)
        #expect(
            block.contains("Last send progress: none"),
            "a silent omission would read as 'not measured' — the whole point is proving 0 bytes moved")
    }

    /// The self-healing counter: a non-zero value proves the bridge rebuilt its own registration instead
    /// of waiting for the user to tap "Set up Garmin remote".
    @Test func autoRecoveryCountIsRendered() {
        var state = GarminDiagnostics.BridgeState(
            queueDepth: 0, lastSendOutcome: .delivered, watchdogFires: 10,
            deviceConnected: true, deviceName: nil)
        state.autoRecoveries = 3
        #expect(GarminDiagnostics.section(state: state, enabled: true).contains("Auto recoveries: 3"))
    }

    /// The dead-line repair: `appInstallState` must be SETTABLE (it was a `let` with a default, hence
    /// excluded from the memberwise init) and must render on every pull, not only the non-installed case.
    @Test func appInstallStateIsSettableAndAlwaysRendered() {
        var state = GarminDiagnostics.BridgeState(
            queueDepth: 0, lastSendOutcome: .delivered, watchdogFires: 0,
            deviceConnected: true, deviceName: nil)
        #expect(GarminDiagnostics.section(state: state, enabled: true).contains("App: ready"))
        state.appInstallState = .notInstalled
        let block = GarminDiagnostics.section(state: state, enabled: true)
        #expect(block.contains("App: "))
        #expect(block.lowercased().contains("not installed") || block.lowercased().contains("app-id mismatch"))
    }

    /// Every new field stays behind the SAME "Share local diagnostics" opt-in as the existing ones.
    @Test func newDiscriminatorFieldsStayBehindTheSharedOptIn() {
        var state = GarminDiagnostics.BridgeState(
            queueDepth: 2, lastSendOutcome: .timedOut, watchdogFires: 10,
            deviceConnected: true, deviceName: "Zev's venu3s")
        state.messageReady = false
        state.echoQueueDepth = 1
        state.statusPending = true
        state.lateCompletions = 4
        state.autoRecoveries = 2
        state.lastSendProgress = GarminDiagnostics.SendProgress(sentBytes: 10, totalBytes: 20)
        let block = GarminDiagnostics.section(state: state, enabled: false)
        #expect(!block.contains("Message-ready"))
        #expect(!block.contains("Echo queue"))
        #expect(!block.contains("Status pending"))
        #expect(!block.contains("Late completions"))
        #expect(!block.contains("Auto recoveries"))
        #expect(!block.contains("Last send progress"))
        #expect(!block.contains("App:"))
        #expect(!block.contains("Zev's venu3s"))
        #expect(!block.contains("How to read"))
    }

    /// `IQApp(uuid:store:device:)` is a FAILABLE initializer (the ObjC factory carries no nullability
    /// annotation, so Swift imports it as `init?`). If it returns nil we hold no app handle at all, and
    /// `pump()`'s `guard let app` then blocks EVERY send silently for the whole process — the same
    /// silent-stall class as the readiness latch. Pin that this has its own visible state and is not
    /// collapsed into `.notInstalled` (there we have a handle and the watch answered; here we never
    /// got to ask) nor left as a bare early return.
    @Test func noAppHandleIsItsOwnVisibleStateDistinctFromNotInstalled() {
        let noHandle = GarminDiagnostics.AppInstallState.noAppHandle
        #expect(noHandle != .notInstalled)
        #expect(noHandle != .unknown)
        #expect(!noHandle.statusText.isEmpty)
        #expect(noHandle.statusText != GarminDiagnostics.AppInstallState.notInstalled.statusText)
        // No store remedy: `showStore(for:)` needs the very IQApp we failed to build.
        #expect(noHandle.offerStoreLink == false)

        var state = GarminDiagnostics.BridgeState(
            queueDepth: 0, lastSendOutcome: .delivered, watchdogFires: 0,
            deviceConnected: true, deviceName: nil)
        state.appInstallState = .noAppHandle
        let block = GarminDiagnostics.section(state: state, enabled: true)
        #expect(block.contains("App: "))
        #expect(block.contains(noHandle.statusText))
    }

    /// The probe classifier maps a `getAppStatus` RESULT, so it must never manufacture `.noAppHandle` —
    /// that state means we never got far enough to probe, and is set only at the construction site.
    @Test func probeClassifierNeverProducesNoAppHandle() {
        #expect(garminClassifyAppInstallState(installed: nil) == .unknown)
        #expect(garminClassifyAppInstallState(installed: true) == .installed)
        #expect(garminClassifyAppInstallState(installed: false) == .notInstalled)
        for input in [nil, true, false] as [Bool?] {
            #expect(garminClassifyAppInstallState(installed: input) != .noAppHandle)
        }
    }

    /// The export is the ONLY verification loop for the bug-2.2 fix — nobody can drive ConnectIQ/BLE
    /// from a test, so the owner reads this text cold. Pin that it interprets ITSELF: every
    /// discriminator whose bare value is meaningless without the debug session must have a legend line
    /// naming the mechanism it implicates. Without this pin a future field can be added silently and
    /// the export degrades back into numbers nobody can action.
    @Test func exportCarriesASelfDescribingLegendForEveryOpaqueDiscriminator() {
        var state = GarminDiagnostics.BridgeState(
            queueDepth: 2, lastSendOutcome: .timedOut, watchdogFires: 10,
            deviceConnected: true, deviceName: nil)
        state.messageReady = false
        state.echoQueueDepth = 1
        state.statusPending = true
        state.lateCompletions = 4
        state.autoRecoveries = 2
        let block = GarminDiagnostics.section(state: state, enabled: true)

        #expect(block.contains("How to read"))
        // Each opaque counter is named in the legend, not just rendered.
        #expect(block.contains("Late completions >"))
        #expect(block.contains("Auto recoveries >"))
        #expect(block.contains("Echo queue >"))
        #expect(block.contains("Message-ready: no + Device: connected"))
        #expect(block.contains("Last send progress: none + Message-ready: yes"))
        // The legend must come AFTER the values it explains, so the raw state reads top-down first.
        let legendAt = block.range(of: "How to read")!.lowerBound
        for value in ["Queue depth: 2", "Message-ready: no", "Late completions: 4", "Auto recoveries: 2"] {
            #expect(block.range(of: value)!.lowerBound < legendAt, "legend must trail the raw values")
        }
    }
}
